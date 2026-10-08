-- Real cache with an in-memory filesystem; no large files are allocated.

local Loader=require('mangaweb.image_loader')
local Reader=require('mangaweb.reader')
local Settings=require('mangaweb.settings')
local Cache=require('mangaweb.page_cache')
local files,hashes={},{}
local serial=0
local function sha(text)
    if not hashes[text] then serial=serial+1;hashes[text]=string.format('%064x',serial) end
    return hashes[text]
end
local header='\255\216\255'..string.rep('a',20)
local fs={mkdir=function()return true end,
    read=function(_,path,limit)return files[path] and files[path].header:sub(1,limit)end,
    write=function(_,path,body)files[path]={header=body,size=#body};return true end,
    size=function(_,path)return files[path]and files[path].size end,
    rename=function(_,a,b)files[b]=files[a];files[a]=nil;return true end,
    remove=function(_,path)files[path]=nil;return true end,
    list=function(_,root)
        local values={}
        for path,file in pairs(files)do
            if path:sub(1,#root+1)==root..'/' then
                values[#values+1]={name=path:sub(#root+2),mode='file',size=file.size,mtime=1}
            end
        end
        return values
    end}
local cache=Cache:new{root='/cache/pages',fs=fs,sha256=sha}
local temp={new_session=function()return{}end,
    path=function(_,_,key,ext)return '/temp/'..key..'.'..ext end,
    track=function(_,_,path)files[path]={header=header,size=10};return path end,
    remove=function(_,path)files[path]=nil end,remove_session=function()end}
require('mangaweb.image_dimensions').from_file=function(path)
    if files[path]then return 1400,1991 end
end
local downloaded=0
local loader=Loader:new{http={get_file=function(_,url,opts,callbacks)
    downloaded=downloaded+1
    files[opts.path]={header=header,size=40*1048576}
    callbacks.on_success(opts.path,{bytes=40*1048576})
    callbacks.on_reaped()
    return{cancel=function()end}
end},temp_files=temp,page_cache=cache,
    page_processor={process=function(source)
        if files[source]then return{width=1192,height=1696,source_width=1400,source_height=1991}end
    end},
    async={available=function()return true end,run=function(work,done)
        done(true,work());return{cancel=function()end}
    end}}
local stored={}
local settings=Settings:new{store={readSetting=function(_,key,default)return stored[key]or default end,
    saveSetting=function(_,key,value)stored[key]=value;return true end,flush=function()return true end}}
local initial=settings:reader_settings()
initial.preload_pages=2;initial.cache_upper_mb=64;initial.cache_lower_mb=0
assert(settings:save_reader_settings(initial))
local errors=0
local reader=Reader:new{settings=settings,store={save_history=function()return true end},
    loader=loader,page_cache=cache,
    ui={show_page_loading=function()return true end,
        show_page=function(_,path)return files[path]~=nil end,
        show_error=function()errors=errors+1 end,content_width=1272,content_height=1696}}
assert(reader:open{site_id='zero',comic_id='x',pages={
    {url='https://test/1.jpg'},{url='https://test/2.jpg'},{url='https://test/3.jpg'}}})
local source2=reader.entries[2].raw_path
assert(reader:update_settings{gray_enabled=true,gray_preset='clear'})
local ok,reason=reader:go_to(2)
assert(files[source2] and ok==true and errors==0 and downloaded==3,
    "filter changes must protect preloaded originals even above the cache limit")
-- Closing between cancellation and replacement must release the retained pin.
loader:cancel_processing(reader.loader_generation,reader.entries[2].key)
reader:close()
assert(not next(cache.pins), "closing a reader must release unclaimed retention pins")
assert(not next(loader.sessions), "closing must release the processing session")
print("filter_cache_pressure_spec: passed")
