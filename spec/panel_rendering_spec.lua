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
print('panel_rendering_spec: raw source, combined LUT, failure release and validation passed')
