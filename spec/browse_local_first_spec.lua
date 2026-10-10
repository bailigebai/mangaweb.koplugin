local Browse=require('mangaweb.ui.browse')
local model,pending,puts,invalidated=nil,nil,0,0
local cached={cards={{site_id='zero',comic_id='1',title='旧漫画',cover_url='https://img/1.jpg'}},page=1,total_pages=2}
local cache={key=function()return 'key' end,get=function()return cached end,
    put=function()puts=puts+1 end,invalidate=function()invalidated=invalidated+1 end}
local source={id='zero',capabilities=function()return{categories=false,tags=false}end,
    image_headers=function()return {Referer='current-origin'}end,
    list=function(_,_,cb)pending=cb;return{cancel=function()end}end}
local shell={catalogue_cache=cache,registry_state=function()return{page=1}end,
    set_model=function(_,v)model=v;return true end,model=function()return model end,
    is_view=function()return true end}
local browse=Browse:new{source=source,shell=shell,view_token=1}
browse:load()
assert(model.grid.cells[1] and model.grid.cells[1].comic_id=='1' and model.refreshing,
    'cached cards must display before the website request returns')
assert(model.grid.cells[1].cover_headers.Referer=='current-origin')
pending.on_success{cards={{site_id='zero',comic_id='2',title='新漫画',cover_url='https://img/2.jpg'}},page=1,total_pages=2}
assert(model.grid.cells[1].comic_id=='2' and not model.refreshing and puts==1)
browse:load();pending.on_error{code='network_error'}
assert(model.grid.cells[1].comic_id=='1' and model.refresh_error.code=='network_error', 'network errors must retain the offline catalogue')
browse:load();pending.on_error{code='login_required'}
assert(not model.grid.cells[1] and model.state=='login_required' and invalidated==1)
browse:load();local late=pending;browse:close();late.on_success{cards={},page=1,total_pages=1}
assert(puts==1, 'closed views must not publish or persist late callbacks')
local account,snapshots='before',{}
shell.catalogue_cache={key=function()return account end,get=function(_,k)return snapshots[k]end,
    put=function(_,k,v)snapshots[k]=v end}
browse=Browse:new{source=source,shell=shell,view_token=2}
browse:load();account='after'
pending.on_success{cards=cached.cards,page=1,total_pages=2}
assert(snapshots.after and not snapshots.before, 'Set-Cookie refresh must store the catalogue in the current account namespace')
browse:load();assert(model.cached and model.grid.cells[1].comic_id=='1')
browse:close()
print('browse_local_first_spec: passed')
