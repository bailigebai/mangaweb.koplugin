local Source = require('mangaweb.panel_source')
local Gray = require('mangaweb.gray_enhance')
local Tone = require('mangaweb.tone_adjust')
local Rendering = {}
Rendering.__index = Rendering
local Handle = {}
Handle.__index = Handle

local function positive(value)
    return type(value)=='number' and value==value and value>0 and value<math.huge
end
local function free(value)
    if value then pcall(value.free,value) end
end
local function lut_for(settings)
    local gray = settings.gray_enabled and Gray.find(settings.gray_preset or 'original',settings.gray_custom_presets)
    local tone = settings.tone_enabled and Tone.find(settings.tone_preset or 'original',settings.tone_custom_presets)
    if settings.gray_enabled and not gray or settings.tone_enabled and not tone then
        return nil,'panel_processing_failed'
    end
    return Tone.combine_lut(gray and Gray.build_lut(gray),tone and Tone.build_lut(tone))
end

function Rendering:new(options)
    options=options or {}
    return setmetatable({source=options.source or Source:new(options.deps),
        settings=options.settings or {},applier=options.deps and options.deps.lut_applier or Gray.apply_lut},self)
end

function Handle:close()
    if self.closed then return end
    self.closed=true
    free(self.sample);self.sample=nil
    self.raw:close()
end

function Handle:detection_raster()
    if self.closed then return nil,'panel_source_unavailable' end
    local raster,reason=self.raw:detection_raster()
    if not raster then return nil,reason end
    -- Sample the unprocessed source when MuPDF is available. The displayed
    -- whole page may already have a LUT or have been scaled down to the screen.
    if self.raw.kind=='mupdf' then
        if not self.sample then
            self.sample=self.raw:render({x=0,y=0,w=1,h=1},
                {view='cut',screen_width=480,screen_height=480,max_pixels=480*480})
        end
        if not self.sample then return nil,'panel_detection_failed' end
        return {buffer=self.sample,width=self.sample:getWidth(),height=self.sample:getHeight()}
    end
    return raster
end

function Handle:render(panel,options)
    if self.closed then return nil,'panel_source_unavailable' end
    -- Applying a second LUT to the already processed fallback would change
    -- both contrast and sharpness. Let the reader restore its whole page.
    if self.lut and self.raw.kind=='buffer' then return nil,'panel_source_unavailable' end
    local buffer,reason=self.raw:render(panel,options)
    if not buffer then return nil,reason end
    local measured,w,h=pcall(function() return buffer:getWidth(),buffer:getHeight() end)
    if not measured or not positive(w) or not positive(h) or w*h>self.budget then
        free(buffer);return nil,'panel_invalid_dimensions'
    end
    if self.lut then
        local ok,applied=pcall(self.applier,buffer,self.lut,true)
        if not ok or applied~=true then free(buffer);return nil,'panel_processing_failed' end
    end
    return buffer
end

function Handle:pan_options(panel,options,dx,dy)
    return self.raw:pan_options(panel,options,dx,dy)
end

function Rendering:open(generation,request,callbacks)
    callbacks=callbacks or {};request=request or {}
    local w,h=request.screen_width,request.screen_height
    local settings=type(self.settings)=='function' and self.settings() or self.settings
    local lut,reason=lut_for(settings)
    if not positive(w) or not positive(h) or w*h>8*1024*1024 or reason then
        if callbacks.on_error then callbacks.on_error(reason or 'panel_invalid_dimensions') end
        return {cancel=function() end}
    end
    -- The copied Source can internally fall back to page_buffer after a native
    -- draw failure while its kind remains "mupdf". Keep the processed screen
    -- image out of that boundary: a failed original must restore the whole page.
    local source_request={}
    for key,value in pairs(request) do
        if key~='page_buffer' then source_request[key]=value end
    end
    local wrapped,cancelled
    local operation=self.source:open(generation,source_request,{
        on_ready=function(raw)
            if cancelled then raw:close();return end
            wrapped=setmetatable({raw=raw,lut=lut,applier=self.applier,budget=math.floor(w*h*1.5)},Handle)
            if callbacks.on_ready then callbacks.on_ready(wrapped) else wrapped:close() end
        end,
        on_error=callbacks.on_error,
    })
    return {cancel=function()
        if cancelled then return end
        cancelled=true
        if wrapped then wrapped:close() end
        if operation and operation.cancel then operation:cancel() end
    end}
end

return Rendering
