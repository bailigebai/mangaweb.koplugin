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
-- Exercise the real Page publisher through Session.configure: native widget
-- allocation may fail after decoding, before it can borrow a new allocation.
local Session=require('mangaweb.panel_session')
local buffers,freed_while_borrowed={},false
local handle={detection_raster=function() return {} end,close=function(self) self.closed=true end}
function handle:render()
    local buffer={frees=0}
    function buffer:free()
        freed_while_borrowed=freed_while_borrowed or page.image and page.image.image==self
        self.frees=self.frees+1
    end
    buffers[#buffers+1]=buffer;return buffer
end
local session=Session:new{screen_width=600,screen_height=800,
    source={open=function(_,_,_,cb) cb.on_ready(handle);return {} end},
    detector={detect=function() return {{id='one',x=0,y=0,w=1,h=.5},{id='two',x=0,y=.5,w=1,h=.5}} end}}
assert(session:start({}, {on_panel=function(buffer,_,index,count)
    return adapter:show_panel(buffer,{index=index,count=count})
end}))
local before_image,before_root,before_buffer=page.image,page[1],session.current_buffer
local saved=100
local function configure()
    return session:configure({strength_percent=150},function() saved=150;return true end,
        function() saved=100 end,{strength_percent=150})
end
local make_surface=page._new_image_surface
page._new_image_surface=function() error('native image surface allocation failure') end
assert(not configure())
assert(page.image==before_image and page[1]==before_root and session.current_buffer==before_buffer
    and saved==100 and before_buffer.frees==0 and buffers[#buffers].frees==1
    and not freed_while_borrowed,'publication failure must detach candidate before its owner frees it')
page._new_image_surface=make_surface
local original_new=adapter.overlap_group.new
function adapter.overlap_group:new(options)
    if options.allow_mirroring==false then error('native root allocation failure') end
    return original_new(self,options)
end
assert(not configure() and page.image==before_image and page[1]==before_root
    and not freed_while_borrowed and saved==100 and before_buffer.frees==0)
adapter.overlap_group.new=original_new
assert(configure() and saved==150 and before_buffer.frees==1 and not freed_while_borrowed)
local bridge_closed=false
page.graydither_bridge={attachImage=function() error('optional gray service failure') end,
    close=function() bridge_closed=true end}
assert(configure() and bridge_closed and page.graydither_bridge==nil and not freed_while_borrowed,
    'optional gray service failure must leave the accepted panel owned and visible')
assert(adapter:detach_panel());session:close()
for _,buffer in ipairs(buffers) do assert(buffer.frees==1) end
adapter:close_reader()
assert(whole.freed and not adapter:show_panel(a,{}))
print('native_panel_reader_spec: borrowed image ownership, restoration, gestures and modal guards passed')
