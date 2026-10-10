local Adapter=require('mangaweb.ui.koreader')
local requests,canceled,begun={},0,0
local reader_loader={request=function()error('covers must not consume reading tasks')end}
local cover_loader={begin_session=function()begun=begun+1;return begun end,
    cancel_generation=function()canceled=canceled+1 end,
    request=function(_,generation,spec,cb)requests[#requests+1]={gen=generation,spec=spec,cb=cb}end}
local adapter=Adapter:new{loader=reader_loader,cover_loader=cover_loader}
local buffer, installs={},0
local grid={cells={[1]={}},cover_w=200,cover_h=300,
    has_cover=function()return false end,set_cover=function(_,_,value)buffer=value;installs=installs+1;return true end}
local model={grid={cells={{site_id='zero',comic_id='a',cover_url='https://img/a'}}}}
adapter.widget=grid
adapter:_load_covers(model,grid)
adapter:_load_covers(model,grid)
assert(#requests==1 and begun==1 and canceled==0, 'same visible grid updates must retain pending downloads')
assert(requests[1].spec.comic_id=='a')
model.grid.cells[1].cover_url='https://img/b'
adapter:_load_covers(model,grid)
assert(#requests==2 and begun==2 and canceled==1)
assert(requests[1].cb.on_ready{buffer={}}==false and installs==0)
assert(requests[2].cb.on_ready{buffer={}} and installs==1)
adapter:_cancel_covers();assert(canceled==2)
local library={page='library',items={{site_id='zero',comic_id='a',title='a'}}}
local existing={update_model=function(_,current)
    assert(not current.grid.cells[1].favorite, 'collection covers must not have a star overlay')
    return true
end}
assert(adapter:_build_collection_grid(library,existing)==existing)
-- Exercise the real render entry, which can cancel before _load_covers runs.
requests,canceled,begun={},0,0
local render_adapter=Adapter:new{loader=reader_loader,cover_loader=cover_loader,ui_manager={},menu={}}
local render_grid={page_id='browse',cells={[1]={}},cover_w=200,cover_h=300,
    has_cover=function()return false end,set_cover=function()return true end,
    update_model=function()return true end}
render_adapter.widget=render_grid
render_adapter._build_grid=function()return render_grid end
local render_model={page='browse',grid={cells={{site_id='zero',comic_id='a',cover_url='https://img/a'}}}}
assert(render_adapter:_render(render_model))
assert(render_adapter:_render(render_model))
assert(#requests==1 and begun==1 and canceled==0, 'the real render path must retain same-grid downloads')
-- Offscreen catalogue and collection covers are persisted after visible requests.
local hidden_calls, protected, ticks, released = {}, {}, {}, 0
local background_loader = {
    begin_session=function() return 20 end, cancel_generation=function()end,
    sync_protected=function(_,owner,specs,complete)
        protected[#protected+1]={owner=owner,specs=specs,complete=complete};return true
    end,
    request=function(_,g,spec,cb) hidden_calls[#hidden_calls+1]={spec=spec,cb=cb} end,
    release=function()released=released+1 end,
}
local background=Adapter:new{cover_loader=background_loader,
    ui_manager={nextTick=function(_,cb)ticks[#ticks+1]=cb end}}
background.widget=grid
local function card(id)return{site_id='zero',comic_id=id,cover_url='https://img/'..id}end
local background_model={grid={cells={card('visible'),card('next')}},
    cover_groups={{owner='local:zero',complete=true,items={card('visible'),card('filtered')}}}}
background:_load_covers(background_model,grid)
assert(#hidden_calls==1 and not hidden_calls[1].spec.cache_only)
assert(#protected==1 and #protected[1].specs==2 and protected[1].complete,
    'all favorites must be protected before visible cache writes')
ticks[1]()
assert(#hidden_calls==3 and hidden_calls[2].spec.cache_only and hidden_calls[3].spec.cache_only,
    'hidden catalogue and category-filtered favorites must also be cached')
hidden_calls[2].cb.on_ready{cached=true};assert(released==1)
background_model.cover_groups[1].items[3]={site_id='zero',comic_id='missing-cover'}
background:_load_covers(background_model,grid)
assert(not protected[#protected].complete, 'missing cover identities must retain previous protection markers')
background:_cancel_covers()
for i=2,#ticks do ticks[i]() end
assert(#hidden_calls==3, 'retired grids must not submit more hidden requests')
print('cover_ui_spec: passed')
