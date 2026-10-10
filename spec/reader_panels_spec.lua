local Panels=require('mangaweb.reader_panels')
local Reader=require('mangaweb.reader')
local scheduled,opened,closed,shown,downloads,events={},{},0,0,0,{}
local source={open=function(_,_,request,callbacks)
    opened[#opened+1]={request=request,callbacks=callbacks}
    return {cancel=function() end}
end}
local function ready(n)
    local handle={closed=false,detection_raster=function() return {} end,
        render=function() return {free=function() events[#events+1]='free' end} end}
    function handle:close() assert(not self.closed);self.closed=true;closed=closed+1 end
    opened[n].callbacks.on_ready(handle);return handle
end
local ui={reader_viewport=function() return 600,800 end,
    show_page=function() events[#events+1]='whole';return true end,
    panel_snapshot=function() return {buffer={},width=600,height=800} end,
    show_panel=function() shown=shown+1;events[#events+1]='panel';return true end,
    detach_panel=function() events[#events+1]='detach';return true end,
    restore_panel_page=function() events[#events+1]='restore';return true end}
local reader=Reader:new{store={},ui=ui}
reader.closed=false;reader.generation=1;reader.target=1;reader.position=1
reader.context={site_id='zero',comic_id='1',pages={{url='1'},{url='2'},{url='3'}}}
reader.entries[1]={index=1,ready=true,path='/processed/1.png',raw_path='/raw/1.jpg'}
reader.position_detail={index=1,segment='right',pan_y=40}
reader.reader_settings.preload_pages=0
local prefs={enabled=true,view='context',rotation=0,order='follow'}
local panels=Panels:new{reader=reader,ui=ui,source=source,
    preferences=function() return prefs end,detector={detect=function()
        return {{id='a',x=0,y=0,w=1,h=0.5},{id='b',x=0,y=0.5,w=1,h=0.5}}
    end},schedule=function(fn) scheduled[#scheduled+1]=fn end}
reader.panels=panels
assert(panels:enter('first'))
assert(opened[1].request.page_path=='/raw/1.jpg')
panels:close();ready(1);assert(shown==0 and closed==1,'late callback must only close old handle')
assert(panels:enter('last'));ready(2)
local requested
reader._request=function(_,index) requested=index;downloads=downloads+1;return true end
assert(panels:move(1) and requested==2 and panels.pending=='first')
reader.entries[2]={index=2,ready=true,path='/processed/2.png',raw_path='/raw/2.jpg'}
reader.position=2;reader.target=2;reader.position_detail={index=2,segment='whole',pan_y=0}
panels:page_displayed();ready(3)
assert(panels:move(-1) and requested==1 and panels.pending=='last')
panels:close()
reader.position=1;reader.target=1;reader.position_detail={index=1,segment='right',pan_y=40}
assert(panels:enter('first'));ready(4)
local before=downloads
events={};panels:exit(true)
assert(downloads==before and reader.position_detail.segment=='right' and reader.position_detail.pan_y==40)
assert(events[1]=='detach' and events[2]=='free','detach before freeing borrowed display')
prefs.view='free';assert(panels:enter());ready(5)
assert(panels:move(1) and downloads==before,'free view consumes navigation without changing physical page')
panels:close();panels:close()
-- No panels: keep physical-page continuation, without trapping navigation.
panels.detector={detect=function() return nil,'no_panels' end};prefs.view='context'
assert(panels:enter());ready(6)
assert(panels:move(1) and requested==2)
panels:close()
print('reader_panels_spec: late completion, boundaries, fallback, raw lifetime and restore passed')
