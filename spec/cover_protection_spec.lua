local Cache=require('mangaweb.page_cache')
local files,hashes,n={}, {},0
local function sha(v)if not hashes[v]then n=n+1;hashes[v]=string.format('%064x',n)end;return hashes[v]end
local fs={mkdir=function()return true end,read=function(_,p,l)return files[p]and files[p]:sub(1,l)end,
    write=function(_,p,b)files[p]=b;return true end,rename=function(_,a,b)files[b]=files[a];files[a]=nil;return true end,
    remove=function(_,p)files[p]=nil;return true end,
    list=function(_,root)local result={};for p,b in pairs(files)do result[#result+1]={name=p:sub(#root+2),mode='file',mtime=1,size=#b}end;return result end}
local a={site_id='zero',comic_id='a',chapter_id='cover',index=1,url='https://img/a'}
local b={site_id='zero',comic_id='b',chapter_id='cover',index=1,url='https://img/b'}
local body='\255\216\255'..string.rep('a',40)
local cache=Cache:new{root='/cache/covers',fs=fs,sha256=sha,upper_bytes=60,lower_bytes=0}
assert(cache:sync_protected('local:zero',{a},true))
assert(cache:put(a,body));cache:put(b,body)
assert(cache:get(a) and not cache:get(b), 'favorite covers must survive rolling cache cleanup')
cache=Cache:new{root='/cache/covers',fs=fs,sha256=sha,upper_bytes=1,lower_bytes=0}
cache:trim();assert(cache:get(a), 'favorite protection must survive restarting the plugin')
assert(cache:sync_protected('other-account',{a},false))
assert(cache:sync_protected('local:zero',{},true));assert(cache:get(a), 'one owner must not unprotect another account')
assert(cache:sync_protected('other-account',{},true));assert(not cache:get(a), 'unfavorited covers must return to normal cleanup')
print('cover_protection_spec: passed')
