local Api=require('mangaweb.bilibili_api')
local specs,successes,errors,logs={},0,0,{}
local response={code=0,data={url='https://passport.bilibili.com/h5-app/passport/login/scan?key=test',qrcode_key='test_key'}}
local http={request=function(_,spec,cb)
    specs[#specs+1]=spec
    cb.on_success('body',{status=200,headers={}})
    cb.on_error({code='transport_error',detail='test_cookie'})
    return {cancel=function() end}
end}
local api=Api:new{http=http,json={decode=function() return response end,encode=function() return '{}' end},
    logger={warn=function(...) logs[#logs+1]=table.concat({...},' ') end}}
local callbacks={on_success=function() successes=successes+1 end,on_error=function(error)
    errors=errors+1;assert(not error.detail and not error.body)
end}
api:generate_qr(callbacks)
assert(successes==1 and errors==0 and specs[1].follow_redirects==false)
assert(specs[1].ui_nonblocking==true, 'QR and account requests must not block the settings UI')
assert(specs[1].url:match('^https://passport%.bilibili%.com/x/passport%-login/web/qrcode/generate'))
response={code=99,msg='test_cookie',data=nil};api:generate_qr(callbacks)
assert(successes==1 and errors==1)
response={code=0,data={url='https://evil.example/',qrcode_key='test'}};api:generate_qr(callbacks)
assert(errors==2)
response=nil;api:generate_qr(callbacks);assert(errors==3)
response={code=0,data={code=86101}};api:poll_qr('test_key',callbacks)
assert(successes==2 and not specs[#specs].headers.Cookie)
response={code=0,data={isLogin=true,mid=123,uname='测试账号'}}
api:verify_account('SESSDATA=test_cookie',callbacks)
assert(specs[#specs].headers.Cookie=='SESSDATA=test_cookie' and successes==3)
assert(not table.concat(logs):find('test_cookie',1,true))
local Transport=require('mangaweb.transport')
assert(Transport:redirect_request({url='https://passport.bilibili.com/x',method='GET',follow_redirects=false},
    302,{location='https://passport.bilibili.com/other'})==nil)
response={code=0,data={url='https://account.bilibili.com/h5/account-h5/auth/scan-web?key=test',qrcode_key='test_key'}}
api:generate_qr(callbacks)
assert(successes==4 and errors==3, 'official account QR host must be accepted')
for _,url in ipairs({'https://account.bilibili.com.evil.example/scan',
    'https://account.bilibili.com@evil.example/scan','http://account.bilibili.com/scan',
    'https://account.bilibili.com/scan\n'}) do
    local before=errors
    response={code=0,data={url=url,qrcode_key='test_key'}}
    api:generate_qr(callbacks)
    assert(errors==before+1 and successes==4, 'invalid QR destination must be rejected')
end
print('bilibili_api_spec: single completion, malformed/error data, credential boundary and redirect policy passed')
