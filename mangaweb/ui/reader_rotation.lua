-- Manual device rotation copied from WebDAVManga's public-event flow.
local Rotation={};Rotation.__index=Rotation
local ANGLES={0,90,180,270}
function Rotation:new(options)
    return setmetatable({adapter=assert(options.adapter),reader=assert(options.reader)},self)
end
function Rotation:active()
    return not self.closed and self.adapter.reader==self.reader and not self.reader.closed and self.adapter.reader_widget~=nil
end
function Rotation:_supported()
    local a=self.adapter
    return a.screen and type(a.screen.getRotationMode)=='function'
        and a.ui_manager and type(a.ui_manager.broadcastEvent)=='function'
        and type(a.ui_manager.onRotation)=='function'
end
function Rotation:_host(mode)
    local a=self.adapter
    local Event=require('ui/event')
    a.root_size_dirty=true
    a.ui_manager:broadcastEvent(Event:new('SetRotationMode',mode))
    assert(a.screen:getRotationMode()==mode,'rotation_not_applied')
    a.ui_manager:onRotation()
end
function Rotation:_retire(operation,rollback)
    if self.operation~=operation then return end
    self.operation=nil
    local manager=self.adapter.ui_manager
    if operation.timer and manager.unschedule then pcall(manager.unschedule,manager,operation.timer)end
    if operation.handle and operation.handle.cancel then pcall(operation.handle.cancel,operation.handle)end
    if rollback and self.adapter.screen:getRotationMode()==operation.mode then
        pcall(self._host,self,operation.previous)
    end
end
function Rotation:close()
    self.closed=true
    if self.operation then self:_retire(self.operation,true)end
end
function Rotation:rotate(degrees)
    if degrees~=0 and degrees~=90 and degrees~=180 and degrees~=270 then return false end
    if not self:active() or not self:_supported() or self.operation then return false end
    local a,r=self.adapter,self.reader
    local previous=a.screen:getRotationMode()
    if previous==degrees/90 then return true end
    local entry=r.position and r.entries[r.position]
    if not entry or not entry.ready or r.target~=r.position or r.chapter_request then return false end
    local operation={previous=previous,mode=degrees/90,generation=r.generation,index=r.position,page=a.reader_widget}
    local panels=r.panels
    if panels and panels.continuing then
        operation.panel_index=panels.session and panels.session.index or 'first'
        if not panels:exit(true)then return false end
    end
    self.operation=operation
    local function current()
        return self.operation==operation and self:active() and r.generation==operation.generation
            and r.position==operation.index and r.target==operation.index
    end
    local function restore_panel()
        if operation.panel_index and self:active() and panels and r.generation==operation.generation
            and r.position==operation.index and r.target==operation.index then panels:enter(operation.panel_index)end
    end
    local function failed()
        if self.operation~=operation then return false end
        self:_retire(operation,true)
        restore_panel()
        if self:active()then self:show('设备方向调整失败，已保留当前页。')end
        return false
    end
    local changed=pcall(self._host,self,operation.mode)
    if not changed then return failed()end
    self:show('正在按新方向准备当前页…')
    local manager=a.ui_manager
    operation.timer=function()if self.operation==operation then failed()end end
    if manager.scheduleIn then pcall(manager.scheduleIn,manager,25,operation.timer)end
    local ok,handle=pcall(r.prepare_viewport,r,a.screen:getWidth(),a.screen:getHeight(),function(path,index,total,options)
        if not current() or a.screen:getRotationMode()~=operation.mode then return false end
        return a:_replace_reader_viewport(path,index,total,options)
    end,{on_success=function()
        if not current()then return end
        self:_retire(operation,false)
        restore_panel()
        self:show()
    end,on_error=failed})
    if not ok or handle==false then return failed()end
    if self.operation==operation then operation.handle=handle end
    return true
end
function Rotation:show(status)
    if not self:active()then return false end
    local a=self.adapter
    self.view_epoch=(self.view_epoch or 0)+1
    local epoch=self.view_epoch
    local panel
    local function guard(callback)
        return function(...)
            if epoch~=self.view_epoch or not self:active() or not panel or panel.closed
                or a.reader_controls~=panel then return false end
            local ok,result=pcall(callback,...)
            return ok and result~=false
        end
    end
    local mode=self:_supported() and a.screen:getRotationMode() or nil
    local items={}
    for _,angle in ipairs(ANGLES)do
        local degrees=angle
        items[#items+1]={text=degrees..'°',enabled=mode~=nil and self.operation==nil,callback=guard(function()
            return self:rotate(degrees)
        end)}
    end
    local function back()
        if self.operation then return false end
        return a:_show_reader_controls('root')
    end
    local function reading()
        if self.operation then return false end
        return a:_close_reader_controls()
    end
    local shown=a:_show_reader_panel({title='设备旋转',modal=true,rows={
        {kind='info',text=mode and ('当前方向：%d°；退出阅读后保留此方向。'):format(mode*90) or '当前设备未提供旋转接口。'},
        {kind='actions',items={items[1],items[2]}},{kind='actions',items={items[3],items[4]}},
    },status=status,navigation={{text='← 返回设置',callback=guard(back)},{text='返回阅读',callback=guard(reading)}},
        on_back=guard(back),on_close=guard(reading)})
    panel=a.reader_controls
    return shown
end
return Rotation
