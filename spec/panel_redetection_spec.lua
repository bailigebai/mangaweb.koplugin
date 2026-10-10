local Panels=require('mangaweb.reader_panels')
local Reader=require('mangaweb.reader')
local Preferences=require('mangaweb.panel_settings')
local Settings=require('mangaweb.settings')
local data,write_fail={},false
local settings=Settings:new{store={readSetting=function(_,key,d) return data[key] or d end,
    saveSetting=function(_,key,value) if write_fail then return false end;data[key]=value;return true end,
    flush=function() return true end}}
local preferences=Preferences:new{settings=settings}
assert(preferences:save('zero','1',{enabled=true},false))
local open_count,display,buffers,detected,queued,events=0,nil,{},{},{},{}
local reject,mode=false,nil
local panels
local ui={reader_viewport=function() return 600,800 end,
    panel_snapshot=function() return {buffer={},width=600,height=800} end,
    show_panel=function(_,buffer)
        if reject then return false end
        if display then assert(display.frees==0,'previous borrowed buffer must live until replacement') end
        display=buffer;events[#events+1]='show';return true
    end,
    detach_panel=function() display=nil;events[#events+1]='detach';return true end,
    restore_panel_page=function() events[#events+1]='whole';return true end}
local reader=Reader:new{store={},ui=ui,settings=settings}
reader.closed=false;reader.generation=1;reader.target=1;reader.position=1
reader.context={site_id='zero',comic_id='1',pages={{url='1'}}}
reader.entries[1]={index=1,ready=true,path='/processed.jpg',raw_path='/original.jpg'}
reader.position_detail={index=1,segment='whole',pan_y=0}
reader.panel_preferences=preferences
local source={open=function(_,_,request,cb)
    open_count=open_count+1
    assert(request.page_path=='/original.jpg')
    local handle={closed=false,detection_raster=function() return {buffer={}} end}
    function handle:render(panel)
        if mode=='render_fail' then return nil,'panel_render_failed' end
        local buffer={id=panel.id,frees=0}
        function buffer:free()
            self.frees=self.frees+1
            assert(self.frees==1 and display~=self,'only detached/non-displayed allocations may be freed once')
        end
        buffers[#buffers+1]=buffer;return buffer
    end
    function handle:close() assert(not self.closed);self.closed=true end
    cb.on_ready(handle)
    return {cancel=function() end}
end}
local detector={detect=function(_,options)
    detected[#detected+1]=options
    if mode=='detect_fail' then return nil,'panel_content_uncovered' end
    if mode=='close' then panels:close() end
    local strength=options.strength_percent or 100
    return {{id=strength..'-a',x=0,y=0,w=1,h=.5},{id=strength..'-b',x=0,y=.5,w=1,h=.5}}
end}
panels=Panels:new{reader=reader,ui=ui,source=source,detector=detector,
    schedule=function(fn) queued[#queued+1]=fn end}
reader.panels=panels
local function apply(changes)
    local undo
    return panels:configure(changes,function()
        local saved,reason,rollback=preferences:save('zero','1',changes,false)
        undo=rollback;return saved,reason
    end,function() if undo then assert(undo()) end end)
end
assert(panels:enter())
assert(detected[1].strength_percent==100 and detected[1].min_area_permille==2
    and detected[1].frame_min==1 and detected[1].dialogue_distance_percent==12,
    'initial entry must pass all recognition parameters')
assert(panels:move(1) and panels.session.index==2)
local old=display
assert(apply{strength_percent=150,min_area_permille=5,frame_min=2,dialogue_distance_percent=20})
assert(open_count==1 and #detected==2 and detected[2].strength_percent==150
    and detected[2].min_area_permille==5 and detected[2].frame_min==2
    and detected[2].dialogue_distance_percent==20,'re-identify must use current local handle and complete parameters')
assert(panels.session.index==1 and display.id=='150-a' and old.frees==1)
for _,fn in ipairs(queued) do fn() end
assert(panels.session.next_buffer.id=='150-b','obsolete pre-render cannot publish an old layout')
old=display;write_fail=true
assert(not apply{strength_percent=200})
assert(display==old and old.frees==0 and preferences:for_comic('zero','1').strength_percent==150)
write_fail=false;reject=true
assert(not apply{strength_percent=200})
assert(display==old and panels.session.panels[1].id=='150-a'
    and preferences:for_comic('zero','1').strength_percent==150,'display rejection must roll back both layout and preferences')
reject=false;mode='detect_fail';events={}
assert(not apply{strength_percent=200})
assert(not panels.session:is_active() and not display and events[1]=='detach'
    and preferences:for_comic('zero','1').strength_percent==150,'uncertain dialogue must detach before fallback, keeping prior settings')
mode=nil;assert(panels:enter());mode='render_fail';events={}
assert(not apply{strength_percent=200} and not display and events[1]=='detach')
mode=nil;assert(panels:enter());mode='close'
assert(not apply{strength_percent=200} and not panels.session and not display)
for _,fn in ipairs(queued) do fn() end
for _,buffer in ipairs(buffers) do assert(buffer.frees==1,'all cancelled/replaced buffers must be released once') end
print('panel_redetection_spec: cached original reuse, complete options, cancel, fallback and preference/display rollback passed')
