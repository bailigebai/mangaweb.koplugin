local CoverLoader = require('mangaweb.cover_loader')
local ImageLoader = require('mangaweb.image_loader')
local Cache = require('mangaweb.page_cache')
local files, hashes, serial, scans = {}, {}, 0, 0
local function sha(value)
    if not hashes[value] then serial=serial+1; hashes[value]=string.format('%064x',serial) end
    return hashes[value]
end
local jpeg='\255\216\255'..string.rep('x',30)
local fs={mkdir=function()return true end,
    read=function(_,p,n)return files[p] and files[p]:sub(1,n)end,
    size=function(_,p)return files[p] and #files[p]end,
    write=function(_,p,b)files[p]=b;return true end,
    rename=function(_,a,b)files[b]=files[a];files[a]=nil;return true end,
    remove=function(_,p)files[p]=nil;return true end,
    list=function(_,root)
        scans=scans+1;local entries={}
        for p,b in pairs(files)do if p:sub(1,#root+1)==root..'/'then
            entries[#entries+1]={name=p:sub(#root+2),mode='file',mtime=1,size=#b}
        end end;return entries
    end}
local small=Cache:new{root='/cache/covers',fs=fs,sha256=sha}
local pages=Cache:new{root='/cache/pages',fs=fs,sha256=sha}
local id={site_id='zero',comic_id='a',chapter_id='c',index=1,url='https://img/1.jpg'}
local Identity=require('mangaweb.image_identity')
local page_id=Identity.page(id,{},sha)
assert(page_id.chapter_id~=id.chapter_id,
    'new public page keys must not reuse legacy originals with unknown credential provenance')
assert(pages:put(id,jpeg)) -- A legacy cache file may have been downloaded with a login.
assert(small:put(id,jpeg));assert(small:pin(id));local before=scans
assert(small:unpin(id))
assert(scans==before, 'releasing an under-limit cached cover must not scan the full directory again')
local pressured=Cache:new{root='/pressure/covers',fs=fs,sha256=sha,upper_bytes=1,lower_bytes=0}
assert(pressured:pin(id));assert(pressured:put(id,jpeg));assert(pressured.needs_trim)
assert(pressured:unpin(id));assert(not pressured:get(id), 'unpin must still resume previously blocked cleanup')

local temp={new_session=function()return{}end,
    path=function(_,_,n,ext)return '/temp/'..n..'.'..ext end,
    track=function(_,_,p)return p end,
    write=function(_,_,n,b,ext)local p='/temp/'..n..'.'..ext;files[p]=b;return p end,
    remove=function(_,p)files[p]=nil end,remove_session=function()end}
local downloads,processed,decoded=0,0,0
local logs,now={},0
local function clock()now=now+0.1;return now end
local logger={warn=function(...)
    local words={};for _,v in ipairs{...}do words[#words+1]=tostring(v)end
    logs[#logs+1]=table.concat(words,' ')
end}
local renderer={renderImageFile=function(_,path)
    assert(files[path]);decoded=decoded+1
    return{getWidth=function()return 1400 end,getHeight=function()return 1900 end,free=function()end}
end}
local http={get=function(_,_,_,cb)downloads=downloads+1;cb.on_success(jpeg);return{cancel=function()end}end,
    get_file=function(_,_,options,cb)
        downloads=downloads+1;files[options.path]=jpeg
        cb.on_success(options.path,{bytes=#jpeg});cb.on_reaped();return{cancel=function()end}
    end}
local loader=CoverLoader:new{cache=small,page_cache=pages,temp_files=temp,http=http,render_image=renderer,
    logger=logger,clock=clock,
    page_processor={process=function(source,output)
        processed=processed+1;assert(files[source]);files[output]=jpeg;return{thumbnail=true,width=192,height=256}
    end},async={available=function()return true end,run=function(work,done)
        done(true,work());return{cancel=function()end}
    end}}
local spec={key='preview',stage='preview',site_id='zero',comic_id='a',chapter_id='c',index=1,
    url=id.url,width=170,height=250}
local result
local gen=loader:begin_session('detail')
loader:request(gen,spec,{on_ready=function(value)result=value;return true end})
assert(result and processed==1 and downloads==1, 'preview must use the background thumbnail processor')
assert(result.path~=result.cached_raw and pages:get(page_id)==result.cached_raw,
    'reading must retain the original, separately from the small preview')
loader:cancel_generation(gen)
assert(not next(pages.pins) and not next(small.pins))
gen=loader:begin_session('detail');result=nil
loader:request(gen,spec,{on_ready=function(value)result=value;return true end})
assert(result and downloads==1 and processed==1, 'reopening previews must use small disk thumbnails')
loader:cancel_generation(gen)
local transcript=table.concat(logs,'\n')
assert(transcript:find('thumbnail_cache_hit',1,true) and transcript:find('thumbnail_cache_miss',1,true)
    and transcript:find('process_start',1,true) and transcript:find('elapsed_ms',1,true),
    'image diagnostics must distinguish thumbnail cache hits, network work and processing time')
assert(not transcript:find('https://',1,true) and not transcript:find('Cookie',1,true),
    'diagnostics must not contain URLs or credentials')
local reader=ImageLoader:new{http=http,page_cache=pages,temp_files=temp,render_image=renderer}
gen=reader:begin_session('reader');result=nil
reader:request(gen,{key='first',url=id.url,stage='image',cache_identity=page_id},
    {on_ready=function(value)result=value;return true end})
assert(result and result.path==pages:get(page_id) and downloads==1,
    'opening reading after preview must use the original without another transfer')
reader:cancel_generation(gen)
local identity=require('mangaweb.image_identity')
local a=identity.page(spec,{Cookie='account-a'},sha)
local b=identity.page(spec,{cookie='account-b'},sha)
assert(a.chapter_id~=b.chapter_id and not a.chapter_id:find('account',1,true))
assert(identity.page(spec,{},sha).chapter_id==page_id.chapter_id)
local pending,stopped={},0
local shared=CoverLoader:new{cache=small,http={get=function(_,_,_,cb)
    pending[#pending+1]=cb;return{cancel=function()stopped=stopped+1 end}
end},temp_files=temp,render_image=renderer}
gen=shared:begin_session('detail')
for i,w in ipairs{200,400}do shared:request(gen,{key='size'..i,stage='cover',site_id='zero',
    comic_id='same',url='https://img/shared.jpg',width=w,height=w}, {})end
assert(#pending==1, 'different thumbnail sizes of one public original must share its transfer')
shared:cancel_generation(gen);assert(stopped==1)
local fallback_decodes,failures=0,0
local unavailable=CoverLoader:new{cache=small,page_cache=pages,http=http,temp_files=temp,
    render_image={renderImageFile=function()fallback_decodes=fallback_decodes+1;return{free=function()end}end},
    async={available=function()return false end}}
gen=unavailable:begin_session('detail')
unavailable:request(gen,{key='unavailable',stage='preview',site_id='zero',comic_id='a',index=2,
    chapter_id='c',url='https://img/no-worker.jpg'},
    {on_ready=function()error('original fallback must not be installed as preview')end,
     on_error=function(err)assert(err.code=='image_error');failures=failures+1 end})
assert(fallback_decodes==0 and failures==1,
    'a failed preview worker must report a retryable failure, never decode a large original on the UI thread')
unavailable:cancel_generation(gen)
print('cover_preview_cache_spec: passed')
