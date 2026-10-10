local CoverLoader=require('mangaweb.cover_loader')
local ImageLoader=require('mangaweb.image_loader')
local Cache=require('mangaweb.page_cache')
local files,hashes={},{}
local serial, downloads, processed, freed=0,0,0,0
local header='\255\216\255'..string.rep('a',20)
local function sha(value)
    if not hashes[value]then serial=serial+1;hashes[value]=string.format('%064x',serial)end
    return hashes[value]
end
local dirs={}
local fs={mkdir=function(_,path)dirs[path]=true;return true end,
    read=function(_,path,limit)return files[path] and files[path]:sub(1,limit)end,
    size=function(_,path)return files[path]and #files[path]end,
    write=function(_,path,body)files[path]=body;return true end,
    rename=function(_,a,b)files[b]=files[a];files[a]=nil;return true end,
    remove=function(_,path)files[path]=nil;return true end,
    list=function(_,root)local entries={};for path,body in pairs(files)do
        if path:sub(1,#root+1)==root..'/' then entries[#entries+1]={name=path:sub(#root+2),size=#body,mtime=1,mode='file'}end
    end;return entries end}
local cache=Cache:new{root='/cache/covers',fs=fs,sha256=sha,upper_bytes=256,lower_bytes=128}
local temp={new_session=function()return{}end,
    write=function(_,_,name,body,extension)local path='/temp/'..name..'.'..extension;files[path]=body;return path end,
    path=function(_,_,name,ext)return '/temp/'..name..'.'..ext end,
    track=function(_,_,path)return path end,
    remove=function(_,path)files[path]=nil end,remove_session=function()end}
local decode_bad
local render={renderImageFile=function(_,path)
    if path==decode_bad then return nil end
    assert(files[path], 'cached path must remain alive until its consumer is released')
    return {free=function()freed=freed+1 end}
end}
local loader=CoverLoader:new{http={get=function(_,url,opts,callbacks)
    downloads=downloads+1;callbacks.on_success(header);return{cancel=function()end}
end},temp_files=temp,cache=cache,render_image=render,
    page_processor={process=function(source,output)
        processed=processed+1;assert(files[source]);assert(output:match('%.jpg$'))
        files[output]=header;return{width=256,height=384,thumbnail=true}
    end},async={available=function()return true end,run=function(work,done)
        done(true,work());return{cancel=function()end}
    end}}
local spec={key='cover',site_id='zero',comic_id='a',url='https://img/1.jpg',stage='cover',width=227,height=321}
local received
local function ready(value)received=value;assert(value.buffer);value.buffer:free();return true end
local gen=loader:begin_session('cover')
loader:request(gen,spec,{on_ready=ready})
assert(received and downloads==1 and processed==1 and dirs['/cache'] and dirs['/cache/covers'])
local identity=require('mangaweb.cover_thumbnail').identity(spec,require('mangaweb.cover_thumbnail').profile(227,321),sha)
local path=assert(cache:get(identity))
assert(next(cache.pins))
loader:request(gen,spec,{on_ready=ready})
assert(downloads==1)
loader:cancel_generation(gen)
assert(not next(cache.pins))
gen=loader:begin_session('cover');received=nil
loader:request(gen,spec,{on_ready=ready})
assert(received and downloads==1 and processed==1, 'reopening must use the thumbnail without downloading')
loader:cancel_generation(gen)
gen=loader:begin_session('cover')
local before=freed
loader:request(gen,spec,{on_ready=function()return false end})
assert(freed==before+1, 'a rejected cached cover must free its decoded buffer')
before=freed
loader:request(gen,spec,{on_ready=function()error('widget retired')end})
assert(freed==before+1, 'a throwing consumer must not leak its cover')
loader:cancel_generation(gen)
-- A JPEG signature alone is insufficient: retry a corrupt cached image from network.
decode_bad=path;gen=loader:begin_session('cover');received=nil
loader:request(gen,spec,{on_ready=ready})
assert(received and downloads==2 and processed==2, 'corrupt retry: '..tostring(received)..' downloads='..downloads..' processed='..processed)
loader:cancel_generation(gen);decode_bad=nil
files[path]='not an image';gen=loader:begin_session('cover')
loader:request(gen,spec,{on_ready=ready});assert(downloads==3)
loader:cancel_generation(gen)
-- Cache write errors must not prevent display, and failed processors must not cache originals.
loader.cache={sha256=sha,get=function()end,pin=function()return true end,unpin=function()end,
    put_file=function()error('disk full')end}
gen=loader:begin_session('cover');received=nil
loader:request(gen,spec,{on_ready=ready});assert(received)
loader:cancel_generation(gen)
local puts=0
loader.cache.put_file=function()puts=puts+1 end
loader.loader.page_processor.process=function()return nil end
gen=loader:begin_session('cover');received=nil
loader:request(gen,spec,{on_ready=ready});assert(received and puts==0)
loader:cancel_generation(gen)
-- Covers have a separate six-task pool; reading keeps its existing default.
local callbacks={}
local canceled_http=0
local pending=CoverLoader:new{http={get=function(_,_,_,cb)callbacks[#callbacks+1]=cb;return{cancel=function()canceled_http=canceled_http+1 end}end},
    temp_files=temp,render_image=render,async={available=function()return false end}}
gen=pending:begin_session('cover')
for i=1,8 do pending:request(gen,{key=tostring(i),url='https://img/'..i,stage='cover'},{})end
assert(#callbacks==6 and pending.loader.active_count==6)
assert(ImageLoader:new{http={},temp_files=temp}.max_active==2)
pending:cancel_generation(gen)
assert(pending.loader.active_count==0 and not next(pending.loader.sessions))
assert(canceled_http==6, 'closing the page must cancel its actual HTTP transfers')
local shared_callbacks,shared_canceled={},0
local shared=CoverLoader:new{temp_files=temp,render_image=render,
    http={get=function(_,_,_,cb)shared_callbacks[#shared_callbacks+1]=cb
        return{cancel=function()shared_canceled=shared_canceled+1 end}end},
    async={available=function()return false end}}
gen=shared:begin_session('cover')
-- Public identical images share a transfer when their cache identities are known.
shared.cache=cache
local owner=shared:request(gen,{key='shared1',url='https://img/shared.jpg',stage='cover'},{})
shared:request(gen,{key='shared2',url='https://img/shared.jpg',stage='cover'}, {})
shared:request(gen,{key='other',url='https://img/other.jpg',stage='cover'}, {})
owner:cancel()
assert(shared_canceled==0 and shared.loader.active_count==2,
    'a shared transfer must stay counted and alive until its remaining consumer is canceled')
shared:cancel_generation(gen)
assert(shared_canceled==2 and shared.loader.active_count==0)
for _,keys in ipairs{{'a','b'},{'owner','waiter'},{'cover:1','cover:2'}} do
    local hits,stops=0,0
    local all=CoverLoader:new{cache=cache,temp_files=temp,render_image=render,
        http={get=function()hits=hits+1;return{cancel=function()stops=stops+1 end}end},
        async={available=function()return false end}}
    local session=all:begin_session('cover')
    for _,key in ipairs(keys)do all:request(session,{key=key,url='https://img/shared-all.jpg',stage='cover'}, {})end
    assert(hits==1)
    all:cancel_generation(session)
    assert(stops==1 and all.loader.active_count==0,
        'whole-session cancellation must stop a shared transfer regardless of owner/waiter traversal order')
end
local mixed_callbacks={}
local mixed=CoverLoader:new{cache=cache,render_image=render,temp_files=temp,
    http={get=function(_,_,_,cb)mixed_callbacks[#mixed_callbacks+1]=cb;return{cancel=function()end}end},
    async={available=function()return false end}}
gen=mixed:begin_session('cover')
for i=1,4 do mixed:request(gen,{key='missing'..i,url='https://missing/'..i,stage='cover'},{})end
received=nil
mixed:request(gen,spec,{on_ready=ready})
assert(received and #mixed_callbacks==4, 'cached covers must display immediately while all download slots are occupied')
mixed:cancel_generation(gen)
local private_callbacks={}
local scoped=CoverLoader:new{cache=cache,render_image=render,temp_files=temp,
    http={get=function(_,_,_,cb)private_callbacks[#private_callbacks+1]=cb;return{cancel=function()end}end},
    async={available=function()return false end}}
gen=scoped:begin_session('cover')
for i=1,2 do scoped:request(gen,{key='account'..i,url='https://private/same.jpg',stage='cover',
    headers={Cookie='account'..i},site_id='custom'}, {})end
assert(#private_callbacks==2, 'different accounts must not share an in-flight original for the same URL')
scoped:cancel_generation(gen)
-- A canceled processor still owns its output until the child has been reaped.
local operation,done,reaped,output,cleaned,accepted
local delayed_temp={new_session=function()return{}end,
    write=temp.write,path=temp.path,track=function(_,_,path)output=path;files[path]=header;return path end,
    remove=temp.remove,remove_session=function()cleaned=true end}
local delayed=CoverLoader:new{cache=cache,render_image=render,temp_files=delayed_temp,
    http={get=function(_,_,_,cb)cb.on_success(header);return{cancel=function()end}end},
    async={available=function()return true end,run=function(_,callback,options)
        done,reaped=callback,options.on_reaped
        operation={pid=10,cancel=function()done(false)end};return operation
    end}}
gen=delayed:begin_session('cover')
delayed:request(gen,{key='delayed',url='https://img/delayed.jpg',stage='cover'},
    {on_ready=function()accepted=true;return true end})
delayed:cancel_generation(gen)
assert(files[output] and not cleaned and delayed.loader.active_count==1,
    'the worker output and session must survive cancellation until on_reaped')
operation.pid=nil;reaped()
assert(not files[output] and cleaned and not accepted and delayed.loader.active_count==0)
assert(not next(delayed.loader.sessions) and not next(cache.pins))
files['/huge.jpg']=header..string.rep('a',200)
assert(not cache:put_file(identity,'/huge.jpg',100), 'oversized images must not enter the thumbnail cache')
-- Hidden covers persist their thumbnail, but never decode a UI buffer or retain originals.
local hidden_decode, hidden_ready = 0, nil
local hidden_cache=Cache:new{root='/hidden/covers',fs=fs,sha256=sha}
local hidden_temp={new_session=function()return{}end,
    write=function(_,_,name,body,ext)local p='/bgtemp/'..name..'.'..ext;files[p]=body;return p end,
    path=function(_,_,name,ext)return '/bgtemp/'..name..'.'..ext end,
    track=function(_,_,p)return p end,remove=temp.remove,remove_session=function()end}
local hidden=CoverLoader:new{cache=hidden_cache,temp_files=hidden_temp,
    render_image={renderImageFile=function()hidden_decode=hidden_decode+1;error('hidden UI decode')end},
    http={get=function(_,_,_,cb)cb.on_success(header);return{cancel=function()end}end},
    page_processor={process=function(source,output)assert(files[source]);files[output]=header;return{thumbnail=true}end},
    async={available=function()return true end,run=function(work,done)done(true,work());return{cancel=function()end}end}}
gen=hidden:begin_session('cover')
local hidden_spec={key='hidden',url='https://img/hidden.jpg',site_id='zero',comic_id='hidden',
    stage='cover',width=320,height=448,cache_only=true}
local function hidden_callback(result)
    hidden_ready=result;assert(result.cached and not result.buffer)
    hidden:release(gen,'hidden');return true
end
hidden:request(gen,hidden_spec,{on_ready=hidden_callback})
assert(hidden_ready and files[hidden_ready.path] and hidden_decode==0)
assert(not next(hidden_cache.pins) and not next(hidden.loader.sessions[gen].jobs_by_key))
for p in pairs(files)do assert(not p:match('^/bgtemp/'), 'hidden originals and outputs must be released immediately')end
hidden:request(gen,hidden_spec,{on_ready=hidden_callback})
assert(hidden_decode==0 and files[hidden_ready.path], 'a cached hidden cover must not decode either')
hidden:cancel_generation(gen)
print('cover_loader_spec: passed')
