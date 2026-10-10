local fixture=require('spec.helpers.reader_ui')
local adapter,reader,manager=fixture()
local raw={free=function() error('whole page must remain alive') end}
local Image=adapter.image_widget:extend{}
function Image:init() self._bb=self.image or raw end
function Image:free() self.freed=true;self._bb=nil end
adapter.image_widget=Image
assert(adapter:show_page('/raw/page.jpg',11,178,{segment='right',pan_y=40,fit_mode='width'}))
local page=adapter.reader_widget
local whole=page.image
local a={free=function() error('only PanelSession frees panel buffers') end}
assert(adapter:show_panel(a,{page_index=11,panel_id='first',index=1,count=2,view='context',rotation=0,zoom=1}))
assert(page.image.image==a and page.image.image_disposable==false and not whole.freed)
assert(adapter:panel_snapshot().buffer==raw)
local previous=page.image
assert(adapter:show_panel(a,{page_index=11,panel_id='second',index=2,count=2,view='free',navigation='vertical'}))
assert(previous.freed and not whole.freed)
local pan,zoom,entered=0,0,0
function reader:pan_panel(dx,dy) pan=pan+1;assert(dx==8 and dy==-4);return true end
function reader:zoom_panel(factor) zoom=zoom+1;assert(factor==1.25);return true end
function reader:enter_panel_mode() entered=entered+1;return true end
assert(page:onGesture{ges='pan_release',relative={x=8,y=-4}} and pan==1)
assert(page:onGesture{ges='spread'} and zoom==1)
local turns=reader.turns
assert(page:onGesture{ges='swipe',direction='west'} and reader.turns==turns)
assert(adapter:detach_panel() and page.image==whole and not whole.freed)
assert(page.segment=='right' and page.pan_y==40 and page.fit_mode=='width')
assert(page:onGesture{ges='hold'} and entered==1)
assert(adapter:_show_reader_controls())
assert(page:onGesture{ges='hold'} and entered==1 and manager.stack[#manager.stack]==page)
assert(page:onGesture{ges='unrecognized'})
page:close_controls();page:set_loading(true)
assert(page:onGesture{ges='hold'} and entered==1)
page:set_loading(false)
adapter:close_reader()
assert(whole.freed and not adapter:show_panel(a,{}))
print('native_panel_reader_spec: borrowed image ownership, restoration, gestures and modal guards passed')
