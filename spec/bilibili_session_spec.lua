local Settings=require('mangaweb.settings')
local Session=require('mangaweb.bilibili_session')
local data,fail={},false
local settings=Settings:new{store={readSetting=function(_,key,d) return data[key] or d end,
    saveSetting=function(_,key,value) data[key]=value;return true end,flush=function() return not fail end}}
local session=Session:new{settings=settings,sha256=function(value)
    return string.rep(value:find('fictional_one',1,true) and 'a' or 'b',64)
end}
local cookie=assert(session:candidate({['Set-Cookie']={
    'SESSDATA=fictional_one; Domain=.bilibili.com; Secure; HttpOnly',
    'DedeUserID=123; Path=/; Expires=Thu, 01 Jan 2099 00:00:00 GMT',
    'bili_jct=fictional_csrf; Path=/'}}))
assert(session:save({uid='123',name='账号一'},cookie))
assert(session:headers('https://api.bilibili.com/x/web-interface/nav').Cookie==cookie)
for _,url in ipairs({'https://i0.hdslb.com/image','https://bilibili.com.evil.example/',
    'http://api.bilibili.com/','https://api.bilibili.com:9999/','https://api.bilibili.com@evil.example/'}) do
    assert(not session:headers(url).Cookie)
end
local account=session:account()
assert(account.uid=='123' and not account.cookie and not account.session)
local first_scope=session:scope()
assert(type(first_scope)=='string' and #first_scope==64 and not first_scope:find('fictional',1,true))
assert(not session:candidate({['set-cookie']='SESSDATA=expired; Max-Age=0, DedeUserID=123; Path=/'}))
assert(not session:candidate({['set-cookie']='SESSDATA=old; Expires=Thu, 01 Jan 1970 00:00:00 GMT, DedeUserID=123'}))
assert(not session:candidate({['set-cookie']='SESSDATA=test\r\nX-Evil: yes; DedeUserID=123'}))
local second=assert(session:candidate({['set-cookie']='SESSDATA=fictional_two; Path=/, DedeUserID=456; Path=/'}))
assert(not session:save({uid='999',name='错误UID'},second))
fail=true;assert(not session:save({uid='456',name='账号二'},second))
assert(session:account().uid=='123' and Session:new{settings=settings}:account().uid=='123')
assert(not session:clear() and session:account().uid=='123')
fail=false;assert(session:save({uid='456',name='账号二'},second))
assert(session:scope()~=first_scope)
assert(session:clear() and session:account()==nil and session:scope()=='public')
print('bilibili_session_spec: cookies, expiry, UID binding, host isolation and save/logout rollback passed')
