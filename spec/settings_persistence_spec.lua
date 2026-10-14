local Settings=require('mangaweb.settings')
local Auth=require('mangaweb.auth')
local function serialize(value)
    if type(value)=='table' then local parts={};for k,v in pairs(value)do
        parts[#parts+1]='['..serialize(k)..']='..serialize(v) end;return '{'..table.concat(parts,',')..'}'
    end
    return type(value)=='string' and string.format('%q',value) or tostring(value)
end
package.preload.dump=function()return serialize end
package.preload.util=function()return{writeToFile=function(data,path)
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
os.remove(path)
print('settings_persistence_spec: passed')
