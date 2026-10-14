local Http=require('mangaweb.http')
local Settings=require('mangaweb.ui.settings')
local cases={
    {'temporary failure in name resolution','dns_error'},
    {'host not found','dns_error'},
    {'Connect timed out after 10 secs','request_timeout'},
    {'async timeout','request_timeout'},
    {'certificate verify failed','tls_error'},
    {'connection refused','network_error'},
    {'private unknown response Cookie=secret','transport_error'},
}
for _,case in ipairs(cases)do
    local got
    local http=Http:new{transport={request=function(_,spec,done)done(nil,{},'',case[1]);return{}end}}
    http:get('https://example.com',{site_id='zero',stage='login_form'}, {on_error=function(e)got=e end})
    assert(got.code==case[2],case[1]..' must be classified as '..case[2])
    assert(not tostring(got.user_message):find('secret',1,true))
    local page=Settings:new{source={id='zero',meta=function()return{}end}}
    local model=page:_model(got.code)
    assert(model.user_message and not model.user_message:find('HTTPS',1,true) or got.code=='tls_error',
        'DNS and timeouts must not be presented as TLS failures')
end
print('network_errors_spec: passed')
