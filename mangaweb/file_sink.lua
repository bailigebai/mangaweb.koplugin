-- Worker-only HTTP-to-file sink. Never return the response body to the UI.
local FileSink = {}

local MAX_BYTES = 64 * 1048576
local BLOCK_BYTES = 64 * 1024

-- Never send backend error strings (which may contain private URLs) through
-- IPC/logging. Preserve only the failure category needed for device diagnosis.
local function failure_cause(value)
    local message = tostring(value or ""):lower()
    if message:find("timeout", 1, true) or message:find("timed out", 1, true) then return "timeout" end
    if message:find("host not found", 1, true) or message:find("not known", 1, true)
        or message:find("name resolution", 1, true) or message:find("getaddrinfo", 1, true) then
        return "dns_error"
    end
    if message:find("ssl", 1, true) or message:find("tls", 1, true)
        or message:find("certificate", 1, true) then return "tls_error" end
    if message:find("closed", 1, true) or message:find("reset", 1, true)
        or message:find("refused", 1, true) then return "connection_closed" end
    return "transport_failure"
end

local function status_number(value)
    if type(value) == "table" then
        return status_number(value.status or value.status_code or value.code)
    end
    local number = tonumber(value)
    if not number then
        number = tonumber(tostring(value or ""):match("^[Hh][Tt][Tt][Pp]/[^%s]+%s+(%d%d%d)"))
    end
    return number and number >= 100 and number <= 599 and number or nil
end

local function header(headers, wanted)
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        if tostring(key):lower() == wanted then
            if type(value) == "table" then value = value[1] end
            return value
        end
    end
end

local function safe_headers(headers)
    local result = {}
    local content_type = header(headers, "content-type")
    local content_length = header(headers, "content-length")
    if type(content_type) == "string" and #content_type <= 128 then
        result["Content-Type"] = content_type
    end
    if tonumber(content_length) and tonumber(content_length) >= 0 then
        result["Content-Length"] = tostring(content_length)
    end
    return result
end

local function close_file(file)
    local ok, result = pcall(file.close, file)
    return ok and result ~= nil and result ~= false
end

local function copy_headers(headers)
    local result = {}
    for key, value in pairs(headers or {}) do result[key] = value end
    return result
end

function FileSink.download(request, part_path, deps)
    request, deps = request or {}, deps or {}
    local limit = math.min(MAX_BYTES, tonumber(request.max_bytes) or MAX_BYTES)
    if limit < 1 or type(part_path) ~= "string" or part_path == "" then
        return { headers = {}, bytes = 0, error = "storage_error" }
    end
    if tonumber(request.expected_bytes) and tonumber(request.expected_bytes) > limit then
        return { headers = {}, bytes = 0, error = "response_too_large" }
    end
    local current = request
    while true do
        local selected, client = pcall(deps.client_for or function() end, current.url)
        if not selected or not client or type(client.request) ~= "function" then
            return { headers = {}, bytes = 0, error = "transport_error" }
        end
        local opened, file = pcall(deps.open_file or io.open, part_path, "wb")
        if not opened or not file then
            return { headers = {}, bytes = 0, error = "storage_error" }
        end
        local bytes, saw_chunk, sink_error, sink_cause = 0, false, nil, nil
        local function sink(chunk, error_value)
            if error_value then
                sink_error = "transport_error"
                sink_cause = failure_cause(error_value)
                return nil, sink_error
            end
            if chunk == nil then return 1 end
            if type(chunk) ~= "string" then
                sink_error = "transport_error"
                return nil, sink_error
            end
            saw_chunk = true
            local offset = 1
            while offset <= #chunk do
                local stop = math.min(#chunk, offset + BLOCK_BYTES - 1)
                local slice = chunk:sub(offset, stop)
                if bytes + #slice > limit then
                    sink_error = "response_too_large"
                    return nil, sink_error
                end
                local ok, written = pcall(file.write, file, slice)
                if not ok or written == nil or written == false
                    or type(written) == "number" and written ~= #slice then
                    sink_error = "storage_error"
                    return nil, sink_error
                end
                bytes = bytes + #slice
                offset = stop + 1
            end
            return 1
        end
        local socketutil = deps.socketutil
        if socketutil and type(socketutil.set_timeout) == "function" then
            pcall(socketutil.set_timeout, socketutil, 30, 180)
        end
        local headers = copy_headers(current.headers)
        if headers["Accept-Encoding"] == nil then headers["Accept-Encoding"] = "identity" end
        local ok, result, code, response_headers, status = pcall(client.request, {
            url = current.url, method = "GET", headers = headers,
            redirect = false, sink = sink,
        })
        if socketutil and type(socketutil.reset_timeout) == "function" then
            pcall(socketutil.reset_timeout, socketutil)
        end
        local closed = close_file(file)
        local response_code = status_number(code) or status_number(status)
            or status_number(result)
        local filtered = safe_headers(response_headers)
        if sink_error or not closed then
            return { status = response_code, headers = filtered, bytes = bytes,
                error = sink_error or "storage_error", cause = sink_cause }
        end
        if not ok or result == nil or not response_code then
            return { status = response_code, headers = filtered, bytes = bytes,
                error = "transport_error", cause = failure_cause(not ok and result or code) }
        end
        if response_code >= 300 and response_code < 400 then
            local accepted, redirected = pcall(deps.redirect_request or function() end,
                current, response_code, response_headers)
            if not accepted or not redirected then
                return { status = response_code, headers = filtered, bytes = bytes,
                    error = "redirect_blocked" }
            end
            current = redirected
        else
            if response_code < 200 or response_code >= 300 then
                return { status = response_code, headers = filtered, bytes = bytes,
                    error = "http_error" }
            end
            if bytes == 0 and (type(result) == "string" and result ~= "") then
                return { status = response_code, headers = filtered, bytes = 0,
                    error = "stream_sink_unavailable" }
            end
            if not saw_chunk or bytes == 0 then
                return { status = response_code, headers = filtered, bytes = 0,
                    error = "empty_result" }
            end
            if tonumber(filtered["Content-Length"])
                and tonumber(filtered["Content-Length"]) > limit then
                return { status = response_code, headers = filtered, bytes = bytes,
                    error = "response_too_large" }
            end
            return { status = response_code, headers = filtered, bytes = bytes }
        end
    end
end

return FileSink
