local Loader=require('mangaweb.image_loader')
local active={}
local loader=Loader:new{max_active=1,
    render_image={renderImageFile=function()return {free=function()end} end},
    http={get=function(_,url,_,cb)
        active[#active+1]={url=url,cb=cb};return {cancel=function() end}
    end},
    temp_files={new_session=function()return{}end,remove_session=function()end,
        path=function(_,_,name)return name end,track=function(_,_,p)return p end,
        write=function(_,_,name)return name end,remove=function()end}}
local g=loader:begin_session('reader')
local function request(key,priority)
    return loader:request(g,{key=key,url='https://image.test/'..key..'.jpg',
        stage='cover',priority=priority},{on_ready=function()return true end})
end
request('first',1);request('far',4);request('target',4)
assert(type(loader.promote)=='function','a queued preload must support foreground promotion')
assert(loader:promote(g,'target'))
assert(#active==1 and loader.queue[1].key=='target','target must precede an older far preload without duplicating the active request')
assert(loader:promote(g,'first') and #active==1,'an active target must keep its original transfer')
active[1].cb.on_success('\255\216\255\217',{status=200})
assert(#active==2 and active[2].url:find('target',1,true),'the next free slot must load the target')
local target=loader.sessions[g].jobs_by_key.target
assert(target.priority==1)
target.handle:cancel()
assert(not loader:promote(g,'target'),'canceled jobs must not be resurrected')
loader:cancel_generation(g)
assert(not loader:promote(g,'far'),'closed sessions must not be resurrected')
-- File workers release their slot only after reaping. Promotion must honor
-- that boundary, cancel a remote speculation, then start the target once.
local transfers,removed={},{}
local file_loader=Loader:new{max_active=1,
    http={get_file=function(_,url,options,cb)
        local transfer={url=url,path=options.path,cb=cb};transfers[#transfers+1]=transfer
        return {cancel=function()transfer.cancelled=true end}
    end},temp_files={new_session=function()return{}end,remove_session=function()end,
        reserve=function(_,_,name)return name..'.part' end,
        discard=function(_,path)removed[path]=true end,remove=function()end}}
local fg=file_loader:begin_session('reader')
local function page(index)
    return file_loader:request(fg,{key=tostring(index),index=index,priority=4,
        stage='image',url='https://image.test/'..index..'.jpg'}, {})
end
page(8);page(2)
assert(file_loader:promote(fg,'2') and transfers[1].cancelled)
assert(#transfers==1 and file_loader.active_count==1,'canceled workers must retain their slot until reaped')
transfers[1].cb.on_reaped()
assert(#transfers==2 and transfers[2].url=='https://image.test/2.jpg' and removed[transfers[1].path])
assert(file_loader:promote(fg,'2') and not transfers[2].cancelled and #transfers==2,
    'turning to an active preload must not cancel or restart it')
file_loader:cancel_generation(fg);transfers[2].cb.on_reaped()
assert(file_loader.active_count==0 and not next(file_loader.sessions),'closing must reap all slots')
print('image_loader_priority_spec: passed')
