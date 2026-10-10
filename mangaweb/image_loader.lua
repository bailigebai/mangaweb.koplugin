local Models = require("mangaweb.models")
local ImageDimensions = require("mangaweb.image_dimensions")
local ImageLoader = {}
ImageLoader.__index = ImageLoader

local function runtime_clock()
    local ok, socket = pcall(require, "socket")
    return ok and type(socket.gettime) == "function" and socket.gettime or os.time
end

local function free(buffer)
    if buffer and type(buffer.free) == "function" then pcall(buffer.free, buffer) end
end

local function canceled_handle()
    return { cancel = function() return true end }
end

local function cache_raw_key(job)
    local parts = { job.url }
    for _, key in ipairs({ "site_id", "comic_id", "chapter_id", "index", "url" }) do
        local value = job.cache_identity[key]
        if key == "index" then value = tonumber(value) or value end
        value = tostring(value or "")
        parts[#parts + 1] = #value .. ":" .. value
    end
    return table.concat(parts, "\0")
end

local function content_extension(body)
    if type(body) ~= "string" then return nil end
    if body:sub(1, 3) == "\255\216\255" then return "jpg" end
    if body:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    local signature = body:sub(1, 6)
    if signature == "GIF87a" or signature == "GIF89a" then return "gif" end
    if body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP" then return "webp" end
    return nil
end

local function image_extension(url, explicit, body)
    local detected = content_extension(body)
    if detected then return detected end
    if type(explicit) == "string" and explicit:match("^%w+$") then
        return explicit:lower()
    end
    local path = tostring(url or ""):match("^[^%?#]+") or ""
    local extension = path:match("%.([%w]+)$")
    extension = extension and extension:lower()
    if extension == "jpeg" then extension = "jpg" end
    if extension == "jpg" or extension == "png" or extension == "gif" or extension == "webp" then
        return extension
    end
    return "jpg"
end

function ImageLoader:new(options)
    options = options or {}
    return setmetatable({
        http = assert(options.http, "http is required"),
        temp_files = assert(options.temp_files, "temp_files is required"),
        async = options.async or require("mangaweb.async"),
        page_processor = options.page_processor or require("mangaweb.page_processor"),
        page_cache = options.page_cache,
        render_image = options.render_image,
        logger = options.logger,
        clock = options.clock or runtime_clock(),
        max_active = math.max(1, math.min(6, tonumber(options.max_active) or 2)),
        max_processing = tonumber(options.max_processing) or math.huge, processing_count = 0,
        active_count = 0, sequence = 0, order = 0, sessions = {}, queue = {},
    }, self)
end

function ImageLoader:_log(job, event, code)
    local logger = self.logger
    if not logger or type(logger.warn) ~= "function" or (tonumber(job.priority) or 3) > 3 then return end
    local site = tostring(job.site_id or "?")
    if #site > 32 or not site:match("^[%w_%-]+$") then site = "?" end
    local safe_code = tostring(code or "-")
    if #safe_code > 32 or not safe_code:match("^[%w_%-]+$") then safe_code = "?" end
    local stage = tostring(job.diagnostic_stage or job.stage or "?")
    if #stage > 16 or not stage:match("^[%w_%-]+$") then stage = "?" end
    local now = self.clock()
    local elapsed = math.max(0, math.floor((now - (job.queued_at or now)) * 1000))
    pcall(logger.warn, "MangaWeb ImageLoader", event, "site", site,
        "stage", stage, "page", tonumber(job.index) or 0, "elapsed_ms", elapsed, "code", safe_code)
end

function ImageLoader:begin_session(kind)
    self.sequence = self.sequence + 1
    self.sessions[self.sequence] = { generation = self.sequence, kind = kind, temp = self.temp_files:new_session(),
        raw_by_url = {}, jobs_by_key = {}, buffers = {}, processing = 0, file_downloads = 0 }
    return self.sequence
end

function ImageLoader:_cleanup(session)
    if session.canceled and session.processing == 0 and session.file_downloads == 0
        and not next(session.jobs_by_key) and not session.cleaned then
        session.cleaned = true
        self.temp_files:remove_session(session.temp)
        self.sessions[session.generation] = nil
    end
end

function ImageLoader:_start_file(job)
    local raw, session = job.raw, job.session
    local part, storage
    if self.page_cache and job.cache_identity then
        local ok, reserved = pcall(self.page_cache.reserve, self.page_cache, job.cache_identity)
        if ok and type(reserved) == "string" then part, storage = reserved, "cache" end
    end
    if not part then
        local ok, reserved = pcall(self.temp_files.reserve, self.temp_files,
            session.temp, "raw-" .. job.order)
        if ok and type(reserved) == "string" then part, storage = reserved, "session" end
    end
    if not part then
        raw.loading = false
        return self:_failed(job, { code = "storage_error" })
    end

    job.file_download = true
    raw.owner, raw.cancel_requested = job, false
    session.file_downloads = session.file_downloads + 1
    local terminal, reaped, launching, finalized = nil, false, true, false
    local function discard()
        if not part then return end
        if storage == "cache" then
            pcall(self.page_cache.discard, self.page_cache, part)
        else
            pcall(self.temp_files.discard, self.temp_files, part)
        end
        part = nil
    end
    local function finalize()
        if launching or finalized or not reaped then return end
        if not terminal and not job.canceled and not session.canceled then return end
        finalized = true
        session.file_downloads = session.file_downloads - 1
        raw.loading = false
        if raw.owner == job then raw.owner = nil end
        local err
        if terminal and terminal.error then err = terminal.error end
        if terminal and not err then
            local metadata = terminal.metadata or {}
            local ok, path, publish_error
            if storage == "cache" then
                ok, path, publish_error = pcall(self.page_cache.publish, self.page_cache,
                    job.cache_identity, part, metadata.bytes)
            else
                ok, path, publish_error = pcall(self.temp_files.publish, self.temp_files,
                    session.temp, part, nil, metadata.bytes)
            end
            if ok and type(path) == "string" then
                raw.path, raw.persistent = path, storage == "cache"
                part = nil
                self:_log(job, "file_ready")
            else
                err = { code = publish_error == "response_too_large"
                    and "response_too_large" or publish_error == "storage_error"
                    and "storage_error" or "image_error" }
            end
        end
        discard()
        if job.canceled or job.dropped or session.canceled then
            self:_stop_worker(job)
            if raw.refs == 0 and raw.path and not raw.persistent then
                self.temp_files:remove(raw.path)
                raw.path = nil
            end
            self:_cleanup(session)
            return self:_pump()
        end
        if err then
            self:_log(job, "file_error", type(err) == "table" and err.code)
            self:_stop_worker(job)
            if raw.attempts < 2 then
                self:_enqueue(job)
                return self:_pump()
            end
            raw.error = err
            return self:_failed(job, err)
        end
        self:_process(job)
    end
    local ok, operation = pcall(self.http.get_file, self.http, job.url, {
        path = part, headers = job.headers, site_id = job.site_id,
        stage = job.stage, expected_bytes = job.expected_bytes,
    }, {
        on_success = function(path, metadata)
            if path ~= part then terminal = { error = { code = "image_error" } }
            else terminal = { metadata = metadata } end
            finalize()
        end,
        on_error = function(error_value)
            terminal = { error = error_value }
            finalize()
        end,
        on_progress = function(bytes, total)
            if not job.canceled and not session.canceled then
                for _, callbacks in ipairs(job.waiters) do
                    if type(callbacks.on_progress) == "function" then
                        pcall(callbacks.on_progress, bytes, total)
                    end
                end
            end
        end,
        on_reaped = function()
            reaped = true
            finalize()
        end,
    })
    launching = false
    if not ok then
        terminal, reaped = { error = { code = "transport_error" } }, true
    elseif job.active then
        job.operation = operation
        if job.canceled and raw.refs == 0 and operation
            and type(operation.cancel) == "function" and not raw.cancel_requested then
            raw.cancel_requested = true
            pcall(operation.cancel, operation)
        end
    end
    finalize()
end

function ImageLoader:_release_retained_pin(raw)
    local identity = raw.retained_cache_identity
    raw.retained_cache_identity = nil
    if identity and self.page_cache then pcall(self.page_cache.unpin, self.page_cache, identity) end
end

function ImageLoader:_drop(job)
    if job.dropped then
        if job.output and (not job.active or not job.processing) then
            self.temp_files:remove(job.output)
            job.output = nil
        end
        return
    end
    job.dropped = true
    if job.cache_pinned and self.page_cache then
        pcall(self.page_cache.unpin, self.page_cache, job.cache_identity)
        job.cache_pinned = false
    end
    for index = #self.queue, 1, -1 do
        if self.queue[index] == job then table.remove(self.queue, index) end
    end
    local session, raw = job.session, job.raw
    if session.jobs_by_key[job.key] == job then session.jobs_by_key[job.key] = nil end
    if job.output and (not job.active or not job.processing) then
        self.temp_files:remove(job.output)
        job.output = nil
    end
    raw.refs = raw.refs - 1
    if raw.refs == 0 then
        if raw.loading then
            if session.raw_by_url[job.raw_key] == raw then session.raw_by_url[job.raw_key] = nil end
            raw.orphan = true
            local owner = raw.owner
            local operation = raw.operation or (owner and owner.file_download and owner.operation)
            if operation and type(operation.cancel) == "function" and not raw.cancel_requested then
                raw.cancel_requested = true
                pcall(operation.cancel, operation)
                raw.operation = nil
            end
            if owner and owner.inline_download then self:_stop_worker(owner) end
        elseif (raw.retain_count or 0) == 0 then
            self:_release_retained_pin(raw)
            if raw.path and not raw.persistent and not raw.borrowed then self.temp_files:remove(raw.path) end
            raw.path = nil
            if session.raw_by_url[job.raw_key] == raw then session.raw_by_url[job.raw_key] = nil end
        end
    end
end

function ImageLoader:_stop_worker(job)
    if not job.active then return end
    job.active = false
    self.active_count = self.active_count - 1
    if job.processing then
        job.processing = false
        self.processing_count = self.processing_count - 1
        job.session.processing = job.session.processing - 1
    end
    job.operation = nil
end

function ImageLoader:_deliver(job, callbacks, buffer)
    if job.canceled or job.dropped or job.session.canceled then return false end
    local ready = callbacks and callbacks.on_ready
    if type(ready) ~= "function" then return false end
    local result = job.result
    local ok, accepted = pcall(ready, { key = job.key, path = result.path, buffer = buffer,
        metadata = result.metadata, cached_raw = result.cached_raw })
    return ok and accepted ~= false
end

function ImageLoader:_ready(job, path, metadata, buffer)
    self:_log(job, "ready")
    self:_stop_worker(job)
    if job.canceled or job.session.canceled then
        free(buffer)
        self:_drop(job)
    else
        job.raw.retained = true
        job.result = { path = path, metadata = metadata or {}, cached_raw = job.raw.path }
        job.session.buffers[job.key] = buffer
        for _, callbacks in ipairs(job.waiters) do
            if self:_deliver(job, callbacks, buffer) then buffer = nil end
        end
        job.session.buffers[job.key] = nil
        free(buffer)
        job.waiters = {}
    end
    self:_cleanup(job.session)
    self:_pump()
end

function ImageLoader:_failed(job, err)
    self:_log(job, "error", type(err) == "table" and err.code)
    self:_stop_worker(job)
    self:_drop(job)
    if not job.canceled and not job.session.canceled then
        local sanitized = Models.error(err, job.site_id, job.stage, "image_error")
        for _, callbacks in ipairs(job.waiters) do
            if job.session.canceled or job.canceled then break end
            if type(callbacks.on_error) == "function" then pcall(callbacks.on_error, sanitized) end
        end
    end
    job.waiters = {}
    self:_cleanup(job.session)
    self:_pump()
end

function ImageLoader:_enqueue(job)
    self.queue[#self.queue + 1] = job
    table.sort(self.queue, function(a, b)
        return a.priority < b.priority or (a.priority == b.priority and a.order < b.order)
    end)
end

function ImageLoader:_process_impl(job)
    local raw = job.raw
    if job.canceled or job.session.canceled then return self:_failed(job) end
    if job.profile then
        if self.processing_count >= self.max_processing then
            self:_stop_worker(job)
            self:_enqueue(job)
            return self:_pump()
        end
        raw.retained = true
        local extension = job.profile.extension == "jpg" and "jpg" or "png"
        local output = self.temp_files:path(job.session.temp, "processed-" .. job.order, extension)
        job.output = self.temp_files:track(job.session.temp, output)
        job.processing = true
        self:_log(job, "process_start")
        self.processing_count = self.processing_count + 1
        job.session.processing = job.session.processing + 1
        local launching, completion = true, nil
        local function complete()
            if not job.active then return end
            -- Async can report a timeout before the terminated child is reaped.
            if job.operation and job.operation.pid then return end
            if job.canceled or job.session.canceled then return self:_failed(job) end
            if not completion then return end
            local ok, value = completion[1], completion[2]
            if ok and type(value) == "table" and type(value.metadata) == "table" then
                return self:_ready(job, output, value.metadata)
            end
            self:_log(job, "process_failed", type(value) == "table"
                and value.processing_error or "image_processing_failed")
            self.temp_files:remove(output)
            job.output = nil
            -- The reader scales this raw path with its normal page fit policy.
            self:_ready(job, raw.path, { processing_error = "image_processing_failed" })
        end
        local function done(ok, value)
            completion = { ok, value }
            if not launching then complete() end
        end
        local function reaped()
            complete()
        end
        if self.async.available and not self.async.available() then
            launching = false
            return done(false)
        end
        local launched, operation = pcall(self.async.run, function()
            local metadata, processing_error = self.page_processor.process(raw.path, output, job.profile)
            return { metadata = metadata, processing_error = processing_error }
        end, done, { on_reaped = reaped })
        launching = false
        if not launched then return done(false) end
        if job.active then job.operation = operation end
        complete()
        return
    end
    if job.stage == "cover" or job.stage == "detail" or job.stage == "preview"
        or job.stage == "page" or job.stage == "image" then
        if job.stage == "page" or job.stage == "image" then
            local width, height = ImageDimensions.from_file(raw.path)
            if width and height then
                self:_log(job, "jpeg_header_ready")
                return self:_ready(job, raw.path, { width = width, height = height })
            end
        end
        self:_log(job, "decode_start")
        job.decode_attempts = (job.decode_attempts or 0) + 1
        local renderer = self.render_image
        if not renderer then
            local ok, loaded = pcall(require, "ui/renderimage")
            if ok then renderer = loaded end
        end
        local ok, buffer
        if renderer and type(renderer.renderImageFile) == "function" then
            ok, buffer = pcall(renderer.renderImageFile, renderer, raw.path, false, job.width, job.height)
        end
        if not ok or not buffer then
            if job.decode_attempts < 2 and (raw.retained or raw.attempts < 2) then
                if raw.persistent and self.page_cache and job.cache_identity then
                    pcall(self.page_cache.invalidate, self.page_cache, job.cache_identity)
                    raw.persistent = nil
                    raw.path = nil
                elseif not raw.retained then
                    self.temp_files:remove(raw.path)
                    raw.path = nil
                end
                self:_stop_worker(job)
                self:_enqueue(job)
                return self:_pump()
            end
            return self:_failed(job, { code = "image_error" })
        end
        if job.stage == "page" or job.stage == "image" then
            local width, height
            if type(buffer.getSize) == "function" then
                local got, first, second = pcall(buffer.getSize, buffer)
                if got then width, height = first, second end
            end
            if (not width or not height) and type(buffer.getWidth) == "function"
                and type(buffer.getHeight) == "function" then
                local got_width, value_width = pcall(buffer.getWidth, buffer)
                local got_height, value_height = pcall(buffer.getHeight, buffer)
                if got_width and got_height then width, height = value_width, value_height end
            end
            width, height = tonumber(width or buffer.width), tonumber(height or buffer.height)
            free(buffer)
            if not width or not height then return self:_failed(job, { code = "image_error" }) end
            return self:_ready(job, raw.path, { width = width, height = height })
        end
        return self:_ready(job, raw.path, { width = job.width, height = job.height }, buffer)
    end
    self:_ready(job, raw.path, { width = job.width, height = job.height })
end

function ImageLoader:_process(job)
    local ok = pcall(self._process_impl, self, job)
    if not ok then
        self:_log(job, "process_exception")
        self:_failed(job, { code = "image_error" })
    end
end

function ImageLoader:_start(job)
    job.active = true
    self.active_count = self.active_count + 1
    local raw = job.raw
    if not raw.path and self.page_cache and job.cache_identity then
        local ok, path = pcall(self.page_cache.get, self.page_cache, job.cache_identity)
        if ok and type(path) == "string" and path ~= "" then
            raw.path, raw.persistent = path, true
            self:_log(job, "cache_ready")
        end
    end
    if raw.path then return self:_process(job) end
    if raw.error then return self:_failed(job, raw.error) end
    raw.loading, raw.attempts = true, raw.attempts + 1
    self:_log(job, "download_start")
    if job.stage == "page" or job.stage == "image" then
        return self:_start_file(job)
    end
    raw.owner, raw.cancel_requested = job, false
    job.inline_download = true
    local settled = false
    local function finished(body, response, err)
        if settled then return end
        settled = true
        job.inline_download = false
        raw.loading = false
        raw.operation = nil
        if not err and response and tonumber(response.status) and tonumber(response.status) >= 400 then
            err = { code = "http_error", status = tonumber(response.status) }
        end
        if not err and (type(body) ~= "string" or body == "") then err = { code = "image_error" } end
        if not err and not content_extension(body) then err = { code = "image_error" } end
        if job.dropped or job.canceled or job.orphan or job.session.canceled then
            self:_stop_worker(job)
            if (job.dropped or job.canceled) and raw.refs > 0
                and job.session.raw_by_url[job.raw_key] == raw and not job.session.canceled then
                if not err then
                    local extension = image_extension(job.url, job.extension, body)
                    local candidate = self.temp_files:track(job.session.temp,
                        self.temp_files:path(job.session.temp, "raw-" .. job.order, extension))
                    local ok, path = pcall(self.temp_files.write, self.temp_files,
                        job.session.temp, "raw-" .. job.order, body, extension)
                    if ok and path then raw.path = path
                    else self.temp_files:remove(candidate) end
                end
                self:_pump()
                return
            end
            self:_cleanup(job.session)
            self:_pump()
            return
        end
        if job.session.canceled then return self:_failed(job) end
        if not err then
            local extension = image_extension(job.url, job.extension, body)
            if self.page_cache and job.cache_identity then
                local cached, path = pcall(self.page_cache.put, self.page_cache,
                    job.cache_identity, body, extension)
                if cached and type(path) == "string" and path ~= "" then
                    raw.path, raw.persistent = path, true
                end
            end
            if not raw.path then
                local candidate = self.temp_files:track(job.session.temp,
                    self.temp_files:path(job.session.temp, "raw-" .. job.order, extension))
                local ok, path = pcall(self.temp_files.write, self.temp_files,
                    job.session.temp, "raw-" .. job.order, body, extension)
                if ok and path then raw.path = path
                else self.temp_files:remove(candidate); err = { code = "image_error" } end
            end
        end
        if err then
            self:_stop_worker(job)
            if raw.attempts < 2 and not job.canceled then
                self:_enqueue(job)
                return self:_pump()
            end
            if raw.attempts >= 2 then raw.error = err end
            return self:_failed(job, err)
        end
        self:_log(job, "download_ready")
        self:_process(job)
    end
    local ok, operation = pcall(self.http.get, self.http, job.url,
        { headers = job.headers, site_id = job.site_id, stage = job.stage,
            -- Prefer Turbo for the common case. Transport marks this as a
            -- binary request so an empty/native failure falls back to a
            -- background temporary file instead of serializing image bytes
            -- through the subprocess payload.
            inline_response = true, binary = true, ui_nonblocking = true }, {
            on_success = function(body, response) finished(body, response) end,
            on_error = function(err) finished(nil, nil, err) end,
        })
    if not ok then finished(nil, nil, { code = "transport_error" })
    elseif not settled then
        job.operation, raw.operation = operation, operation
    end
end

function ImageLoader:_pump()
    if self.pumping then return end
    self.pumping = true
    while self.active_count < self.max_active do
        local next_job
        for index, job in ipairs(self.queue) do
            if not job.raw.loading and not (job.profile and job.raw.path
                and self.processing_count >= self.max_processing) then
                next_job = table.remove(self.queue, index)
                break
            end
        end
        if not next_job then break end
        if not next_job.canceled and not next_job.session.canceled then self:_start(next_job) end
    end
    self.pumping = false
end

function ImageLoader:request(generation, spec, callbacks)
    local session = self.sessions[generation]
    if not session or session.canceled then return canceled_handle() end
    spec, callbacks = spec or {}, callbacks or {}
    if type(spec.key) ~= "string" or spec.key == "" or type(spec.url) ~= "string" or spec.url == "" then
        if type(callbacks.on_error) == "function" then
            pcall(callbacks.on_error, Models.error({ code = "image_error" }, spec.site_id, spec.stage))
        end
        return canceled_handle()
    end
    local existing = session.jobs_by_key[spec.key]
    if existing then
        if existing.result then self:_deliver(existing, callbacks)
        else existing.waiters[#existing.waiters + 1] = callbacks end
        return existing.handle
    end
    self.order = self.order + 1
    local job = {}
    for key, value in pairs(spec) do job[key] = value end
    job.session, job.order, job.waiters = session, self.order, { callbacks }
    job.queued_at = self.clock()
    job.priority = tonumber(job.priority) or 3
    if job.priority ~= job.priority or job.priority < 1 or job.priority > 4 then job.priority = 3 end
    job.stage = job.stage or ((job.priority == 2 or job.priority == 3) and "cover" or "page")
    job.extension = image_extension(job.url, job.extension)
    if self.page_cache and job.cache_identity then
        local pinned, value = pcall(self.page_cache.pin, self.page_cache, job.cache_identity)
        job.cache_pinned = pinned and value ~= false
    end
    -- Page identity stays stable across filter epochs. Different pages using
    -- one CDN URL still have separate originals, while previews and settings
    -- changes share the owning raw object and consume its temporary retention.
    job.raw_key = type(job.raw_scope) == "string" and (job.url .. "\0" .. job.raw_scope)
        or self.page_cache and job.cache_identity and cache_raw_key(job) or job.url
    job.raw = session.raw_by_url[job.raw_key] or { refs = 0, attempts = 0, retain_count = 0 }
    if type(job.source_path) == "string" and not job.raw.path then
        -- Preview borrows the active reader's original. Its owner keeps the
        -- source alive; preview cleanup only removes the derived image.
        job.raw.path, job.raw.borrowed = job.source_path, true
    end
    session.raw_by_url[job.raw_key] = job.raw
    if job.raw.retain_count > 0 then job.raw.retain_count = job.raw.retain_count - 1 end
    job.raw.refs = job.raw.refs + 1
    if job.raw.retain_count == 0 and job.cache_pinned then self:_release_retained_pin(job.raw) end
    local owner = self
    job.handle = { cancel = function()
        if job.canceled or job.dropped then return true end
        job.canceled = true
        if job.processing and job.operation and type(job.operation.cancel) == "function" then
            pcall(job.operation.cancel, job.operation)
            owner:_drop(job)
        elseif job.active and job.file_download then
            owner:_drop(job)
        elseif job.active and job.inline_download then
            -- Another queued consumer can still need this shared transfer.
            -- Keep its slot until completion, or cancel when the last reference drops.
            owner:_drop(job)
        elseif job.active then
            owner:_stop_worker(job)
            owner:_drop(job)
        else
            owner:_drop(job)
        end
        owner:_pump()
        return true
    end }
    session.jobs_by_key[job.key] = job
    self:_log(job, "queued")
    self:_enqueue(job)
    if job.priority == 1 and self.active_count >= self.max_active then
        local farthest, distance = nil, -1
        local target = tonumber(job.index)
        for _, active in pairs(session.jobs_by_key) do
            if active ~= job and active.active and active.file_download
                and not active.canceled and active.priority > 1
                and active.raw_key ~= job.raw_key then
                local active_index = tonumber(active.index)
                local gap = target and active_index
                    and math.abs(active_index - target) or active.order
                if gap > distance then farthest, distance = active, gap end
            end
        end
        if farthest then farthest.handle:cancel() end
    end
    self:_pump()
    return job.handle
end

function ImageLoader:release(generation, key)
    local session = self.sessions[generation]
    local job = session and session.jobs_by_key[key]
    if job and job.result then self:_drop(job) end
    return true
end

function ImageLoader:cancel_processing(generation, key)
    local session = self.sessions[generation]
    local job = session and session.jobs_by_key[key]
    if not job then return true end
    if not job.retention_claimed and (job.processing or job.result) then
        job.retention_claimed = true
        -- Retaining the raw path also retains its cache protection. Otherwise
        -- dropping the old epoch can trim preloaded originals before the new
        -- processing jobs acquire their own pins.
        if job.cache_pinned and not job.raw.retained_cache_identity then
            local pinned, value = pcall(self.page_cache.pin, self.page_cache, job.cache_identity)
            if pinned and value ~= false then job.raw.retained_cache_identity = job.cache_identity end
        end
        job.raw.retain_count = (job.raw.retain_count or 0) + 1
        job.raw.retained = true
    end
    return job.handle:cancel()
end

function ImageLoader:cancel_generation(generation)
    local session = self.sessions[generation]
    if not session or session.canceled then return true end
    session.canceled = true
    for _, raw in pairs(session.raw_by_url) do self:_release_retained_pin(raw) end
    local jobs = {}
    for _, job in pairs(session.jobs_by_key) do jobs[#jobs + 1] = job end
    for _, job in ipairs(jobs) do
        job.handle:cancel()
        if job.active and not job.processing and not job.file_download and not job.inline_download then
            job.raw.loading = false
            self:_failed(job)
        end
    end
    self:_cleanup(session)
    self:_pump()
    return true
end

function ImageLoader:cancel_all()
    for generation in pairs(self.sessions) do self:cancel_generation(generation) end
    return true
end

return ImageLoader
