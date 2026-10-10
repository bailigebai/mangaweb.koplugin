local Adapter=require('mangaweb.ui.koreader')
local requests,releases,updates={}, {},0
local loader={begin_session=function()return 1 end,cancel_generation=function()end,
    release=function(_,_,key)releases[key]=true end,
    request=function(_,_,spec,cb)
        local job={spec=spec,cb=cb};requests[#requests+1]=job
        return{cancel=function()job.canceled=true end}
    end}
local adapter=Adapter:new{cover_loader=loader}
local widget={preview_w=150,preview_h=230,cover_w=250,cover_h=400,
    has_cover=function()return false end,set_cover=function()return true end,
    update_model=function(_,current)updates=updates+1;assert(current.preview_state=='error');return true end,
    has_preview=function()return false end,set_preview=function()return true end}
local model={page='detail',selected_chapter_id='c2',preview_page=2,
    detail={card={site_id='zero',comic_id='a',chapter_id='c2'}},preview_pages={}}
for i=1,4 do model.preview_pages[i]={url='https://img/'..(i+4)..'.jpg'}end
adapter.widget=widget
adapter:_load_detail_cover(model,widget)
assert(#requests==5)
assert(requests[1].spec.stage=='preview' and requests[1].spec.index==5,
    'using the first preview as a missing cover must share its original page download')
for i=2,5 do
    assert(requests[i].spec.index==i+3 and requests[i].spec.chapter_id=='c2',
        'preview requests need the global image index and chapter used by the reader')
end
adapter:_load_detail_cover(model,widget)
assert(#requests==5, 'a model repaint must retain existing preview requests')
local old=requests[2]
model.preview_page=3
for i=1,4 do model.preview_pages[i]={url='https://img/'..(i+8)..'.jpg'}end
adapter:_load_detail_cover(model,widget)
assert(old.canceled and releases[old.spec.key], 'leaving a preview window must release its tasks and pins')
assert(old.cb.on_ready{buffer={}}==false, 'late preview results must not paint the new window')
assert(requests[2].canceled and requests[3].canceled and requests[4].canceled and requests[5].canceled)
old.cb.on_error{code='image_error'}
assert(updates==0, 'an old preview failure must not change the new window')
local count=#requests
requests[count].cb.on_error{code='image_error'}
assert(model.preview_state=='error' and model.preview_error.code=='image_error' and updates==1,
    'an active thumbnail failure must display the native retry-preview controls')
assert(#requests==count, 'showing a synchronous preview failure must not recursively queue retries')
print('detail_preview_lifecycle_spec: passed')
