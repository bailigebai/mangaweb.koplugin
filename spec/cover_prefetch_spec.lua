local Prefetch=require('mangaweb.cover_prefetch')
local calls,releases,scheduled={},0,{}
local alive=true
local loader={request=function(_,g,spec,cb)assert(g==7 and spec.cache_only and spec.priority==4);calls[#calls+1]=cb end,
    release=function()releases=releases+1 end}
local prefetch=Prefetch:new{loader=loader,generation=7,alive=function()return alive end,
    defer=function(cb)scheduled[#scheduled+1]=cb;return true end}
local specs={};for i=1,20 do specs[i]={key=tostring(i),url='https://img/'..i}end
prefetch:add(specs);prefetch:add(specs)
assert(#calls==0 and #scheduled==1, 'background prefetch must let the visible page render first')
scheduled[1]();assert(#calls==2, 'at most two hidden covers should be queued at once')
calls[1].on_ready{cached=true};assert(releases==1)
scheduled[2]();assert(#calls==3)
alive=false;calls[2].on_error{code='network_error'}
assert(releases==2)
if scheduled[3]then scheduled[3]()end
assert(#calls==3, 'a retired page must not start more prefetch requests')
print('cover_prefetch_spec: passed')
