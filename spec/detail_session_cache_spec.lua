local Detail=require('mangaweb.ui.detail')
local Shell=require('mangaweb.ui.shell')
local n,hashes=0,{}
local keyer=require('mangaweb.catalogue_cache'):new{storage={root='/cache/catalogues',fs={list=function()return{}end},
    sha256=function(v)if not hashes[v]then n=n+1;hashes[v]=string.format('%064x',n)end;return hashes[v]end},json={}}
local cookie='one'
local source={id='zero',origin='https://zero.test',auth={cookie=function()return cookie end},details=0,page_calls=0}
function source:detail(id,cb)
    self.details=self.details+1
    cb.on_success{card={site_id=self.id,comic_id=id,title='title'},chapters={{id='c1'}}}
    return{cancel=function()end}
end
function source:pages(_,_,cb)
    self.page_calls=self.page_calls+1
    cb.on_success{pages={{url='https://img/1.jpg',headers={Referer=self.origin}}}}
    return{cancel=function()end}
end
local shell=Shell:new{source_registry={},catalogue_cache=keyer}
local card={site_id='zero',comic_id='a'}
local function show()
    local detail=Detail:new{source=source,shell=shell}
    assert(detail:show(card));assert(shell:model().preview_state=='ready')
    return detail
end
local first=show();first:close()
local second=show()
assert(source.details==1 and source.page_calls==1,
    'quickly reopening a detail must reuse both its detail and image list, without waiting on HTML again')
assert(shell:model().detail.card.pages[1].url=='https://img/1.jpg')
shell:model().detail.card.title='UI changed title'
second:close();local third=show()
assert(shell:model().detail.card.title=='title', 'view mutations must not contaminate a cached detail')
assert(shell:model().actions.preview_retry())
assert(source.page_calls==2, 'explicit preview retry must request a fresh image list')
assert(shell:model().actions.retry())
assert(source.details==2 and source.page_calls==3, 'explicit detail retry must bypass both cached stages')
third:close();cookie='two';show()
assert(source.details==3 and source.page_calls==4, 'different account cookies must not reuse private metadata')
source.origin='https://other.test';show()
assert(source.details==4 and source.page_calls==5, 'domain changes must not reuse old CDN locations')

local Cache=require('mangaweb.detail_cache')
local now=1
local cache=Cache:new{keyer=keyer,clock=function()return now end,max_entries=2,ttl=60}
local value={pages={{url='https://img/a'}}}
assert(cache:put(source,'a','c1','pages',value))
assert(cache:put(source,'b','c1','pages',value))
assert(cache:put(source,'c','c1','pages',value))
assert(not cache:get(source,'a','c1','pages') and cache:get(source,'c','c1','pages'))
now=62;assert(not cache:get(source,'c','c1','pages'), 'expired signed URLs must be re-enumerated')
assert(not cache:put(source,'big',nil,'detail',{body=string.rep('x',512*1024+1)}), 'cache entries must be bounded')
local delayed={id='zero',origin='https://zero.test',auth=source.auth}
local details_cb,pages_cb,details_count,pages_count
details_count,pages_count=0,0
function delayed:detail(_,cb)details_count=details_count+1;details_cb=cb;return{cancel=function()end}end
function delayed:pages(_,_,cb)pages_count=pages_count+1;pages_cb=cb;return{cancel=function()end}end
local isolated=Shell:new{source_registry={},catalogue_cache=keyer}
local before=Detail:new{source=delayed,shell=isolated}
cookie='old';assert(before:show(card))
cookie='new';details_cb.on_success{card={site_id='zero',comic_id='a',title='old account'},chapters={{id='c1'}}}
local after=Detail:new{source=delayed,shell=isolated};assert(after:show(card))
assert(details_count==2, 'a response begun under an older cookie must not be cached as the new account')
details_cb.on_success{card={site_id='zero',comic_id='a'},chapters={{id='c1'}}}
cookie='third';pages_cb.on_success{pages={{url='https://img/private'}}}
assert(isolated:model().preview_state=='ready', 'cookie rotation must still finish loading normally')
assert(not isolated.detail_cache:get(delayed,'a','c1','pages'),
    'image lists begun under an older cookie must not be cached as the new account')
print('detail_session_cache_spec: passed')
