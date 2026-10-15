-- Android keeps user data outside the KOReader runtime. The installed
-- runtime CA must allow a request without a certificate in user storage.
package.preload['datastorage'] = function()
    return { getDataDir = function() return '/storage/emulated/0/koreader' end }
end
local response_body = '{"ok":false,"error":"invalid_key"}'
package.preload['rapidjson'] = function()
    return { decode = function(raw)
        assert(raw == response_body)
        return { ok = false, error = 'invalid_key' }
    end }
end
local Transport = require('mangaweb.license_transport')
local payload = {
    product = 'mangaweb-image-reader', key = '2345-6789-ABCD',
    device_id = string.rep('a', 64),
}

local function request(options)
    options = options or {}
    local state = { requests = 0, wrapped = 0, closed = 0 }
    local certificate = { checkhost = function(_, host)
        return host == Transport.HOST and options.wrong_host ~= true
    end }
    local wire = {
        settimeout = function() return 1 end,
        connect = function(_, host, port)
            assert(host == Transport.HOST and port == 443)
            return 1
        end,
        sni = function(_, host) assert(host == Transport.HOST) end,
        dohandshake = function()
            if options.untrusted then return nil, 'certificate verify failed' end
            return 1
        end,
        getpeercertificate = function() return certificate end,
        close = function() state.closed = state.closed + 1 end,
    }
    local dependencies = {
        ca_file = options.ca_file,
        read_file = function(path)
            if not options.missing_ca
                and path == (options.ca_file or 'data/ca-bundle.crt') then
                return 'fixture certificate bundle'
            end
        end,
        socket = { tcp = function() return wire end, gettime = function() return 0 end },
        ssl = { wrap = function(connection, config)
            assert(connection == wire)
            assert(config.verify == 'peer', 'activation must verify the certificate chain')
            assert(config.cafile == (options.ca_file or 'data/ca-bundle.crt'))
            state.wrapped = state.wrapped + 1
            return wire
        end },
        ltn12 = { source = { string = function(body)
            return function() local chunk = body; body = nil; return chunk end
        end } },
        http = { request = function(spec)
            state.requests = state.requests + 1
            assert(spec.url == Transport.ENDPOINT and spec.redirect == false)
            local connection = spec.create()
            local connected, err = connection:connect(Transport.HOST, 443)
            if not connected then return nil, err end
            assert(spec.source() == '{"product":"mangaweb-image-reader","key":"2345-6789-ABCD","device_id":"'
                .. string.rep('a', 64) .. '"}')
            spec.sink(response_body)
            return 1, 400, { ['Content-Type'] = 'application/json' }
        end },
    }
    local result, err = Transport.request_sync(payload, dependencies)
    return result, err, state
end

local result, err, state = request()
assert(result and result.error == 'invalid_key' and err == nil,
    'Android activation must reach the server with the runtime CA, got ' .. tostring(err))
assert(state.requests == 1 and state.wrapped == 1 and state.closed == 1)

result, err = request{ ca_file = '/custom/ca.crt' }
assert(result and result.error == 'invalid_key' and err == nil)

result, err, state = request{ missing_ca = true }
assert(result == nil and err == 'tls_unavailable' and state.requests == 0)

result, err, state = request{ wrong_host = true }
assert(result == nil and err == 'tls_error' and state.closed == 1)

result, err, state = request{ untrusted = true }
assert(result == nil and err == 'tls_error' and state.closed == 1)
