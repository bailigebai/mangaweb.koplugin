local Catalogue=require('mangaweb.catalogue_cache')
local files,serial,hashes={},0,{}
local function sha(value)if not hashes[value]then serial=serial+1;hashes[value]=string.format('%064x',serial)end;return hashes[value]end
local snapshots={}
local codec={encode=function(value)local key='json'..(#snapshots+1);snapshots[#snapshots+1]=value;return key end,
    decode=function(body)local n=tonumber(body:match('^json(%d+)$'));assert(n);return snapshots[n]end}
local storage={root='/cache/catalogues',sha256=sha,_ensure_dir=function()return true end,
    fs={read=function(_,path,limit)return files[path]and files[path]:sub(1,limit)end,
        write=function(_,path,body)files[path]=body;return true end,
        rename=function(_,a,b)files[b]=files[a];files[a]=nil;return true end,
        remove=function(_,path)files[path]=nil;return true end,
        list=function()local entries={};for path,body in pairs(files)do entries[#entries+1]={name=path:match('[^/]+$'),mtime=1,size=#body,mode='file'}end;return entries end}}
local cache=assert(Catalogue:new{storage=storage,json=codec,max_entries=2})
local cookie='private-cookie'
local source={id='zero',origin='https://zero.example',auth={active_cookie=function()return cookie end}}
local first=assert(cache:key(source,{page=1},'browse'))
assert(cache:key(source,{page=2},'browse')~=first)
cookie='other-account';assert(cache:key(source,{page=1},'browse')~=first);cookie='private-cookie'
local cards={{site_id='zero',comic_id='1',title='漫画',cover_url='https://img/1.jpg',
    cover_headers={Cookie='private-cookie'},pages={{url='https://chapter/1.jpg'}},on_tap=function()end}}
assert(cache:put(first,{cards=cards,page=1,total_pages=5}))
local value=assert(cache:get(first))
assert(value.cards[1].comic_id=='1' and not value.cards[1].cover_headers and not value.cards[1].pages and not value.cards[1].on_tap)
assert(not snapshots[1].cards[1].cover_headers, 'credentials and chapter data must never be persisted')
files['/cache/catalogues/'..first..'.json']='broken'
assert(not cache:get(first))
for i=1,4 do assert(cache:put(sha(tostring(i)),{cards=cards,page=i,total_pages=5}))end
local count=0;for path in pairs(files)do if path:match('%.json$')then count=count+1 end end
assert(count<=2, 'catalogue snapshots must be bounded')
print('catalogue_cache_spec: passed')
