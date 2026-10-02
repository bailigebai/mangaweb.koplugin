local Http = {}
Http.__index = Http
local Models = require("mangaweb.models")

local function copy_table(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function url_encode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function form_encode(fields)
    local values = {}
    for key, value in pairs(fields or {}) do
        values[#values + 1] = url_encode(key) .. "=" .. url_encode(value)
    end
    table.sort(values)
    return table.concat(values, "&")
end

local function error_value(code, stage, detail)
    return { code = code, stage = stage or "request", detail = detail }
end

function Http:new(options)
    options = options or {}
    return setmetatable({
        transport = assert(options.transport, "transport is required"),
        timeout_seconds = tonumber(options.timeout_seconds) or 20,
        max_bytes = tonumber(options.max_bytes) or 8 * 1024 * 1024,
        active = {},
        next_id = 0,
        logger = options.logger,
    }, self)
end

function Http:_callback(request, name, ...)
    local callback = request.callbacks and request.callbacks[name]
    if type(callback) ~= "function" then return true end
    local args = { ... }
    if name == "on_error" then
        local raw = type(args[1]) == "table" and args[1] or {}
        -- Response content stays separate, for source-local challenge classification only.
        args[2] = { body = raw.body or raw.response_body }
        args[1] = Models.error(raw, request.site_id, request.stage)
    end
    local ok = pcall(callback, unpack(args))
    if not ok and self.logger then
        local entry = Models.error({ code = "callback_error" }, request.site_id, request.stage)
        if type(self.logger) == "function" then
            pcall(self.logger, entry)
        elseif type(self.logger.warn) == "function" then
            pcall(self.logger.warn, self.logger, entry)
        end
    end
    return ok
end

function Http:_finish(request, status, headers, body, err)
    if request.done or request.canceled then return end
    request.done = true
    self.active[request.id] = nil
    if err then
        local error_result = err
        if type(error_result) ~= "table" then
            local code = error_result == "response_too_large" and "response_too_large" or "transport_error"
            error_result = error_value(code, request.stage, tostring(error_result))
        end
        self:_callback(request, "on_error", error_result)
        return
    end
    body = tostring(body or "")
    if #body > self.max_bytes then
        self:_callback(request, "on_error", error_value("response_too_large", request.stage))
        return
    end
    if tonumber(status) and tonumber(status) >= 400 then
        local error = error_value("http_error", request.stage, tonumber(status))
        error.status, error.body = tonumber(status), body
        self:_callback(request, "on_error", error)
        return
    end
    self:_callback(request, "on_success", body,
        { status = tonumber(status) or 0, headers = headers or {} })
end

function Http:request(spec, callbacks)
    spec = spec or {}
    callbacks = callbacks or {}
    self.next_id = self.next_id + 1
    local request = {
        id = self.next_id,
        stage = spec.stage or "request",
        site_id = spec.site_id,
        callbacks = callbacks,
        canceled = false,
        done = false,
    }
    self.active[request.id] = request
    local request_spec = {
        url = assert(spec.url, "url is required"),
        method = spec.method or "GET",
        headers = copy_table(spec.headers),
        body = spec.body,
        timeout = spec.timeout or self.timeout_seconds,
        max_bytes = self.max_bytes,
        site_id = spec.site_id,
        stage = spec.stage,
        inline_response = spec.inline_response,
        binary = spec.binary,
        ui_nonblocking = spec.ui_nonblocking,
    }
    local function finish(status, headers, body, err)
        self:_finish(request, status, headers, body, err)
    end
    local ok, transport_handle = pcall(self.transport.request, self.transport, request_spec, finish)
    if not ok then
        self:_finish(request, nil, nil, nil, error_value("transport_error", request.stage))
        return { cancel = function() end }
    end
    request.transport_handle = transport_handle
    local owner = self
    local public_handle = {}
    function public_handle:cancel()
        if request.done or request.canceled then return end
        request.canceled = true
        owner.active[request.id] = nil
        if request.transport_handle and request.transport_handle.cancel then
            pcall(request.transport_handle.cancel, request.transport_handle)
        end
    end
    return public_handle
end

function Http:get(url, options, callbacks)
    options = options or {}
    return self:request({
        url = url,
        method = "GET",
        headers = options.headers,
        timeout = options.timeout,
        stage = options.stage,
        site_id = options.site_id,
        inline_response = options.inline_response,
        binary = options.binary,
        ui_nonblocking = options.ui_nonblocking,
    }, callbacks)
end

function Http:get_file(url, options, callbacks)
    options, callbacks = options or {}, callbacks or {}
    self.next_id = self.next_id + 1
    local request = { id = self.next_id, stage = options.stage or "image",
        site_id = options.site_id, callbacks = callbacks,
        canceled = false, done = false, reaped = false }
    self.active[request.id] = request
    local part_path = options.path
    local owner = self
    local function reaped()
        if request.reaped then return end
        request.reaped = true
        if type(callbacks.on_reaped) == "function" then pcall(callbacks.on_reaped) end
    end
    local function fail(code, status)
        if request.done or request.canceled then return end
        request.done = true
        self.active[request.id] = nil
        self:_callback(request, "on_error", { code = code, status = status })
    end
    local function complete(result)
        if request.done or request.canceled then return end
        result = type(result) == "table" and result or {}
        local status = tonumber(result.status)
        local code = result.error
        if code or not status or status >= 300 or status < 200 then
            local safe_code = code == "response_too_large" and "response_too_large"
                or code == "storage_error" and "storage_error"
                or code == "ui_nonblocking_unavailable" and "http_unavailable"
                or (code == "stream_sink_unavailable"
                    or code == "ui_scheduler_unavailable") and "http_unavailable"
                or (code == "first_byte_timeout" or code == "idle_timeout"
                    or code == "total_timeout") and "request_timeout"
                or status and status >= 300 and "http_error"
                or "transport_error"
            return fail(safe_code, status)
        end
        local bytes = tonumber(result.bytes)
        if result.path ~= part_path or not bytes or bytes < 1 then
            return fail("image_error", status)
        end
        if bytes > 64 * 1048576 then return fail("response_too_large", status) end
        request.done = true
        self.active[request.id] = nil
        self:_callback(request, "on_success", part_path,
            { status = status, headers = result.headers or {}, bytes = bytes })
    end
    if type(part_path) ~= "string" or not part_path:match("%.part$") then
        fail("image_error")
        reaped()
        return { cancel = function() end }
    end
    local request_spec = { url = url, method = "GET", headers = copy_table(options.headers),
        site_id = options.site_id, stage = options.stage or "image",
        expected_bytes = options.expected_bytes, max_bytes = 64 * 1048576,
        connect_timeout = 15, idle_timeout = 30, total_timeout = 180,
        ui_nonblocking = true }
    local ok, handle = pcall(self.transport.request_file, self.transport,
        request_spec, part_path, {
            on_done = complete,
            on_progress = function(bytes, total)
                if not request.done and not request.canceled then
                    self:_callback(request, "on_progress", bytes, total)
                end
            end,
            on_reaped = reaped,
        })
    if not ok then
        fail("transport_error")
        reaped()
    elseif handle == nil and not request.done then
        fail("transport_error")
        reaped()
    end
    request.transport_handle = ok and handle or nil
    return {
        cancel = function()
            if request.canceled or request.done then return end
            request.canceled = true
            owner.active[request.id] = nil
            if request.transport_handle and type(request.transport_handle.cancel) == "function" then
                pcall(request.transport_handle.cancel, request.transport_handle)
            else
                reaped()
            end
        end,
    }
end

function Http:post_form(url, fields, options, callbacks)
    options = options or {}
    local headers = copy_table(options.headers)
    headers["Content-Type"] = headers["Content-Type"] or "application/x-www-form-urlencoded"
    return self:request({
        url = url,
        method = "POST",
        headers = headers,
        body = form_encode(fields),
        timeout = options.timeout,
        stage = options.stage,
        site_id = options.site_id,
        inline_response = options.inline_response,
        ui_nonblocking = options.ui_nonblocking,
    }, callbacks)
end

function Http:cancel_all()
    local requests = {}
    for _, request in pairs(self.active) do requests[#requests + 1] = request end
    for _, request in ipairs(requests) do
        request.canceled = true
        self.active[request.id] = nil
        if request.transport_handle and request.transport_handle.cancel then
            pcall(request.transport_handle.cancel, request.transport_handle)
        end
    end
end

return Http
