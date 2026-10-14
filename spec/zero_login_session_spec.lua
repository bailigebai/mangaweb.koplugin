local Auth=require('mangaweb.auth')
local Zero=require('mangaweb.sources.zero')
local form='<form action="/Android/my/"><input name="username"><input name="password" type="password"></form>'
local logged='<a href="/logout">退出登录</a>'
local function fixture()
    local saved, requests={},{}
    local settings={read=function(_,k,d) if saved[k]~=nil then return saved[k] end return d end,
        write=function(_,k,v) saved[k]=v;return true end,flush=function()return true end}
    local auth=Auth:new{settings=settings,origins={zero='https://www.zerobyw33.com'}}
    assert(auth:set_cookie('zero','zero_auth=old_session'))
    local http={}
    function http:get(url,opts,cb)
        local r={url=url,opts=opts,cb=cb,method='GET'};requests[#requests+1]=r
        return{cancel=function()r.canceled=true end}
    end
    function http:post_form(url,fields,opts,cb)
        local r={url=url,opts=opts,cb=cb,fields=fields,method='POST'};requests[#requests+1]=r
        return{cancel=function()r.canceled=true end}
    end
    local source=Zero:new{auth=auth,http=http}
    local success,failure=0,nil
    local handle=source:login({username='test_user',password='test_password'}, {
        on_success=function()success=success+1 end,on_error=function(e)failure=e.code end})
    return{auth=auth,saved=saved,requests=requests,source=source,handle=handle,
        result=function()return success,failure end}
end
local a=fixture()
assert(a.auth:cookie('zero')=='zero_auth=old_session','starting a login must retain the saved session')
assert(not a.requests[1].opts.headers.Cookie,'new credentials must be verified in an isolated cookie jar')
a.requests[1].cb.on_error{code='transport_error'}
assert(a.auth:cookie('zero')=='zero_auth=old_session' and select(2,a.result())=='transport_error')
local b=fixture()
b.requests[1].cb.on_success(form,{status=200,headers={['set-cookie']='challenge=fresh'}})
assert(#b.requests==2 and b.requests[2].method=='POST')
assert(b.requests[2].opts.headers.Cookie=='challenge=fresh')
b.requests[2].cb.on_error{code='request_timeout'}
assert(b.auth:cookie('zero')=='zero_auth=old_session','a failed password submission must retain the old session')
local c=fixture()
c.requests[1].cb.on_success(form,{status=200,headers={}})
c.requests[2].cb.on_success(logged,{status=200,headers={}})
assert(select(2,c.result())=='invalid_credentials' and c.result()==0,
    'old authentication cookies must not turn a failed new login into success')
local d=fixture()
d.requests[1].cb.on_success(form,{status=200,headers={}})
d.requests[2].cb.on_success(logged,{status=200,headers={['set-cookie']='zero_auth=new_session'}})
assert(#d.requests==3 and d.auth:cookie('zero')=='zero_auth=old_session','do not commit before verification')
d.requests[3].cb.on_success(logged,{status=200,headers={}})
assert(d.result()==1 and d.auth:cookie('zero')=='zero_auth=new_session')
d.requests[3].cb.on_success(logged,{status=200,headers={}})
assert(d.result()==1,'late duplicate completions must not commit twice')
local e=fixture()
e.requests[1].cb.on_success(form,{status=200,headers={}})
e.handle:cancel()
assert(e.requests[2].canceled,'cancel must reach the current request, not only the first form GET')
e.requests[2].cb.on_success(logged,{status=200,headers={['set-cookie']='zero_auth=late'}})
assert(#e.requests==2 and e.auth:cookie('zero')=='zero_auth=old_session' and e.result()==0)
local f=fixture()
f.requests[1].cb.on_success(form,{status=200,headers={}})
f.auth:set_cookie('zero','zero_auth=other_login')
f.requests[2].cb.on_success(logged,{status=200,headers={['set-cookie']='zero_auth=new_session'}})
f.requests[3].cb.on_success(logged,{status=200,headers={}})
assert(f.auth:cookie('zero')=='zero_auth=other_login' and f.result()==0,'do not overwrite an independently changed session')
local g=fixture()
g.requests[1].cb.on_success(form,{status=200,headers={}})
g.auth.origins.zero='https://new.example.com'
g.requests[2].cb.on_success(logged,{status=200,headers={['set-cookie']='zero_auth=new_session'}})
g.requests[3].cb.on_success(logged,{status=200,headers={}})
assert(g.auth:cookie('zero')=='zero_auth=old_session' and g.result()==0,'edited domains invalidate pending logins')
local h=fixture()
h.requests[1].cb.on_success(form,{status=200,headers={}})
h.requests[2].cb.on_success(logged,{status=200,headers={['set-cookie']='zero_auth=new_session'}})
h.auth.settings.flush=function()return false end
h.requests[3].cb.on_success(logged,{status=200,headers={}})
assert(h.auth:cookie('zero')=='zero_auth=old_session' and h.result()==0,'failed persistence must roll back the saved session')
print('zero_login_session_spec: passed')
