local ImageLoader = require("mangaweb.image_loader")
local Thumbnail = require("mangaweb.cover_thumbnail")
local ImageIdentity = require("mangaweb.image_identity")
local CoverLoader = {}
CoverLoader.__index = CoverLoader

local function free(buffer)
    if buffer and type(buffer.free) == "function" then pcall(buffer.free, buffer) end
end

function CoverLoader:new(options)
    options = options or {}
    return setmetatable({ cache = options.cache, render_image = options.render_image, sessions = {},
        loader = ImageLoader:new{ http = options.http, temp_files = options.temp_files,
            async = options.async, render_image = options.render_image, logger = options.logger,
            clock = options.clock,
            page_cache = options.page_cache,
            page_processor = options.page_processor or Thumbnail, max_active = 6, max_processing = 2 },
    }, self)
end

function CoverLoader:begin_session(kind)
    local generation = self.loader:begin_session(kind)
    self.sessions[generation] = {}
    return generation
end

function CoverLoader:_unpin(state)
    if state.pinned then
        state.pinned = false
        pcall(state.cache.unpin, state.cache, state.identity)
    end
end

function CoverLoader:request(generation, spec, callbacks)
    spec, callbacks = spec or {}, callbacks or {}
    local session = self.sessions[generation]
    if not session or (spec.stage ~= "cover" and spec.stage ~= "preview") or type(spec.key) ~= "string"
        or type(spec.url) ~= "string" then
        return self.loader:request(generation, spec, callbacks)
    end
    local profile = Thumbnail.profile(spec.width, spec.height)
    local diagnostic = { site_id = spec.site_id, stage = spec.stage, priority = spec.priority,
        index = spec.index, queued_at = self.loader.clock() }
    local state = session[spec.key]
    if not state then
        local cache = self.cache
        local identity = Thumbnail.identity(spec, profile, cache and cache.sha256)
        state = { cache = cache, identity = identity, sequence = 0 }
        if cache and identity and type(cache.pin) == "function" then
            local ok, value = pcall(cache.pin, cache, identity)
            state.pinned = ok and value == true
        end
        session[spec.key] = state
    end
    local cache, identity = state.cache, state.identity
    local function alive()
        return not state.canceled and self.sessions[generation] == session
    end
    local function error_callback(err)
        if alive() and type(callbacks.on_error) == "function" then pcall(callbacks.on_error, err) end
    end
    local function ready(result, cache_hit)
        if not alive() then return false end
        if spec.stage == "preview" and (result.metadata or {}).processing_error then
            self.loader:_log(diagnostic, "thumbnail_processing_failed", "image_error")
            error_callback({ code = "image_error", site_id = spec.site_id, stage = "preview" })
            return false, false
        end
        local persisted = cache_hit == true
        local persistent_path = persisted and result.path or nil
        if cache and identity and result.metadata and result.metadata.thumbnail then
            local ok, path = pcall(cache.put_file, cache, identity, result.path, 2 * 1048576)
            persisted = ok and type(path) == "string"
            if persisted then persistent_path = path end
            self.loader:_log(diagnostic, persisted and "thumbnail_cached" or "thumbnail_cache_write_failed",
                not persisted and "storage_error" or nil)
        end
        if spec.cache_only then
            if not persisted then error_callback({ code = "storage_error", site_id = spec.site_id, stage = "cover" }); return false end
            if type(callbacks.on_ready) == "function" then
                local ok, accepted = pcall(callbacks.on_ready, {key=spec.key,path=persistent_path,cached=true})
                return ok and accepted ~= false, true
            end
            return true, true
        end
        local buffer, owned = result.buffer, false
        if not buffer then
            self.loader:_log(diagnostic, "thumbnail_decode_start")
            local renderer = self.render_image
            if not renderer then
                local ok, value = pcall(require, "ui/renderimage")
                if ok then renderer = value end
            end
            if renderer and type(renderer.renderImageFile) == "function" then
                local ok, value = pcall(renderer.renderImageFile, renderer, result.path, false, spec.width, spec.height)
                if ok then buffer, owned = value, value ~= nil end
            end
        end
        if not buffer then
            self.loader:_log(diagnostic, "thumbnail_decode_failed", "image_error")
            if not cache_hit then error_callback({ code = "image_error", site_id = spec.site_id, stage = "cover" }) end
            return false, false
        end
        local delivered = {}
        for key, value in pairs(result) do delivered[key] = value end
        delivered.buffer = buffer
        local ok, accepted = false, false
        if type(callbacks.on_ready) == "function" then ok, accepted = pcall(callbacks.on_ready, delivered) end
        accepted = ok and accepted ~= false
        self.loader:_log(diagnostic, accepted and "thumbnail_display_ready" or "thumbnail_display_rejected")
        -- ImageLoader owns buffers it provided; only our decoded derivatives are ours to free.
        if owned and not accepted then free(buffer) end
        return accepted, true
    end
    local launch
    launch = function(use_cache)
        if not alive() then return end
        local path
        if use_cache and cache and identity then
            local ok, value = pcall(cache.get, cache, identity)
            if ok and type(value) == "string" then path = value end
        end
        -- Tiny cached files never wait for the network/worker pool. A failed
        -- decode invalidates this entry and retries once through the normal pipeline.
        if path then
            self.loader:_log(diagnostic, "thumbnail_cache_hit")
            local _, decoded = ready({ key = spec.key, path = path, metadata = {} }, true)
            if decoded == false and alive() then
                pcall(cache.invalidate, cache, identity)
                return launch(false)
            end
            return
        end
        self.loader:_log(diagnostic, "thumbnail_cache_miss")
        local request = {}
        for key, value in pairs(spec) do request[key] = value end
        -- Preview originals use the reader's cache; the JPEG displayed here is
        -- only a derivative and must never replace a full reading page.
        local page_cache = self.loader.page_cache
        if page_cache then
            local identify = spec.stage == "preview" and ImageIdentity.page or ImageIdentity.cover
            request.cache_identity = identify(spec, spec.headers, page_cache.sha256)
        end
        -- File downloads keep DNS, transfer and full-size response bytes off
        -- the UI thread. Originals survive a home/detail session change and
        -- can produce another thumbnail size without another transfer.
        if type(self.loader.http.get_file) == "function" then
            request.stage = "image"
        end
        request.diagnostic_stage = spec.stage
        -- Share a temporary original only within the same site/account scope.
        local scope = ImageIdentity.scope(spec.headers, cache and cache.sha256)
        request.raw_scope = not request.cache_identity
            and scope and (tostring(spec.site_id) .. ":" .. scope) or nil
        if not request.cache_identity and not scope then request.raw_scope = spec.key end
        request.source_path = nil
        request.profile = profile
        state.sequence = state.sequence + 1
        local sequence = state.sequence
        local handle = self.loader:request(generation, request, {
            on_ready = ready,
            on_error = error_callback,
        })
        if sequence == state.sequence then state.handle = handle end
    end
    launch(true)
    return { cancel = function()
        if state.canceled then return true end
        state.canceled = true
        if state.handle then state.handle:cancel() end
        self:_unpin(state)
        if session[spec.key] == state then session[spec.key] = nil end
        return true
    end }
end

function CoverLoader:sync_protected(owner, specs, replace)
    local cache, identities = self.cache, {}
    if not cache or type(cache.sync_protected) ~= "function" then return false end
    for _, spec in ipairs(specs or {}) do
        local identity = Thumbnail.identity(spec, Thumbnail.profile(spec.width, spec.height), cache.sha256)
        if not identity then return false end
        identities[#identities + 1] = identity
    end
    local ok, value = pcall(cache.sync_protected, cache, owner, identities, replace)
    return ok and value == true
end

function CoverLoader:release(generation, key)
    self.loader:release(generation, key)
    local session = self.sessions[generation]
    if session and session[key] then self:_unpin(session[key]); session[key] = nil end
    return true
end

function CoverLoader:cancel_generation(generation)
    local session = self.sessions[generation]
    self.sessions[generation] = nil
    self.loader:cancel_generation(generation)
    for _, state in pairs(session or {}) do state.canceled = true; self:_unpin(state) end
    return true
end

function CoverLoader:cancel_all()
    local generations = {}
    for generation in pairs(self.sessions) do generations[#generations + 1] = generation end
    for _, generation in ipairs(generations) do self:cancel_generation(generation) end
end

return CoverLoader
