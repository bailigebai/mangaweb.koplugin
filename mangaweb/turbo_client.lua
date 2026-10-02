local UIManager = require("ui/uimanager")

local TurboClient = {}
TurboClient.__index = TurboClient

local loop, pump, inflight, patched

local function patch_turbo()
    if patched then return end
    patched = true
    local crypto_ok, crypto = pcall(require, "turbo.crypto")
    if crypto_ok and type(crypto) == "table" then
        if type(crypto.ssl_do_handshake) == "function" then
            local original = crypto.ssl_do_handshake
            crypto.ssl_do_handshake = function(stream)
                local socket = stream and stream._ssl
                local host = stream and stream._ssl_hostname
                if socket and not stream._mangaweb_sni_done and type(socket.sni) == "function"
                    and type(host) == "string" and not host:find(":", 1, true)
                    and not host:match("^[%d%.]+$") then
                    stream._mangaweb_sni_done = true
                    pcall(socket.sni, socket, host)
                end
                return original(stream)
            end
        end
        if type(crypto.ssl_create_client_context) == "function" then
            local original = crypto.ssl_create_client_context
            crypto.ssl_create_client_context = function(cert_file, key_file, ca_path, verify, ssl_version)
                if verify then return original(cert_file, key_file, ca_path, verify, ssl_version) end
                local ssl = require("ssl")
                local context, err = ssl.newcontext({
                    mode = "client", protocol = "sslv23", key = key_file,
                    certificate = cert_file, options = { "all" },
                })
                if not context then return -1, err end
                return 0, context
            end
        end
    end

    local stream_ok, stream_module = pcall(require, "turbo.iostream")
    local IOStream = stream_ok and type(stream_module) == "table" and stream_module.IOStream
    if type(IOStream) == "table" and type(IOStream.connect) == "function"
        and type(IOStream._handle_connect_fail) == "function"
        and not IOStream._book_connect_fail_patched
        and not IOStream._mangaweb_connect_fail_patched then
        local original_connect = IOStream.connect
        local original_fail = IOStream._handle_connect_fail
        IOStream.connect = function(stream, address, port, family, callback, fail_callback, argument)
            stream._handle_connect_fail = function(first, second)
                if type(first) ~= "table" then return original_fail(stream, first) end
                return original_fail(first, second)
            end
            return original_connect(stream, address, port, family, callback, fail_callback, argument)
        end
        IOStream._mangaweb_connect_fail_patched = true
    end
end

local function pump_once(target)
    local co_callbacks = target._co_cbs
    if type(co_callbacks) == "table" and #co_callbacks > 0 then
        target._co_cbs = {}
        for index = 1, #co_callbacks do
            if co_callbacks[index] then
                target:_resume_coroutine(co_callbacks[index][1], co_callbacks[index][2])
            end
        end
    end
    local callbacks = target._callbacks
    if type(callbacks) == "table" then
        target._callbacks = {}
        for index = 1, #callbacks do target:_run_callback(callbacks[index]) end
    end
    local timeout_count = target._timeouts_sz
    if type(timeout_count) == "number" and timeout_count > 0 then
        local util = require("turbo.util")
        local now, visited, index = util.gettimemonotonic(), 0, 0
        while visited ~= timeout_count do
            local item = target._timeouts[index]
            if item ~= nil then
                visited = visited + 1
                if item:timed_out(now) == 0 then
                    target:_run_callback({ item:callback() })
                    target._timeouts[index] = nil
                    target._timeouts_sz = target._timeouts_sz - 1
                end
            end
            index = index + 1
            if index > timeout_count + 64 then break end
        end
    end
    if type(target._event_poll) == "function" then target:_event_poll(0) end
end

local function kick()
    if not loop or not inflight or inflight == 0 then return end
    local ok, err = pcall(pump_once, loop)
    if not ok then
        local logger_ok, logger = pcall(require, "logger")
        if logger_ok and logger and type(logger.warn) == "function" then
            pcall(logger.warn, "MangaWeb Turbo pump", tostring(err))
        end
    end
end

local function boot()
    TURBO_SSL = true
    __TURBO_USE_LUASOCKET__ = true
    if loop then patch_turbo(); return true end
    local ok, turbo = pcall(require, "turbo")
    if not ok or type(turbo) ~= "table" or not turbo.ioloop then return false end
    local made, created = pcall(turbo.ioloop.IOLoop)
    if not made or type(created) ~= "table" then return false end
    loop = created
    patch_turbo()
    return true
end

local function acquire()
    if not boot() then return nil end
    inflight = (inflight or 0) + 1
    if inflight == 1 then
        pump = pump or { waitEvent = kick, stop = function() end }
        UIManager:insertZMQ(pump)
        UIManager:nextTick(kick)
        UIManager:preventStandby()
    end
    return loop
end

local function release()
    if not inflight or inflight == 0 then return end
    inflight = inflight - 1
    if inflight == 0 then
        UIManager:unschedule(kick)
        if pump then UIManager:removeZMQ(pump); pump = nil end
        UIManager:allowStandby()
    end
end

local function header(headers, name)
    name = name:lower()
    for key, value in pairs(headers or {}) do
        if type(key) == "string" and key:lower() == name then return value end
    end
end

local function add_headers(output, values)
    for name, value in pairs(values or {}) do
        if type(name) == "string" and value ~= nil and name:lower() ~= "content-length" then
            if type(output.get) == "function" and output:get(name, true) ~= nil
                and type(output.set) == "function" then
                output:set(name, tostring(value), true)
            elseif type(output.add) == "function" then
                output:add(name, tostring(value))
            end
        end
    end
end

local function response_error(response)
    if not response then return "network request failed" end
    if not response.error then return nil end
    if type(response.error) == "table" then
        return response.error.message or response.error.code or "network request failed"
    end
    return tostring(response.error)
end

local function close_client(client)
    if client and client.iostream and type(client.iostream.closed) == "function"
        and not client.iostream:closed() and type(client.iostream.close) == "function" then
        pcall(client.iostream.close, client.iostream)
    end
end

function TurboClient.available()
    return boot()
end

function TurboClient:new()
    return setmetatable({}, self)
end

function TurboClient:request(request, callback)
    request = request or {}
    local state = { canceled = false, done = false }
    local selected_loop = acquire()
    local function settle(response, err)
        if state.done then return end
        state.done = true
        state.client = nil
        if not state.canceled and type(callback) == "function" then
            response = type(response) == "table" and response or {}
            if err then response.error = err end
            callback(response)
        end
        if selected_loop then release() end
    end
    if not selected_loop then
        settle(nil, "turbo looper unavailable")
        return { cancel = function() end }
    end

    selected_loop:add_callback(function()
        if state.canceled then settle(); return end
        local ok, turbo = pcall(require, "turbo")
        if not ok then settle(nil, turbo); return end
        if turbo.log and turbo.log.categories then
            turbo.log.categories.success = false
            turbo.log.categories.warning = false
        end
        local made, client = pcall(turbo.async.HTTPClient, { verify_ca = false }, selected_loop)
        if not made or type(client) ~= "table" then settle(nil, client); return end
        state.client = client

        local fetched, future = pcall(client.fetch, client, request.url, {
            method = request.method or "GET", body = request.body,
            request_timeout = request.request_timeout or request.timeout or 20,
            connect_timeout = request.connect_timeout or 10,
            allow_redirects = request.allow_redirects,
            max_redirects = request.allow_redirects == false and 0 or request.max_redirects,
            user_agent = header(request.headers, "User-Agent"),
            on_headers = function(output) add_headers(output, request.headers) end,
        })
        if not fetched then settle(nil, future); return end
        local response = coroutine.yield(future)
        settle(response, response_error(response))
    end)

    return {
        cancel = function()
            if state.done or state.canceled then return end
            state.canceled = true
            if not state.client then settle(); return end
            if type(state.client._throw_error) == "function"
                and pcall(state.client._throw_error, state.client, -10, "request canceled") then return end
            close_client(state.client)
            settle()
        end,
    }
end

return TurboClient
