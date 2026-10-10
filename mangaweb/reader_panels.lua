local Session=require('mangaweb.panel_session')
local Rendering=require('mangaweb.panel_rendering')
local Detector=require('mangaweb.panel_detector')
local Presets=require('mangaweb.filter_presets')
local Panels={}
Panels.__index=Panels

function Panels:new(options)
    return setmetatable({reader=assert(options.reader),ui=assert(options.ui),
        source=options.source,detector=options.detector or Detector,
        preferences=options.preferences,schedule=options.schedule,token=0},self)
end

function Panels:values()
    if self.preferences then return self.preferences() end
    return self.reader:panel_settings_snapshot()
end
function Panels:_direction(config)
    return config.order=='follow' and (self.reader.reader_settings.direction=='rtl' and 'manga' or 'normal')
        or config.order
end

function Panels:_detach()
    if type(self.ui.detach_panel)~='function' then return true end
    local ok,result=pcall(self.ui.detach_panel,self.ui)
    return ok and result~=false
end

function Panels:before_page()
    if not self:_detach() then return false end
    self.token=self.token+1
    if self.session then self.session:close();self.session=nil end
    self.original=nil
    return true
end

function Panels:exit(restore)
    local original=self.original
    if not self:before_page() then return false end
    self.continuing,self.pending=false,nil
    if restore and original and not self.reader.closed then
        self.reader.position_detail=original
        if self.ui.restore_panel_page then self.ui:restore_panel_page() end
    end
    return true
end

function Panels:close() return self:exit(false) end

function Panels:enter(desired)
    local config=self:values()
    if not config or config.enabled~=true then return false,'panel_disabled' end
    local context,reason=self.reader:panel_context()
    if not context then return false,reason end
    if not self:before_page() then return false,'panel_display_busy' end
    self.original=Presets.copy(context.position)
    self.continuing=true;self.pending=nil
    local token,generation,entry=self.token,context.generation,context.entry
    local function valid()
        return token==self.token and not self.reader.closed and self.reader.generation==generation
            and self.reader.position==entry.index and self.reader.target==entry.index
            and self.reader.entries[entry.index]==entry
    end
    self.source=self.source or Rendering:new{settings=function() return self.reader:settings_snapshot() end}
    local schedule=self.schedule
    if not schedule and self.reader.scheduler and self.reader.scheduler.scheduleIn then
        schedule=function(fn) self.reader.scheduler:scheduleIn(0,fn) end
    end
    self.session=Session:new{source=self.source,detector=self.detector,schedule=schedule,
        screen_width=context.width,screen_height=context.height}
    local direction=self:_direction(config)
    return self.session:start({generation=generation,page_path=context.raw_path,page_buffer=context.buffer,
        engine='default',direction=direction,desired=desired or 'first',view=config.view,
        rotation=config.rotation,show_adjacent=config.show_adjacent,margin_percent=config.margin_percent}, {
        on_panel=function(buffer,panel,index,count,render)
            if not valid() or not self.ui.show_panel then return false end
            local current=self:values()
            return self.ui:show_panel(buffer,{page_index=entry.index,total=#self.reader.context.pages,
                panel_id=panel.id,index=index,count=count,view=render.view or 'context',
                rotation=render.rotation,zoom=render.zoom,pan_x=render.pan_x,pan_y=render.pan_y,
                navigation=current.navigation,reverse_navigation=current.reverse_navigation})==true
        end,
        on_boundary=function(delta) if valid() then self:_boundary(delta) end end,
        on_fallback=function()
            if not valid() then return true end
            if not self:_detach() then return false end
            if self.ui.restore_panel_page then self.ui:restore_panel_page() end
            return true
        end,
    })
end

function Panels:_boundary(delta)
    local reader=self.reader
    local index=(reader.position or 1)+delta
    if index<1 or index>#reader.context.pages then return true end
    if not self:before_page() then return true end
    self.pending=delta>0 and 'first' or 'last'
    return reader:_request(index,'whole')
end

function Panels:page_displayed()
    if self.continuing and self.pending then return self:enter(self.pending) end
end

function Panels:move(delta)
    if not self.continuing then return false end
    if self.pending then return true end
    local session=self.session
    if session and session:is_active() then
        if session.render_options.view~='free' then session:move(delta) end
    elseif session and session.callbacks and session.handle==nil then
        -- Pending source callback: consume repeated input without launching more work.
        return true
    else
        self:_boundary(delta)
    end
    return true
end

function Panels:configure(values,commit,rollback)
    if not self.session or not self.session:is_active() then
        if commit then return commit() end
        return false,'panel_inactive'
    end
    local session=self.session
    local previous_direction=session.direction
    local accepted,reason=session:configure(values,commit,rollback)
    if accepted and values.order then
        local current=session:set_direction(self:_direction(self:values()))
        if current and session.callbacks.on_panel(current.buffer,current.panel,current.index,current.count,session.render_options) then
            return true
        end
        if rollback then rollback() end
        current=session:set_direction(previous_direction)
        if current then session.callbacks.on_panel(current.buffer,current.panel,current.index,current.count,session.render_options) end
        return false,'panel_settings_failed'
    end
    return accepted,reason
end
function Panels:pan(dx,dy) return self.session and self.session:pan(dx,dy) or false end
function Panels:zoom(factor) return self.session and self.session:zoom(factor) or false end
return Panels
