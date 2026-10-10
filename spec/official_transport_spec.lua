local Transport = require('mangaweb.transport')
local Http = require('mangaweb.http')
local Zero = require('mangaweb.sources.zero')
local posts, gets, outcome = 0, 0, nil
local active = '<a id="btn-fav" class="btn-act btn-fav active">已收藏</a>'
    .. '<script>data: {action: "toggle_fav", formhash: "abcd1234"}</script>'
local client = { request = function(options)
    if type(options) == 'string' then return '', 200, {} end
    if options.method == 'POST' then
        posts = posts + 1
        -- Kindle LuaSec may return 200 without ever filling the supplied sink.
        return 1, 200, {}
    end
    gets = gets + 1
    options.sink(active)
    return 1, 200, {}
end }
local ltn12 = { source = { string = function(value)
    local sent = false
    return function() if not sent then sent = true; return value end end
end }, sink = {table = function(chunks)
    return function(chunk) if chunk then chunks[#chunks + 1] = chunk end; return 1 end
end} }
local transport = Transport:new{http=client,https=client,ltn12=ltn12,socketutil={},socket={},
    async=false,native_http=false}
-- The asynchronous worker executes this same backend. Exercise the real request spec unchanged.
transport.request = transport._request_sync
local source = Zero:new{origin='https://zero.example',http=Http:new{transport=transport},auth={
    active_cookie=function() return 'zero_auth=test' end,
    headers=function() return {Cookie='zero_auth=test'} end,
}}
source:remove_favorite('12',{on_success=function() outcome='success' end,
    on_error=function(err) outcome=err.code end})
assert(posts == 1, 'an empty response must not make the real Http/Transport replay the favorite toggle')
assert(gets == 1 and outcome == 'favorite_remove_uncertain')

-- The existing GET empty-sink recovery remains available to other source calls.
local attempts, body = 0, nil
client.request = function(options)
    attempts = attempts + 1
    if attempts == 2 then options.sink('read-only body') end
    return 1, 200, {}
end
transport:_request_sync({url='https://zero.example/list',method='GET'},function(_,_,value) body=value end)
assert(attempts == 2 and body == 'read-only body')
print('official_transport_spec: passed')
