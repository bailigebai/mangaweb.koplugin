local Cache=require('mangaweb.page_cache')
local Settings=require('mangaweb.settings')
local Manager=require('mangaweb.cache_manager')
local MB=1048576
local function fixture()
    local files,blocked,hashes,queue={},{},{},{}
    local now,serial=100,0
    local fs={mkdir=function()return true end,
        read=function(_,p,n)return files[p] and files[p].body:sub(1,n)end,
        write=function(_,p,b)files[p]={body=b,size=#b,mtime=now,mode='file'};return true end,
        size=function(_,p)return files[p] and files[p].size end,
        rename=function(_,a,b)files[b]=files[a];files[a]=nil;return true end,
        remove=function(_,p)if blocked[p] then return false end;files[p]=nil;return true end,
        stat=function(_,p)return files[p]end,
        touch=function(_,p,t)if files[p]then files[p].mtime=t end end,
        list=function(_,root)local out={};for p,f in pairs(files)do
            if p:sub(1,#root+1)==root..'/' then out[#out+1]={name=p:sub(#root+2),size=f.size,mtime=f.mtime,mode=f.mode} end
        end;return out end}
    local function sha(value)if not hashes[value]then serial=serial+1;hashes[value]=string.format('%064x',serial)end;return hashes[value]end
    local caches,ids,paths={},{},{}
    for i,kind in ipairs{'pages','covers','catalogues'}do
        caches[i]=Cache:new{root='/cache/'..kind,directory=kind,fs=fs,sha256=sha,clock=function()return now end,
            upper_bytes=4096*MB,lower_bytes=4000*MB}
        ids[i]={site_id='zero',comic_id=tostring(i),chapter_id='c',index=1,url='https://example.com/'..i}
        if kind=='catalogues' then
            paths[i]='/cache/catalogues/'..string.rep('a',64)..'.json'
            fs:write(paths[i],'{}')
        else paths[i]=caches[i]:put(ids[i],'\255\216\255'..string.rep('a',30)) end
        files[paths[i]].size=25*MB;files[paths[i]].mtime=i
    end
    local saved={}
    local settings=Settings:new{store={readSetting=function(_,k,d)return saved[k]or d end,
        saveSetting=function(_,k,v)saved[k]=v;return true end,flush=function()return true end}}
    assert(settings:save_cache_policy{upper_mb=64,lower_mb=32,interval_minutes=10})
    local scheduler={scheduleIn=function(_,delay,cb)queue[cb]=now+delay end,unschedule=function(_,cb)queue[cb]=nil end}
    local manager=Manager:new{caches=caches,settings=settings,scheduler=scheduler,clock=function()return now end,batch_size=1}
    local function drain()
        for i=1,100 do
            local fn,time
            for cb,t in pairs(queue)do if not time or t<time then fn,time=cb,t end end
            if not fn or time>now+2 then return end
            queue[fn]=nil;now=math.max(now,time);fn()
        end
        error('cleanup must be bounded')
    end
    return{manager=manager,caches=caches,files=files,paths=paths,ids=ids,blocked=blocked,
        settings=settings,queue=queue,drain=drain,advance=function(n)now=now+n end}
end
local f=fixture()
assert(f.manager:stats().total_bytes==75*MB,'sum all three cache types')
local result
assert(f.manager:check(true,function(r)result=r end));f.drain()
assert(result and result.total_bytes==25*MB and result.freed_bytes==50*MB)
assert(f.files[f.paths[3]],'evict the least recently used entries across cache types')
local below=fixture()
below.files[below.paths[1]].size=14*MB
below.manager:check(true);below.drain()
assert(below.manager:stats().total_bytes==64*MB,'at the upper bound no cleanup is needed')
local recent=fixture()
recent.caches[1]:get(recent.ids[1])
recent.manager:check(true);recent.drain()
assert(recent.files[recent.paths[1]],'a cache hit must update the eviction order')
local protected=fixture()
protected.caches[1]:pin(protected.ids[1])
assert(protected.caches[2]:sync_protected('favorites',{protected.ids[2]},true))
protected.manager:check(true,function(r)result=r end);protected.drain()
assert(protected.files[protected.paths[1]] and protected.files[protected.paths[2]])
assert(result.total_bytes==50*MB and result.protected_bytes==50*MB and result.reason=='protected_limit')
local changed=fixture()
changed.manager:check(true)
changed.caches[1]:pin(changed.ids[1])
changed.drain()
assert(changed.files[changed.paths[1]],'recheck pins immediately before deleting a queued candidate')
local failure=fixture()
for _,path in ipairs(failure.paths)do failure.blocked[path]=true end
failure.manager:check(true,function(r)result=r end);failure.drain()
assert(result.total_bytes==75*MB and result.freed_bytes==0 and result.reason=='cleanup_failed')
assert(not failure.caches[1]:remove_entry{path='/outside/keep.jpg',name=failure.paths[1]:match('[^/]+$')})
local unreadable=fixture()
unreadable.caches[1].fs.list=function()error('unreadable directory')end
assert(unreadable.manager:stats().scan_failed,'an unreadable cache must not be reported as empty')
local pending=fixture()
local part=pending.caches[1]:reserve(pending.ids[1]);pending.files[part].size=8*MB
pending.manager:check(true);pending.drain()
assert(pending.files[part] and pending.manager:stats().protected_bytes>=8*MB,'active partial downloads stay protected and counted')
local invalid=fixture()
for _,policy in ipairs{
    {upper_mb=0,lower_mb=0,interval_minutes=10},
    {upper_mb=64,lower_mb=64,interval_minutes=10},
    {upper_mb=64,lower_mb=-1,interval_minutes=10},
    {upper_mb=64,lower_mb=0,interval_minutes=0},
    {upper_mb=math.huge,lower_mb=0,interval_minutes=1},
    {upper_mb=0/0,lower_mb=0,interval_minutes=1},
}do assert(not invalid.settings:save_cache_policy(policy))end
assert(invalid.settings:cache_policy().upper_mb==64,'invalid policy must not change the saved settings')
local stopped=fixture()
stopped.manager:start();stopped.drain()
stopped.manager:stop()
assert(not next(stopped.queue),'exit cancels every maintenance timer')
local before=stopped.manager:stats().total_bytes
stopped.manager:check(true);stopped.drain()
assert(stopped.manager:stats().total_bytes==before)
local link=fixture()
link.files[link.paths[1]].mode='link'
link.manager:check(true);link.drain()
assert(link.files[link.paths[1]] and link.manager:stats().total_bytes==50*MB,'never follow or delete cache symlinks')
local App=require('mangaweb.app')
local lifecycle=fixture()
local app=App:new{source_registry={},settings=lifecycle.settings,page_cache=lifecycle.caches[1],
    cover_cache=lifecycle.caches[2],catalogue_cache={storage=lifecycle.caches[3]},
    ui={ui_manager=lifecycle.manager.scheduler}}
assert(app.cache_manager and #app.cache_manager.caches==3,'runtime must register every cache in the same manager')
app.cache_manager:start();app:close()
assert(not next(lifecycle.queue),'closing the plugin must stop cache maintenance')
print('global_cache_spec: passed')
