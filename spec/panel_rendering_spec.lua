local Rendering=require('mangaweb.panel_rendering')
local Gray=require('mangaweb.gray_enhance')
local Tone=require('mangaweb.tone_adjust')
local opened, borrowed_frees, buffers, fail = nil,0,{},false
local borrowed={free=function() borrowed_frees=borrowed_frees+1 end}
local source={open=function(_,_,request,cb)
    opened=request.page_path
    local handle={closed=false}
    function handle:detection_raster() return {buffer=borrowed,width=100,height=100} end
    function handle:render(_,options)
        if options.max_pixels and (options.max_pixels<=0 or options.max_pixels~=options.max_pixels) then return nil,'invalid_pixel_budget' end
        local b={pixel=128,frees=0,getWidth=function() return 300 end,getHeight=function() return 400 end,
            free=function(self) self.frees=self.frees+1 end}
        buffers[#buffers+1]=b;return b
    end
    function handle:close() self.closed=true end
    cb.on_ready(handle);return {cancel=function() handle:close() end}
end}
local preferences={gray_enabled=true,gray_preset='clear',tone_enabled=true,tone_preset='clear'}
local rendering=Rendering:new{source=source,settings=preferences,deps={lut_applier=function(b,lut)
    b.pixel=lut[b.pixel];return not fail
end}}
local handle
rendering:open(1,{page_path='/cache/raw.jpg',page_buffer=borrowed,screen_width=600,screen_height=800},
    {on_ready=function(h) handle=h end})
local b=assert(handle:render({id='one'},{view='cut'}))
assert(opened=='/cache/raw.jpg' and borrowed_frees==0)
local lut=Tone.combine_lut(Gray.build_lut(Gray.find('clear')),Tone.build_lut(Tone.find('clear')))
assert(b.pixel==lut[128] and b.frees==0)
b:free();fail=true
local rejected,reason=handle:render({id='one'},{view='cut'})
assert(rejected==nil and reason=='panel_processing_failed' and buffers[#buffers].frees==1)
assert(handle:render({id='one'},{max_pixels=-1})==nil)
handle:close();handle:close();assert(borrowed_frees==0)
local invalid
rendering:open(2,{page_path='/cache/raw.jpg',screen_width=0/0,screen_height=800},
    {on_error=function(reason) invalid=reason end})
assert(invalid=='panel_invalid_dimensions')
-- Exercise the copied Source itself: open/getSize succeed but MuPDF draw fails.
-- A processed whole-page buffer must never become a successful panel source.
local Source=require('mangaweb.panel_source')
local fallback_count,lut_count,source_closed=0,0,0
local processed={getWidth=function() return 600 end,getHeight=function() return 800 end,
    free=function() error('the original processed whole page is borrowed') end,
    viewport=function()
        fallback_count=fallback_count+1
        return {free=function() end,scale=function()
            return {getWidth=function() return 300 end,getHeight=function() return 400 end,free=function() end}
        end}
    end}
local sample_first,draw_count=false,0
local original_source=Source:new{
    draw_context={new=function() return {} end},
    mupdf={openDocument=function()
        return {close=function() source_closed=source_closed+1 end,
            openPage=function()
                return {getSize=function() return 2400,3200 end,close=function() end,
                    draw_new=function(_,_,w,h)
                        draw_count=draw_count+1
                        if sample_first and draw_count==1 then
                            return {getWidth=function() return w end,getHeight=function() return h end,free=function() end}
                        end
                        error('MuPDF draw failed')
                    end}
            end}
    end}}
local raw_request={page_path='/cache/original.jpg',page_buffer=processed,screen_width=600,screen_height=800}
local strict=Rendering:new{source=original_source,settings=preferences,
    deps={lut_applier=function() lut_count=lut_count+1;return true end}}
strict:open(3,raw_request,{on_ready=function(value) handle=value end})
local raster=handle:detection_raster()
assert(raster==nil and fallback_count==0 and lut_count==0,
    'failed raw sampling must not resample the processed whole-page image')
handle:close()
sample_first,draw_count=true,0
strict:open(4,raw_request,{on_ready=function(value) handle=value end})
assert(handle:detection_raster())
assert(handle:render({x=0,y=0,w=0.5,h=0.5},{view='cut'})==nil
    and fallback_count==0 and lut_count==0,
    'a later raw clip failure must not publish or enhance a processed fallback')
handle:close()
sample_first,draw_count=false,0
local unfiltered=Rendering:new{source=original_source,settings={}}
unfiltered:open(5,raw_request,{on_ready=function(value) handle=value end})
assert(handle:render({x=0,y=0,w=0.5,h=0.5},{view='cut'})==nil and fallback_count==0,
    'raw-only clarity must hold with enhancement disabled too')
handle:close()
assert(source_closed==3 and raw_request.page_buffer==processed,
    'source documents close once and the caller request is not mutated')
local restored,published,detected=0,0,0
local session=require('mangaweb.panel_session'):new{source=strict,screen_width=600,screen_height=800,
    detector={detect=function() detected=detected+1;return {{id='one',x=0,y=0,w=1,h=1}} end}}
session:start(raw_request,{on_fallback=function() restored=restored+1;return true end,
    on_panel=function() published=published+1;return true end})
assert(restored==1 and published==0 and detected==0 and not session:is_active(),
    'actual Session must restore whole-page reading when original sampling fails')
assert(source_closed==4 and fallback_count==0 and lut_count==0)
print('panel_rendering_spec: raw source, combined LUT, failure release and validation passed')
