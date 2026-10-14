local Reader=require('mangaweb.reader')
local fixture=require('spec.helpers.reader_ui')
local adapter,_,manager=fixture()
local mode,events,repaints=0,0,0
local scheduled={}
function manager:scheduleIn(delay,callback)scheduled[callback]=delay;return true end
function manager:unschedule(callback)scheduled[callback]=nil end
local screen=adapter.screen
function screen:getRotationMode()return mode end
function screen:getWidth()return mode%2==0 and 600 or 800 end
function screen:getHeight()return mode%2==0 and 800 or 600 end
function screen:getSize()return{w=self:getWidth(),h=self:getHeight()}end
package.loaded['ui/event']={new=function(_,name,value)return{name=name,mode=value}end}
function manager:broadcastEvent(event)
    assert(event.name=='SetRotationMode');events=events+1;mode=event.mode
    for _,widget in ipairs(self.stack)do if widget.onSetRotationMode then widget:onSetRotationMode(mode)end end
end
function manager:onRotation()repaints=repaints+1 end
local requests,callbacks,history,sessions={},nil,0,0
local loader={begin_session=function()sessions=sessions+1;return sessions end,
    release=function()end,cancel_generation=function()end,
    request=function(_,_,spec,cb)
        requests[#requests+1]=spec
        if spec.key:match('viewport')then callbacks=cb
        else cb.on_ready{path='/raw.jpg',cached_raw='/raw.jpg',metadata={width=1200,height=1600}}end
        return{cancel=function()end}
    end}
local store={save_history=function()history=history+1;return true end}
local reader=Reader:new{store=store,loader=loader,ui=adapter}
adapter.reader=reader
local root_model={page='site_center',sites={},actions={}}
local shell={model=function()return root_model end}
assert(adapter:show_fullscreen(shell))
local portrait_root=adapter.widget
assert(reader:open{site_id='zero',comic_id='a',chapter_id='c2',default_chapter_id='c1',
    pages={{url='https://image/1'}}})
local immediate={}
for callback,delay in pairs(scheduled)do if delay==0 then immediate[#immediate+1]=callback end end
for _,callback in ipairs(immediate)do scheduled[callback]=nil;callback()end
local function button(text)
    for _,row in ipairs(adapter.reader_controls.model.rows or {})do
        for _,b in ipairs(row.items or {})do if b.text==text then return b end end
    end
end
assert(adapter:_show_reader_controls())
assert(button('设备旋转'),'reading settings must include copied device rotation entry')
assert(button('设备旋转').callback())
for _,angle in ipairs{0,90,180,270}do assert(button(angle..'°'))end
local stale_button=button('0°')
local old,position,gen=adapter.reader_widget,reader:current_page(),reader.generation
assert(button('90°').callback())
assert(mode==1 and reader.context.chapter_id=='c2' and reader:current_page()==position)
assert(requests[#requests].source_path=='/raw.jpg','rotation must prepare from the owned original, never redownload')
callbacks.on_ready{path='/landscape.jpg',cached_raw='/raw.jpg',metadata={width=800,height=600}}
local landscape=adapter.reader_widget
assert(landscape~=old and old.released and landscape.width==800 and landscape.height==600)
assert(reader.generation==gen and reader:current_page()==position and history==1,
    'rotation preserves reader generation, chapter history and page index')
assert(landscape.page_gestures.Tap[1].range.w==800 and landscape.page_gestures.Tap[1].range.h==600,
    'native gesture bounds must match the rotated screen')
assert(stale_button.callback()==false and mode==1,'callbacks from the old rotation panel must be inert')
local same_events,same_requests=events,#requests
assert(button('90°').callback() and events==same_events and #requests==same_requests,'same angle is idle')
local dismissed=button('0°')
assert(adapter.reader_controls.model.navigation[1].callback())
assert(dismissed.callback()==false and mode==1,'leaving the rotation menu invalidates its callbacks')
assert(button('设备旋转').callback())
assert(button('180°').callback());callbacks.on_error{code='image_error'}
assert(mode==1 and adapter.reader_widget==landscape and not landscape.released,
    'processing failure rolls orientation back while retaining the visible page')
reader.reader_settings.gray_enabled=true;reader.reader_settings.gray_preset='clear'
for _,angle in ipairs{180,270,0,90}do
    assert(button(angle..'°').callback())
    local spec=requests[#requests]
    assert(spec.source_path=='/raw.jpg' and spec.profile.source_width==1200 and spec.profile.source_height==1600,
        'filter rotation must process the original source dimensions')
    callbacks.on_ready{path='/angle-'..angle..'.png',cached_raw='/raw.jpg',metadata={width=spec.profile.target_width,height=spec.profile.target_height}}
    assert(mode==angle/90 and reader:current_page()==position and reader.context.chapter_id=='c2')
end
landscape=adapter.reader_widget
local original_repaint=manager.onRotation
function manager:onRotation()error('host rotation failure')end
button('180°').callback()
assert(mode==1 and adapter.reader_widget==landscape and not landscape.released,'host error must roll back without dropping the page')
manager.onRotation=original_repaint
assert(button('180°').callback());local timed=callbacks
adapter.reader_rotation.operation.timer()
assert(mode==1 and adapter.reader_widget==landscape and timed.on_ready{path='/too-late.jpg'}==false,
    'a stalled preparation must time out and reject late images')
assert(button('270°').callback());local late=callbacks
reader:close()
assert(mode==1 and late.on_ready{path='/late.jpg'}==false and not adapter.reader_widget,
    'close cancels pending rotation; late callbacks cannot reopen reading')
assert(adapter.widget~=portrait_root and portrait_root.retired,'returning to the plugin rebuilds its content at the new size')
local root=adapter.root_renderer.root_widget
assert(root.width==800 and root.height==600 and root[1].width==800 and root[1].height==600,
    'plugin background must use live orientation after reading closes')
assert(root.ges_events.RootTap[1].range.w==800 and root.ges_events.RootTap[1].range.h==600)
assert(root.dimen and root.dimen.w==800 and root.dimen.h==600,'root paint bounds must follow the new orientation')
assert(repaints>0)
print('reader_rotation_spec: passed')
