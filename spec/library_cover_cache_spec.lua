local Library=require('mangaweb.ui.library')
local calls,model,cancels={},nil,0
local source={id='zero',origin='https://zero.example',capabilities=function()return{official_favorites=true}end,
    favorites=function(_,options,cb)calls[#calls+1]={options=options,cb=cb};return{cancel=function()cancels=cancels+1 end}end,
    remove_favorite=function()end}
local shell={catalogue_cache={key=function(_,_,_,kind)return kind end,get=function()end,put=function()end},
    set_model=function(_,v)model=v;return true end,is_view=function()return true end}
local records={{site_id='zero',comic_id='a',cover_url='https://img/a'},
    {site_id='zero',comic_id='b',cover_url='https://img/b'}}
local store={list_categories=function()return{{id=2,name='分类'}}end,list_favorites=function()return records end,
    list_category_items=function()return{records[1]}end}
local registry={current=function()return source end,current_id=function()return 'zero'end}
local library=Library:new{shell=shell,store=store,source_registry=registry,category_id=2}
library:show()
assert(#model.items==1 and #model.cover_groups[1].items==2, 'category filters must not restrict the complete local cover cache')
calls[1].cb.on_success{cards={{site_id='zero',comic_id='x',cover_url='https://img/x'}},page=1,total_pages=2,total_count=2}
assert(#calls==2 and calls[2].options.page==2, 'official covers from unvisited website pages must also be discovered')
assert(model.cover_groups[2].complete==false)
calls[2].cb.on_success{cards={{site_id='zero',comic_id='y',cover_url='https://img/y'}},page=2,total_pages=2,total_count=2}
assert(#model.cover_groups[2].items==2 and model.cover_groups[2].complete)
assert(#model.items==1 and model.items[1].comic_id=='a', 'background scanning must not change the selected collection')
library:load_official(1)
calls[#calls].cb.on_success{cards={{site_id='zero',comic_id='x'}},page=1,total_pages=2,total_count=2}
calls[#calls].cb.on_success{cards={{site_id='zero',comic_id='x'}},page=2,total_pages=2,total_count=2}
assert(not model.cover_groups[2].complete, 'repeated server pages must never replace the previous complete protection list')
library:load_official(1)
calls[#calls].cb.on_success{cards={{site_id='zero',comic_id='x'}},page=1,total_pages=2,total_count=2}
calls[#calls].cb.on_success{cards={{site_id='zero',comic_id='y'}},page=2,total_pages=2,total_count=3}
assert(not model.cover_groups[2].complete, 'a collection changing during scanning cannot certify a full snapshot')
library:load_official(1);local first=calls[#calls]
first.cb.on_success{cards={{site_id='zero',comic_id='z',cover_url='https://img/z'}},page=1,total_pages=3}
local pending=calls[#calls];library:close();local previous=model
pending.cb.on_success{cards={},page=2,total_pages=3}
assert(model==previous and cancels>=1, 'closed collections must cancel and reject late background page scans')
shell.catalogue_cache.get=function()return{cards={{site_id='zero',comic_id='cached',cover_url='https://img/cached'}},
    page=1,total_pages=1,total_count=1}end
library=Library:new{shell=shell,store=store,source_registry=registry,category_id='official:zero'}
library:show()
assert(model.items[1].comic_id=='cached' and model.state=='ready')
calls[#calls].cb.on_error{code='network_error'}
assert(model.state=='ready' and model.items[1].comic_id=='cached', 'offline official favorites must retain their cached catalogue')
library:load_official(1)
local outstanding=calls[#calls];local before_cancel=cancels
assert(library:remove_official(model.items[1]) and cancels==before_cancel+1,
    'removing a cached favorite must cancel its outstanding catalogue GET')
outstanding.cb.on_success{cards={},page=1,total_pages=1,total_count=0}
assert(model.items[1].comic_id=='cached', 'a canceled GET cannot overwrite pending removal')
library:close()
local account,saved='before',nil
shell.catalogue_cache={key=function(_,_,_,kind)return account..':'..kind end,get=function()end,
    put=function(_,key)saved=key end}
library=Library:new{shell=shell,store=store,source_registry=registry}
library:show();local owner=model.cover_groups[2].owner;account='after'
calls[#calls].cb.on_success{cards={{site_id='zero',comic_id='fresh',cover_url='https://img/fresh'}},
    page=1,total_pages=1,total_count=1}
assert(saved=='after:favorites', 'official snapshots must also follow cookies merged before a successful response')
assert(model.cover_groups[2].owner==owner and model.cover_groups[2].complete,
    'Cookie refresh must not leave permanent protection owners from old sessions')
library:close()
print('library_cover_cache_spec: passed')
