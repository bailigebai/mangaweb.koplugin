local Settings=require('mangaweb.settings')
local Auth=require('mangaweb.auth')
local function serialize(value)
    if type(value)=='table' then local parts={};for k,v in pairs(value)do
        parts[#parts+1]='['..serialize(k)..']='..serialize(v) end;return '{'..table.concat(parts,',')..'}'
    end
    return type(value)=='string' and string.format('%q',value) or tostring(value)
end
package.preload.dump=function()return serialize end
-- Match KOReader's actual fourth argument: true wraps serialized data as a
-- complete Lua file. Already complete file contents must pass false.
package.preload.util=function()return{writeToFile=function(data,path,force_flush,lua_dofile_ready)
    if lua_dofile_ready then data='-- '..path..'\nreturn '..data..'\n' end
    local file=io.open(path,'wb');if not file then return nil end
    local ok=file:write(data);file:close();return ok~=nil
end}end
local function store(path)
    return {file=path,data={['cookie:zero']='sid=old',['cookie_origin:zero']='https://zero.test'},
        readSetting=function(self,k,f)local v=self.data[k];if v~=nil then return v end;return f end,
        saveSetting=function(self,k,v)self.data[k]=v;return self end,
        -- Actual LuaSettings flush returns self even when the underlying write failed.
        flush=function(self)return self end}
end
local missing=os.tmpname()..'/missing-parent/settings.lua'
local broken=store(missing);local settings=Settings:new{store=broken}
local saved=settings:save_cache_policy{upper_mb=64,lower_mb=32,interval_minutes=1}
assert(saved==false and settings:cache_policy().upper_mb==256,
    'LuaSettings self return must not turn a failed disk write into a successful policy change')
local auth=Auth:new{settings=settings,origins={zero='https://zero.test'}}
assert(auth:set_cookie('zero','sid=new')==false and auth:cookie('zero')=='sid=old',
    'disk failure must preserve the previous in-memory session')
local path=os.tmpname();local good=store(path);local persisted=Settings:new{store=good}
assert(persisted:save_cache_policy{upper_mb=64,lower_mb=32,interval_minutes=1})
local disk=assert(loadfile(path))()
assert(disk.reader.cache_upper_mb==64 and disk['cookie:zero']=='sid=old')
-- A first login has no session file yet. Keep this separate from the policy
-- save above so the Windows desktop C runtime need not replace a POSIX file.
local login_path=os.tmpname()
local login_store=store(login_path)
login_store.data.reader=disk.reader
local login_settings=Settings:new{store=login_store}
local saved_auth=Auth:new{settings=login_settings,origins={zero='https://zero.test'}}
local gets,posts,logged_in=0,0,false
local http={}
function http:get(url,options,callbacks)
    gets=gets+1
    if gets==1 then
        assert(not options.headers.Cookie,'new credentials must have an isolated session')
        callbacks.on_success('<form action="/Android/my/"><input name="username"><input name="password" type="password"></form>',
            {status=200,headers={['set-cookie']='sid=challenge'}})
    else
        assert(options.headers.Cookie:find('zero_auth=verified_session',1,true))
        callbacks.on_success('<a href="/logout">退出登录</a>',{status=200,headers={}})
    end
    return {cancel=function()end}
end
function http:post_form(url,fields,options,callbacks)
    posts=posts+1
    assert(options.headers.Cookie=='sid=challenge')
    callbacks.on_success('<a href="/logout">退出登录</a>',
        {status=200,headers={['set-cookie']='zero_auth=verified_session'}})
    return {cancel=function()end}
end
require('mangaweb.sources.zero'):new{auth=saved_auth,http=http,origin='https://zero.test'}:login(
    {username='fixture_user',password='fixture_password'},
    {on_success=function(result)logged_in=result.verified==true end,
        on_error=function(err)error('verified login must persist: '..tostring(err.code))end})
assert(logged_in and gets==2 and posts==1,'verified login must commit one session without repeating the password submission')
local reloaded=assert(loadfile(login_path))()
assert(reloaded['cookie:zero']:find('zero_auth=verified_session',1,true),
    'an Android login must remain saved after reopening the settings file')
assert(reloaded.reader.cache_upper_mb==64,'saving a new session must preserve existing reader preferences')
os.remove(path)
os.remove(login_path)
print('settings_persistence_spec: passed')
