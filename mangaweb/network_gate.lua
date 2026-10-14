-- Share one bounded Wi-Fi connection attempt; cached reads never enter this gate.
local Gate={};Gate.__index=Gate
local function optional(name)
    local ok,value=pcall(require,name);return ok and value or nil
end
function Gate:new(options)
    options=options or {}
    local manager=options.manager or optional('ui/network/manager')
    local scheduler=options.scheduler or optional('ui/uimanager')
    if not manager or type(manager.isConnected)~='function'
        or type(manager.runWhenConnected)~='function' or not scheduler
        or type(scheduler.scheduleIn)~='function' then return nil end
    return setmetatable({manager=manager,scheduler=scheduler,clock=options.clock or os.time,
        timeout=options.timeout_seconds or 45},self)
end
function Gate:_connected()
    local ok,ready=pcall(self.manager.isConnected,self.manager)
    return ok and ready==true
end
function Gate:_start(item)
    if item.canceled then return end
    item.started=true
    local ok,child=pcall(item.start)
    if ok then item.child=child
    elseif item.on_error then pcall(item.on_error,{code='network_error'}) end
end
function Gate:_resolve(wait,error_value)
    if self.wait~=wait then return end
    self.wait=nil
    if self.scheduler.unschedule then pcall(self.scheduler.unschedule,self.scheduler,wait.poll) end
    for _,item in ipairs(wait.items)do
        if not item.canceled then
            if error_value then
                if item.on_error then pcall(item.on_error,error_value) end
            else self:_start(item) end
        end
    end
end
function Gate:run(start,on_error)
    local item={start=start,on_error=on_error}
    local owner=self
    local handle={cancel=function()
        if item.canceled then return end
        item.canceled=true
        if item.child and type(item.child.cancel)=='function' then pcall(item.child.cancel,item.child) end
        local wait=owner.wait
        if wait then
            for _,pending in ipairs(wait.items)do if not pending.canceled then return end end
            owner:_resolve(wait,{code='network_unavailable'})
        end
    end}
    if self:_connected() then self:_start(item);return handle end
    if self.wait then self.wait.items[#self.wait.items+1]=item;return handle end
    local wait={items={item},time=self.clock(),ticks=0}
    self.wait=wait
    wait.poll=function()
        if self.wait~=wait then return end
        wait.ticks=wait.ticks+1
        if self:_connected() then return self:_resolve(wait) end
        if self.clock()-wait.time>=self.timeout or wait.ticks>=self.timeout then
            return self:_resolve(wait,{code='network_unavailable'})
        end
        local ok,result=pcall(self.scheduler.scheduleIn,self.scheduler,1,wait.poll)
        if not ok or result==false then self:_resolve(wait,{code='network_unavailable'}) end
    end
    local scheduled,result=pcall(self.scheduler.scheduleIn,self.scheduler,1,wait.poll)
    if not scheduled or result==false then self:_resolve(wait,{code='network_unavailable'});return handle end
    local ok=pcall(self.manager.runWhenConnected,self.manager,function()
        if self.wait==wait and self:_connected() then self:_resolve(wait) end
    end)
    if not ok then self:_resolve(wait,{code='network_unavailable'}) end
    return handle
end
return Gate
