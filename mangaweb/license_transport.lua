local LicenseJson = require("mangaweb.license_json")
local Protocol = require("mangaweb.license_protocol")

local Transport = {}
Transport.__index = Transport

Transport.HOST = "mangaweb-image-reader-gateway.pages.dev"
Transport.ENDPOINT = "https://" .. Transport.HOST .. "/activate"
Transport.TIMEOUT = 10
Transport.MAX_RESPONSE = 8192

local SAFE_ERRORS = {
    invalid_request = true,
    invalid_key = true,
    key_bound_to_other_device = true,
    rate_limited = true,
    service_unavailable = true,
    http_unavailable = true,
    proxy_not_supported = true,
    tls_unavailable = true,
    dns_error = true,
    server_unreachable = true,
    tls_error = true,
    timeout = true,
    response_too_large = true,
    redirect_refused = true,
    server_error = true,
    invalid_response = true,
    network_error = true,
}

local function safe_error(code, fallback)
    return SAFE_ERRORS[code] and code or (fallback or "network_error")
end

local function normalized_name(value)
    if type(value) ~= "string" or value == "" or value:find("[^A-Za-z0-9.*%-]") then
        return nil
    end
    value = value:lower():gsub("%.$", "")
    return value ~= "" and value or nil
end

local function hostname_matches(host, name)
    host, name = normalized_name(host), normalized_name(name)
    if not host or not name then return false end
    if name == host then return true end
    if name:sub(1, 2) ~= "*." or name:find("*", 2, true) then return false end
    local suffix = name:sub(2)
    if #host <= #suffix or host:sub(-#suffix) ~= suffix then return false end
    local prefix = host:sub(1, #host - #suffix)
    return prefix ~= "" and prefix:find(".", 1, true) == nil
end

function Transport.certificate_matches(certificate, host)
    if type(certificate) ~= "table" and type(certificate) ~= "userdata" then return false end
    host = normalized_name(host)
    if not host then return false end

    if type(certificate.checkhost) == "function" then
        local success, matches = pcall(certificate.checkhost, certificate, host)
        return success and matches == true
    end

    if type(certificate.extensions) == "function" then
        local success, extensions = pcall(certificate.extensions, certificate)
        if not success or type(extensions) ~= "table" then return false end
        local names = extensions["2.5.29.17"]
        if names ~= nil then
            if type(names) ~= "table" or type(names.dNSName) ~= "table" then return false end
            for _, name in ipairs(names.dNSName) do
                if hostname_matches(host, name) then return true end
            end
            return false
        end
    end

    if type(certificate.subject) ~= "function" then return false end
    local success, subject = pcall(certificate.subject, certificate)
    if not success or type(subject) ~= "table" then return false end
    for _, field in ipairs(subject) do
        if type(field) == "table"
            and (field.oid == "2.5.4.3" or field.name == "commonName")
            and hostname_matches(host, field.value) then
            return true
        end
    end
    return false
end

local function exact_payload(payload)
    if type(payload) ~= "table" or getmetatable(payload) ~= nil then return false end
    local count = 0
    for key in pairs(payload) do
        if key ~= "product" and key ~= "key" and key ~= "device_id" then return false end
        count = count + 1
    end
    if count ~= 3 or payload.product ~= Protocol.PRODUCT_ID then return false end
    local canonical = Protocol.normalize_key(payload.key)
    return canonical ~= nil and canonical == payload.key
        and type(payload.device_id) == "string" and #payload.device_id == 64
        and payload.device_id:match("^[0-9a-f]+$") ~= nil
end

local function encode_payload(payload)
    return '{"product":"' .. payload.product .. '","key":"' .. payload.key
        .. '","device_id":"' .. payload.device_id .. '"}'
end

local function read_ca(path, reader)
    if reader then
        local success, value = pcall(reader, path)
        return success and value ~= nil and value ~= false and value ~= ""
    end
    local handle = io.open(path, "rb")
    if not handle then return false end
    local value = handle:read(1)
    handle:close()
    return value ~= nil
end

local function header_value(headers, expected)
    if type(headers) ~= "table" then return nil end
    expected = expected:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == expected then
            if type(value) == "table" then value = value[1] end
            return type(value) == "string" and value or tostring(value or "")
        end
    end
end

local function json_content_type(value)
    if type(value) ~= "string" then return false end
    value = value:lower():gsub("^%s+", ""):gsub("%s+$", "")
    return value == "application/json"
        or value:match('^application/json%s*;%s*charset%s*=%s*"?utf%-8"?%s*$') ~= nil
end

local function classify_connect_error(value)
    value = tostring(value or ""):lower()
    if value == "timeout" then return "timeout" end
    if value:find("host not found", 1, true)
        or value:find("name resolution", 1, true)
        or value:find("name or service not known", 1, true)
        or value:find("nodename nor servname", 1, true)
        or value:find("no address associated", 1, true) then
        return "dns_error"
    end
    return "server_unreachable"
end

local function response_matches_status(status, response)
    if status == 200 then return response.ok == true end
    if status == 400 then
        return response.ok == false
            and (response.error == "invalid_request" or response.error == "invalid_key")
    end
    if status == 409 then
        return response.ok == false and response.error == "key_bound_to_other_device"
    end
    if status == 429 then return response.ok == false and response.error == "rate_limited" end
    if status == 503 then
        return response.ok == false and response.error == "service_unavailable"
    end
    return false
end

function Transport.request_sync(payload, dependencies)
    dependencies = dependencies or {}
    if not exact_payload(payload) then return nil, "invalid_request" end

    local http_ok, http = pcall(function()
        return dependencies.http or require("socket.http")
    end)
    local socket_ok, socket = pcall(function()
        return dependencies.socket or require("socket")
    end)
    local ssl_ok, ssl = pcall(function()
        return dependencies.ssl or require("ssl")
    end)
    local ltn12_ok, ltn12 = pcall(function()
        return dependencies.ltn12 or require("ltn12")
    end)
    if not http_ok or not socket_ok or not ssl_ok or not ltn12_ok
        or type(http) ~= "table" or type(socket) ~= "table" or type(ssl) ~= "table"
        or type(ltn12) ~= "table" then
        return nil, "http_unavailable"
    end
    if http.PROXY then return nil, "proxy_not_supported" end

    local ca_file = dependencies.ca_file
    if not ca_file then
        local storage_ok, storage = pcall(require, "datastorage")
        if not storage_ok or not storage or type(storage.getDataDir) ~= "function" then
            return nil, "tls_unavailable"
        end
        ca_file = storage:getDataDir() .. "/data/ca-bundle.crt"
    end
    if not read_ca(ca_file, dependencies.read_file) then return nil, "tls_unavailable" end
    if type(socket.gettime) ~= "function" or type(socket.tcp) ~= "function"
        or type(http.request) ~= "function" or type(ssl.wrap) ~= "function"
        or type(ltn12.source) ~= "table" or type(ltn12.source.string) ~= "function" then
        return nil, "http_unavailable"
    end

    local body = encode_payload(payload)
    if #body > 512 then return nil, "invalid_request" end

    local connections = {}
    local stage = "network_error"
    local overflow, expired = false, false
    local chunks, size = {}, 0
    local started = socket.gettime()
    if type(started) ~= "number" then return nil, "network_error" end
    local deadline = started + Transport.TIMEOUT

    local called, result, reason = pcall(function()
        local function create_connection()
            local connection = { socket = assert(socket.tcp()) }
            connections[#connections + 1] = connection

            function connection:close()
                if self.socket then
                    pcall(self.socket.close, self.socket)
                    self.socket = nil
                end
                return true
            end

            function connection:settimeout()
                local remaining = deadline - socket.gettime()
                if remaining <= 0 then return nil, "timeout" end
                local block = math.min(5, remaining)
                local block_ok = self.socket:settimeout(block, "b")
                if block_ok == nil or block_ok == false then return nil, "timeout" end
                return self.socket:settimeout(remaining, "t")
            end

            function connection:connect(request_host, request_port)
                if request_host ~= Transport.HOST or tonumber(request_port) ~= 443 then
                    self:close()
                    return nil, "wrong_origin"
                end
                if not self:settimeout() then self:close(); return nil, "timeout" end
                stage = "server_unreachable"
                local connected, connect_reason = self.socket:connect(request_host, 443)
                if not connected then
                    stage = classify_connect_error(connect_reason)
                    self:close()
                    return nil, stage
                end

                stage = "tls_error"
                local wrapped = ssl.wrap(self.socket, {
                    mode = "client",
                    protocol = "any",
                    verify = "peer",
                    cafile = ca_file,
                    options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
                })
                if not wrapped then self:close(); return nil, "tls_error" end
                self.socket = wrapped
                if not self:settimeout() then self:close(); return nil, "timeout" end
                if type(self.socket.sni) ~= "function" then
                    self:close()
                    return nil, "tls_error"
                end
                local sni_ok = pcall(self.socket.sni, self.socket, Transport.HOST)
                if not sni_ok then
                    self:close()
                    return nil, "tls_error"
                end
                local secured, handshake_reason = self.socket:dohandshake()
                if not secured then
                    stage = handshake_reason == "timeout" and "timeout" or "tls_error"
                    self:close()
                    return nil, stage
                end
                local certificate = self.socket:getpeercertificate()
                if not Transport.certificate_matches(certificate, Transport.HOST) then
                    self:close()
                    return nil, "tls_error"
                end
                stage = "network_error"
                return 1
            end

            return setmetatable(connection, {
                __index = function(self, name)
                    local active = rawget(self, "socket")
                    local method = active and active[name]
                    if type(method) ~= "function" then return nil end
                    return function(_, ...)
                        if not self:settimeout() then return nil, "timeout" end
                        return method(self.socket, ...)
                    end
                end,
            })
        end

        local received, status, headers = http.request{
            url = Transport.ENDPOINT,
            method = "POST",
            redirect = false,
            create = create_connection,
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = #body,
                Accept = "application/json",
                ["User-Agent"] = "MangaWeb/0.8.61 (KOReader)",
            },
            source = ltn12.source.string(body),
            sink = function(chunk)
                if socket.gettime() > deadline then
                    expired = true
                    return nil, "timeout"
                end
                if chunk then
                    size = size + #chunk
                    if size > Transport.MAX_RESPONSE then
                        overflow = true
                        return nil, "response_too_large"
                    end
                    chunks[#chunks + 1] = chunk
                end
                return 1
            end,
        }

        if overflow then return nil, "response_too_large" end
        if expired or socket.gettime() > deadline then return nil, "timeout" end
        if not received then return nil, safe_error(status, stage) end
        status = tonumber(status)
        if not status then return nil, "network_error" end
        if status >= 300 and status < 400 then return nil, "redirect_refused" end
        if status ~= 200 and status ~= 400 and status ~= 409
            and status ~= 429 and status ~= 503 then
            return nil, status >= 500 and "server_error" or "invalid_response"
        end
        if not json_content_type(header_value(headers, "content-type")) then
            return nil, "invalid_response"
        end
        local decoded = LicenseJson.decode_response(table.concat(chunks))
        if not decoded or not response_matches_status(status, decoded) then
            return nil, "invalid_response"
        end
        return decoded
    end)

    for _, connection in ipairs(connections) do connection:close() end
    if not called then return nil, safe_error(stage, "network_error") end
    if result ~= nil then return result end
    return nil, safe_error(reason, "network_error")
end

local function schedule(scheduler, callback)
    if scheduler and type(scheduler.scheduleIn) == "function" then
        local success, scheduled = pcall(scheduler.scheduleIn, scheduler, 0, callback)
        if success and scheduled ~= false then return true end
    end
    callback()
    return false
end

function Transport:new(dependencies)
    dependencies = dependencies or {}
    local async = dependencies.async
    if async == nil then
        local success, module = pcall(require, "mangaweb.async")
        async = success and module or false
    end
    local scheduler = dependencies.scheduler
    if scheduler == nil then
        local success, module = pcall(require, "ui/uimanager")
        scheduler = success and module or false
    end
    return setmetatable({
        dependencies = dependencies,
        async = async,
        scheduler = scheduler,
        request_sync_fn = dependencies.request_sync or Transport.request_sync,
        async_options = dependencies.async_options or {},
    }, self)
end

function Transport:request(payload, callbacks)
    callbacks = callbacks or {}
    local handle = { canceled = false, finished = false }
    local child

    local function finish(kind, value)
        if handle.canceled or handle.finished then return end
        handle.finished = true
        local callback = callbacks[kind]
        if type(callback) == "function" then pcall(callback, value) end
    end

    function handle:cancel()
        if self.canceled then return end
        self.canceled = true
        if child and type(child.cancel) == "function" then pcall(child.cancel, child) end
    end

    local available = false
    if self.async and type(self.async.available) == "function" then
        local success, value = pcall(self.async.available, self.async_options)
        available = success and value == true
    end
    if not available then
        schedule(self.scheduler, function() finish("on_error", "http_unavailable") end)
        return handle
    end

    local run_ok, run_result = pcall(self.async.run, function()
        local response, code = self.request_sync_fn(payload, self.dependencies)
        return { response = response, error = safe_error(code, "network_error") }
    end, function(success, result, async_error)
        if handle.canceled or handle.finished then return end
        if not success or type(result) ~= "table" then
            local code = async_error == "async timeout" and "timeout" or "network_error"
            finish("on_error", code)
        elseif type(result.response) == "table" then
            finish("on_success", result.response)
        else
            finish("on_error", safe_error(result.error, "network_error"))
        end
    end, {
        scheduler = self.async_options.scheduler or self.scheduler,
        ffiutil = self.async_options.ffiutil,
        timeout = 11,
        max_payload_bytes = 16384,
        poll_interval = self.async_options.poll_interval,
    })
    if run_ok then
        child = run_result
    else
        schedule(self.scheduler, function() finish("on_error", "http_unavailable") end)
    end
    return handle
end

return Transport
