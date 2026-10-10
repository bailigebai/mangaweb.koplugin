local Loader=require('mangaweb.image_loader')
local network,workers={},{}
local temp={new_session=function()return{}end,write=function(_,_,name)return '/temp/'..name..'.jpg'end,
    path=function(_,_,name,ext)return '/temp/'..name..'.'..ext end,track=function(_,_,p)return p end,
    remove=function()end,remove_session=function()end}
local loader=Loader:new{max_active=6,max_processing=2,temp_files=temp,
    http={get=function(_,_,_,cb)network[#network+1]=cb;return{cancel=function()end}end},
    async={available=function()return true end,run=function(_,done,options)workers[#workers+1]=done;
        return{cancel=function()options.on_reaped()end}end}}
local gen=loader:begin_session('cover')
for i=1,12 do loader:request(gen,{key=tostring(i),url='https://img/'..i,stage='cover',profile={extension='jpg'}},{})end
assert(#network==6, 'six independent cover requests must start without waiting for prior images')
for i=1,6 do network[i].on_success('\255\216\255'..string.rep('a',20))end
assert(#workers==2 and loader.processing_count==2, 'no more than two processors may decode originals at once')
workers[1](true,{metadata={width=320,height=512}})
assert(#workers==3 and loader.processing_count==2, 'queued processing must resume after a slot becomes free')
loader:cancel_generation(gen)
assert(loader.active_count==0 and loader.processing_count==0)
print('cover_pipeline_spec: passed')
