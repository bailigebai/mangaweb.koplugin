local Transport = {}
Transport.__index = Transport

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function response_status(value)
    if type(value) == "table" then
        return response_status(value.status or value.status_code or value.code)
    end
    local numeric = tonumber(value)
    if numeric and numeric >= 100 and numeric <= 599 then return numeric end
    local status = tonumber(tostring(value or ""):match("^[Hh][Tt][Tt][Pp]/[^%s]+%s+(%d%d%d)"))
    return status and status >= 100 and status <= 599 and status or nil
end

local function response_body(value)
    if type(value) == "string" then return value end
    if type(value) ~= "table" then return "" end
    for _, key in ipairs({ "body", "response_body", "content", "data" }) do
        if type(value[key]) == "string" then return value[key] end
    end
    local chunks = {}
    for index = 1, #value do
        if type(value[index]) == "string" then chunks[#chunks + 1] = value[index] end
    end
    return table.concat(chunks)
end

local function structured_body(value)
    if type(value) ~= "table" then return "" end
    for _, key in ipairs({ "body", "response_body", "content", "data" }) do
        if type(value[key]) == "string" then return value[key] end
    end
    return ""
end

local function structured_headers(value)
    if type(value) == "table" then
        local headers = value.headers or value.response_headers
        if type(headers) == "table" then return headers end
    end
end

local function direct_headers(value)
    if type(value) ~= "table" then return nil end
    local names = {
        ["location"] = true, ["set-cookie"] = true, ["content-type"] = true,
        ["content-length"] = true, ["etag"] = true, ["server"] = true,
    }
    for key in pairs(value) do
        if names[tostring(key):lower()] then return value end
    end
end

-- LuaSec builds used by KOReader do not all keep the standard
-- (body, code, headers, status) return order. Scan every returned slot so a
-- valid HTML body cannot be mistaken for an empty response.
local function response_parts(values, first)
    local body, headers, status = "", nil, nil
    -- Lua's ipairs stops at the first nil; wrappers may leave a nil slot
    -- between metadata and the body, so inspect the small return tuple by index.
    first = first or 1
    for index = first, first + 7 do
        local value = values and values[index]
        if type(value) == "table" then
            if body == "" then body = response_body(value) end
            headers = headers or structured_headers(value) or direct_headers(value)
            status = status or response_status(value)
        elseif type(value) == "number" then
            status = status or response_status(value)
        elseif type(value) == "string" and body == "" then
            local parsed_status = response_status(value)
            if parsed_status then
                status = status or parsed_status
            elseif value ~= "" and value ~= "OK" and value ~= "ok"
                and not value:match("^%d+$")
                and (value:find("<", 1, true) or #value >= 8) then
                body = value
            end
        end
    end
    return body, headers, status
end

local function has_headers(value)
    return type(value) == "table" and next(value) ~= nil
end

local function make_sink(socketutil, ltn12, chunks)
    if socketutil and socketutil.table_sink then
        local ok, sink = pcall(socketutil.table_sink, chunks)
        if ok and type(sink) == "function" then return sink end
        ok, sink = pcall(socketutil.table_sink, socketutil, chunks)
        if ok and type(sink) == "function" then return sink end
    end
    return ltn12.sink.table(chunks)
end

local NATIVE_HEADER_NAMES = { "location", "set-cookie", "content-type", "content-length" }

local function native_module()
    local ok, module = pcall(require, "mangaweb.turbo_client")
    if not ok or type(module) ~= "table" or type(module.new) ~= "function"
        or type(module.available) ~= "function" then return false end
    return module
end

local function native_client()
    local module = native_module()
    if not module or not module.available() then return false end
    local created, client = pcall(module.new, module)
    return created and client or false
end

local function native_headers(value)
    if type(value) ~= "table" then return {} end
    if type(value.get) ~= "function" then return copy(value) end
    local headers = {}
    for _, name in ipairs(NATIVE_HEADER_NAMES) do
        local ok, item = pcall(value.get, value, name, true)
        if ok and item ~= nil then headers[name] = item end
    end
    return headers
end

function Transport.ensure_native()
    local module = native_module()
    return module ~= false and module.available()
end

local INLINE_RESPONSE_LIMIT = 96 * 1024

local function warn_response(logger, request, status, body, error_value)
    if not logger or type(logger.warn) ~= "function" then return end
    local bytes = #tostring(body or "")
    if not error_value and bytes > 0 and tonumber(status) and tonumber(status) < 400 then return end
    pcall(logger.warn, "MangaWeb HTTP", tostring(request.site_id or "?"),
        tostring(request.stage or "request"), tostring(request.method or "GET"),
        "status", tostring(status or "?"), "bytes", tostring(bytes),
        "error", tostring(error_value or ""))
end

local function header_value(headers, name)
    if type(headers) ~= "table" then return nil end
    local expected = tostring(name or ""):lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == expected then
            if type(value) == "table" then value = value[1] end
            return value and tostring(value) or nil
        end
    end
end

local function url_parts(url)
    local scheme, authority, path = tostring(url or ""):match("^(https?)://([^/?#]+)([^?#]*)")
    if not scheme or not authority then return nil, nil, nil end
    return scheme:lower(), authority:lower(), path ~= "" and path or "/"
end

local function absolute_redirect(base_url, location)
    location = tostring(location or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if location == "" then return nil end
    if location:match("^https?://") then return location end
    local scheme, authority, path = url_parts(base_url)
    if not scheme or not authority then return nil end
    if location:sub(1, 2) == "//" then return scheme .. ":" .. location end
    if location:sub(1, 1) == "/" then return scheme .. "://" .. authority .. location end
    local directory = path:match("^(.*)/") or ""
    if directory == "" then directory = "/" end
    if directory:sub(-1) ~= "/" then directory = directory .. "/" end
    return scheme .. "://" .. authority .. directory .. location
end

local function redirect_request(request, status, headers)
    local method = tostring(request.method or "GET"):upper()
    if method ~= "GET" or not status
        or (status ~= 301 and status ~= 302 and status ~= 303 and status ~= 307 and status ~= 308) then
        return nil
    end
    local count = tonumber(request._redirect_count) or 0
    if count >= 3 then return nil end
    local location = header_value(headers, "location")
    local target = absolute_redirect(request.url, location)
    if not target or target == request.url then return nil end
    local source_scheme, source_authority = url_parts(request.url)
    local target_scheme, target_authority = url_parts(target)
    if not source_authority or not target_authority
        or source_authority ~= target_authority
        or source_scheme == "https" and target_scheme == "http" then
        return nil
    end
    local redirected = copy(request)
    redirected.url = target
    redirected._redirect_count = count + 1
    redirected.headers = copy(request.headers)
    return redirected
end

function Transport:redirect_request(request, status, headers)
    return redirect_request(request, status, headers)
end

function Transport:new(options)
    options = options or {}
    local socketutil = options.socketutil
    if not socketutil then
        local ok, loaded = pcall(require, "socketutil")
        if ok then socketutil = loaded end
    end
    local socket = options.socket
    if not socket then
        local ok, loaded = pcall(require, "socket")
        if ok then socket = loaded end
    end
    local async = options.async
    if async == nil then
        local ok, loaded = pcall(require, "mangaweb.async")
        async = ok and loaded or false
    end
    local native_http = options.native_http
    if native_http == nil then native_http = native_client() end
    return setmetatable({
        http = options.http or require("socket.http"),
        https = options.https,
        ltn12 = options.ltn12 or require("ltn12"),
        socketutil = socketutil,
        socket = socket,
        timeout = tonumber(options.timeout) or 20,
        async = async,
        native_http = native_http,
        logger = options.logger,
        -- An explicitly injected stream remains useful for unit tests. The
        -- runtime default uses a named file because Lua file handles are not
        -- reliable across KOReader's forked subprocess boundary.
        temp_file = options.temp_file,
        open_file = options.open_file or io.open,
        remove_file = options.remove_file or os.remove,
        temp_name = options.temp_name or os.tmpname,
    }, self)
end

function Transport:_request_native(request, done)
    local handle = { canceled = false }
    local native_handle
    function handle:cancel()
        if self.canceled or self.finished then return end
        self.canceled = true
        if native_handle and type(native_handle.cancel) == "function" then
            pcall(native_handle.cancel, native_handle)
        end
    end
    local headers = copy(request.headers)
    local user_agent
    for name, value in pairs(headers) do
        if tostring(name):lower() == "user-agent" then user_agent = tostring(value) end
    end
    local request_options = {
        url = request.url,
        method = request.method or "GET",
        body = request.body,
        headers = headers,
        allow_redirects = false,
        user_agent = user_agent,
        on_headers = function(output)
            if type(output) ~= "table" or type(output.add) ~= "function" then return end
            for name, value in pairs(headers) do
                if tostring(name):lower() ~= "content-length" then
                    local current = type(output.get) == "function" and output:get(name, true) or nil
                    if current ~= nil and type(output.set) == "function" then
                        output:set(name, tostring(value), true)
                    else
                        output:add(name, tostring(value))
                    end
                end
            end
        end,
    }
    local ok, result = pcall(self.native_http.request, self.native_http, request_options,
        function(response)
            if handle.canceled or handle.finished then return end
            response = type(response) == "table" and response or {}
            -- Turbo versions bundled with KOReader have used body, content,
            -- and data for the response payload. Normalize them here so
            -- binary covers/pages are not discarded as an empty 200 response.
            local body = response_body(response)
            local status = response_status(response.code) or response_status(response.status)
            local response_headers = native_headers(response.headers)
            local redirected = redirect_request(request, status, response_headers)
            if redirected then
                native_handle = self:_request_native(redirected, function(final_status,
                        final_headers, final_body, final_error)
                    if handle.canceled or handle.finished then return end
                    handle.finished = true
                    done(final_status, final_headers, final_body, final_error)
                end)
                return
            end
            handle.finished = true
            local failure = response.error
            if #body > (tonumber(request.max_bytes) or math.huge) then
                failure = "response_too_large"
            elseif not failure and body == "" and (request.method or "GET") == "GET"
                and tostring(request.stage or "") ~= ""
                and tonumber(status) and status >= 200 and status < 400 then
                -- A few Kindle Turbo builds expose the status for a response
                -- before making its body available. Treat every empty GET as
                -- a transport miss so HTML pages and binary images both use
                -- the idempotent LuaSec fallback instead of being parsed as
                -- an empty success. POST is intentionally excluded because a
                -- login redirect may legitimately have no response body.
                failure = "empty_response"
            elseif not status and not failure then
                failure = "request failed"
            end
            warn_response(self.logger, request, status, body, failure)
            done(status, response_headers, body, failure)
        end)
    native_handle = ok and result or nil
    if not ok and not handle.canceled and not handle.finished then
        handle.finished = true
        warn_response(self.logger, request, nil, "", result)
        done(nil, {}, "", tostring(result))
    end
    return handle
end

function Transport:_client(url)
    if not url:match("^https://") then return self.http end
    if self.https then return self.https end
    local ok, client = pcall(require, "ssl.https")
    if not ok then return nil end
    self.https = client
    return client
end

function Transport:_request_sync(request, done)
    local canceled = false
    local active_socket
    local handle = {
        cancel = function()
            canceled = true
            if active_socket and active_socket.close then pcall(active_socket.close, active_socket) end
        end,
    }
    local chunks = {}
    local headers = copy(request.headers)
    if request.body ~= nil then
        headers["Content-Length"] = headers["Content-Length"] or #request.body
    end
    local client = self:_client(request.url)
    if not client then
        done(nil, {}, "", "https transport unavailable")
        return handle
    end
    local source = request.body and self.ltn12.source.string(request.body) or nil
    local timeout = math.max(1, tonumber(request.timeout) or self.timeout)
    local socketutil = self.socketutil
    local timeout_set = false
    if socketutil and socketutil.set_timeout then
        pcall(socketutil.set_timeout, socketutil, timeout, timeout)
        timeout_set = true
    end
    local sink
    sink = make_sink(socketutil, self.ltn12, chunks)
    local max_bytes = tonumber(request.max_bytes)
    local bytes_read = 0
    local response_too_large = false
    local sink_with_cancel = function(chunk, error_value)
        if canceled then return nil, "canceled" end
        if chunk and max_bytes then
            bytes_read = bytes_read + #chunk
            if bytes_read > max_bytes then
                response_too_large = true
                return nil, "response_too_large"
            end
        end
        return sink(chunk, error_value)
    end
    local request_options = {
        url = request.url,
        method = request.method or "GET",
        headers = headers,
        source = source,
        sink = sink_with_cancel,
        redirect = false,
    }
    -- LuaSocket HTTP accepts a custom creator, which lets cancel() close the
    -- active connection. LuaSec's HTTPS client does not consistently accept
    -- this option, so it relies on socketutil's bounded timeout instead.
    if self.socket and self.socket.tcp and not request.url:match("^https://") then
        request_options.create = function()
            active_socket = self.socket.tcp()
            return active_socket
        end
    end
    local returned = { pcall(client.request, request_options) }
    local ok = returned[1]
    local result, code, response_headers, status = returned[2], returned[3], returned[4], returned[5]
    if type(result) == "table" then
        response_headers = response_headers or structured_headers(result)
        code = code or result.code
        status = status or result.status or result.status_code
    end
    local returned_body, returned_headers, returned_status = response_parts(returned, 2)
    if not has_headers(response_headers) then
        response_headers = returned_headers or structured_headers(result)
            or structured_headers(code) or structured_headers(status)
    end
    if type(response_headers) ~= "table" then response_headers = {} end
    local body = table.concat(chunks)
    if body == "" then body = response_body(result) end
    if body == "" then body = structured_body(code) end
    if body == "" then body = structured_body(response_headers) end
    if body == "" then body = structured_body(status) end
    if body == "" then body = returned_body end
    local reported_status = response_status(code) or response_status(status) or returned_status
    -- Some Kindle LuaSec builds report success but never call a custom sink.
    -- Retry once with a plain table sink so the response body is still captured.
    -- Never replay a POST redirect: Base:_post_form must see it and follow it as GET.
    if ok and not canceled and not response_too_large and body == ""
        and ((request.method or "GET") == "GET"
            and (not reported_status or reported_status >= 200 and reported_status < 400)
            or (request.method or "GET") == "POST"
                and reported_status and reported_status >= 200 and reported_status < 300) then
        local fallback_options = copy(request_options)
        local fallback_chunks = {}
        -- Keep a plain sink: LuaSocket table requests return only a success
        -- flag and status, never the response body as the first return value.
        fallback_options.sink = self.ltn12.sink.table(fallback_chunks)
        fallback_options.source = request.body and self.ltn12.source.string(request.body) or nil
        local fallback_returned = { pcall(client.request, fallback_options) }
        local fallback_ok = fallback_returned[1]
        local fallback_result, fallback_code = fallback_returned[2], fallback_returned[3]
        local fallback_headers, fallback_status = fallback_returned[4], fallback_returned[5]
        local fallback_body, fallback_structured_headers, fallback_structured_status =
            response_parts(fallback_returned, 2)
        if fallback_ok and (fallback_result ~= nil or #fallback_chunks > 0) then
            result, code, response_headers, status = fallback_result, fallback_code,
                fallback_headers, fallback_status
            if type(fallback_result) == "string" then body = fallback_result end
            if body == "" and type(fallback_code) == "string" then body = fallback_code end
            if body == "" then body = table.concat(fallback_chunks) end
            if body == "" then body = fallback_body end
            if not has_headers(response_headers) then response_headers = fallback_structured_headers end
            if type(response_headers) ~= "table" then response_headers = {} end
            status = status or fallback_structured_status
        end
        -- A few Kindle LuaSec builds ignore both custom sinks but return the
        -- body only when the request uses their string-returning form.
        if body == "" and fallback_ok then
            local body_options = copy(request_options)
            body_options.sink = nil
            body_options.source = nil
            local body_returned = { pcall(client.request, body_options) }
            local body_ok = body_returned[1]
            local body_result, body_code = body_returned[2], body_returned[3]
            local body_headers, body_status = body_returned[4], body_returned[5]
            local body_fallback, body_structured_headers, body_structured_status = response_parts(body_returned, 2)
            if body_ok and type(body_result) == "string" and body_result ~= "" then
                result, code, response_headers, status = body_result, body_code,
                    body_headers, body_status
                body = body_result
                if not has_headers(response_headers) then response_headers = body_structured_headers end
                if type(response_headers) ~= "table" then response_headers = {} end
                status = status or body_structured_status
                if #body > (tonumber(request.max_bytes) or math.huge) then
                    response_too_large = true
                end
            elseif body_ok and body == "" and body_fallback ~= "" then
                body = body_fallback
                if not has_headers(response_headers) then response_headers = body_structured_headers end
                if type(response_headers) ~= "table" then response_headers = {} end
                status = status or body_structured_status
            end
        end
        -- Some Kindle LuaSec builds only return the body for the string URL
        -- overload. It cannot carry request headers, so source-level callers
        -- must still verify login markers instead of trusting this fallback.
        if body == "" and fallback_ok then
            local string_returned = { pcall(client.request, request.url) }
            local string_ok = string_returned[1]
            local string_result, string_code = string_returned[2], string_returned[3]
            local string_headers, string_status = string_returned[4], string_returned[5]
            local string_body, string_structured_headers, string_structured_status = response_parts(string_returned, 2)
            if string_ok and type(string_result) == "string" and string_result ~= "" then
                result, code, response_headers, status = string_result, string_code,
                    string_headers, string_status
                body = string_result
                if not has_headers(response_headers) then response_headers = string_structured_headers end
                if type(response_headers) ~= "table" then response_headers = {} end
                status = status or string_structured_status
                if #body > (tonumber(request.max_bytes) or math.huge) then
                    response_too_large = true
                end
            elseif string_ok and body == "" and string_body ~= "" then
                body = string_body
                if not has_headers(response_headers) then response_headers = string_structured_headers end
                if type(response_headers) ~= "table" then response_headers = {} end
                status = status or string_structured_status
            end
        end
    end
    if timeout_set and socketutil.reset_timeout then
        pcall(socketutil.reset_timeout, socketutil)
    end
    if #body > (tonumber(request.max_bytes) or math.huge) then response_too_large = true end
    if response_too_large then
        warn_response(self.logger, request, nil, body, "response_too_large")
        if not canceled then done(nil, response_headers or {}, body, "response_too_large") end
        return handle
    end
    if not ok then
        warn_response(self.logger, request, nil, body, tostring(result))
        if not canceled then done(nil, {}, body, tostring(result)) end
        return handle
    end
    if canceled then return handle end
    local response_code = response_status(code) or response_status(status)
    if not response_code then
        warn_response(self.logger, request, nil, body, tostring(code or status or "request failed"))
        done(nil, response_headers or {}, body, tostring(code or status or "request failed"))
    else
        local redirected = redirect_request(request, response_code, response_headers)
        if redirected and not canceled then
            return self:_request_sync(redirected, done)
        end
        warn_response(self.logger, request, response_code, body)
        done(response_code, response_headers or {}, body)
    end
    return handle
end

function Transport:request(request, done)
    if request.inline_response and self.native_http
        and type(self.native_http.request) == "function" then
        local finished, canceled
        local native_handle, fallback_handle
        local method = tostring(request.method or "GET"):upper()
        local function finish(status, headers, body, error_value)
            if finished or canceled then return end
            finished = true
            done(status, headers, body, error_value)
        end
        native_handle = self:_request_native(request, function(status, headers, body, error_value)
            -- Android Turbo can fail an authenticated GET before exposing a
            -- response. GET is idempotent, so recover once through the
            -- existing LuaSec path in a worker; never replay a login POST.
            if error_value and method == "GET"
                and (not status or tostring(error_value) == "empty_response") then
                -- HTML chapters can exceed the subprocess IPC budget just as
                -- images do (a 592-page Zero chapter is commonly over 128 KB).
                -- Re-enter the bounded non-inline path for every GET fallback
                -- so the worker writes a temporary file and only the parent
                -- reads it back; never serialize manga bytes in a Lua
                -- subprocess result table.
                local async_available = self.async and type(self.async.run) == "function"
                    and (type(self.async.available) ~= "function" or self.async.available())
                if not async_available then
                    -- Never fall through to synchronous DNS/TLS from a
                    -- KOReader UI callback when the subprocess runtime is
                    -- unavailable. Surface a retryable error instead.
                    finish(status, headers, body, error_value)
                    return
                end
                local background_request = copy(request)
                background_request.inline_response = false
                background_request.binary = nil
                fallback_handle = self:request(background_request,
                    function(fallback_status, fallback_headers, fallback_body, fallback_error)
                        finish(fallback_status, fallback_headers, fallback_body, fallback_error)
                    end)
                return
            end
            finish(status, headers, body, error_value)
        end)
        return {
            cancel = function()
                if finished or canceled then return end
                canceled = true
                if native_handle and type(native_handle.cancel) == "function" then
                    pcall(native_handle.cancel, native_handle)
                end
                if fallback_handle and type(fallback_handle.cancel) == "function" then
                    pcall(fallback_handle.cancel, fallback_handle)
                end
            end,
        }
    end
    if not self.async or type(self.async.run) ~= "function"
        or type(self.async.available) == "function" and not self.async.available() then
        if request.ui_nonblocking then
            done(nil, {}, "", "ui_nonblocking_unavailable")
            return { cancel = function() return true end }
        end
        return self:_request_sync(request, done)
    end

    local transport = self
    local body_path, path_error
    local body_file
    local function ensure_output()
        if body_file or body_path then return true end
        if self.temp_file then
            body_file, path_error = self.temp_file()
        else
            body_path, path_error = self.temp_name()
        end
        return body_file ~= nil or body_path ~= nil
    end
    if not request.inline_response then ensure_output() end
    local removed = false
    local function cleanup()
        if removed then return end
        removed = true
        if body_file then
            pcall(body_file.close, body_file)
        end
        if body_path then
            pcall(transport.remove_file, body_path)
        end
    end
    local function work()
        if not request.inline_response and not ensure_output() then
            return { error = "temporary response open failed: " .. tostring(path_error) }
        end
        local response
        transport:_request_sync(request, function(status, headers, body, error_value)
            response = { status = status, headers = headers or {}, error = error_value }
            if error_value then return end
            if request.inline_response and #tostring(body or "") <= INLINE_RESPONSE_LIMIT then
                response.body = tostring(body or "")
                return
            end
            if not ensure_output() then
                response.error = "temporary response open failed: " .. tostring(path_error)
                return
            end
            local file = body_file
            local open_error
            if not file then file, open_error = transport.open_file(body_path, "wb") end
            if not file then
                response.error = "temporary response open failed: " .. tostring(open_error)
                return
            end
            local wrote, write_error = file:write(body or "")
            if not wrote then
                response.error = "temporary response write failed: " .. tostring(write_error)
            end
            if body_file then
                local flushed, flush_error = file:flush()
                if not flushed and not response.error then
                    response.error = "temporary response flush failed: " .. tostring(flush_error)
                end
            else
                local closed, close_error = file:close()
                if closed == nil and not response.error then
                    response.error = "temporary response close failed: " .. tostring(close_error)
                end
            end
            if not response.error and not body_file then response.body_path = body_path end
        end)
        return response or { error = "request did not finish" }
    end
    local async_handle = self.async.run(work, function(ok, response, async_error)
        if not ok or type(response) ~= "table" then
            cleanup()
            warn_response(transport.logger, request, nil, "", async_error or "background request failed")
            return done(nil, {}, "", async_error or "background request failed")
        end
        if response.error then
            cleanup()
            warn_response(transport.logger, request, response.status, "", response.error)
            return done(response.status, response.headers or {}, "", response.error)
        end
        if response.body ~= nil then
            cleanup()
            return done(response.status, response.headers or {}, response.body)
        end
        if body_file then
            local position, seek_error = body_file:seek("set", 0)
            if not position then
                cleanup()
                return done(nil, response.headers or {}, "", "temporary response seek failed: " .. tostring(seek_error))
            end
        else
            body_file, path_error = transport.open_file(response.body_path or body_path, "rb")
            if not body_file then
                cleanup()
                return done(nil, response.headers or {}, "", "temporary response read failed: " .. tostring(path_error))
            end
        end
        local body, read_error = body_file:read("*a")
        cleanup()
        if body == nil then
            return done(nil, response.headers or {}, "", "temporary response read failed: " .. tostring(read_error))
        end
        return done(response.status, response.headers or {}, body or "")
    end, {
        timeout = math.max(1, tonumber(request.timeout) or self.timeout) + 2,
        max_payload_bytes = request.inline_response and 128 * 1024 or 16384,
        on_reaped = cleanup,
    })
    if async_handle and type(async_handle.cancel) == "function" then
        local cancel = async_handle.cancel
        async_handle.cancel = function(handle, ...)
            cleanup()
            return cancel(handle, ...)
        end
    end
    return async_handle
end

function Transport:request_file(request, part_path, callbacks)
    return require("mangaweb.file_transport").request(self, request, part_path, callbacks)
end

return Transport
