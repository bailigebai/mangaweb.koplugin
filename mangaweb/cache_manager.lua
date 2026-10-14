local Manager={};Manager.__index=Manager
local MB=1048576
function Manager:new(options)
    options=options or {}
    local object=setmetatable({caches=options.caches or {},settings=assert(options.settings),
        scheduler=options.scheduler,clock=options.clock or os.time,batch_size=options.batch_size or 20},self)
    for _,cache in ipairs(object.caches)do cache.coordinator=object end
    return object
end
function Manager:policy() return self.settings:cache_policy() end
function Manager:stats()
    local result={total_bytes=0,protected_bytes=0,pages_bytes=0,covers_bytes=0,catalogues_bytes=0,entries={}}
    local seen={}
    for _,cache in ipairs(self.caches)do
        local ok,entries=pcall(cache.maintenance_entries,cache)
        if not ok then result.scan_failed=true;entries={} end
        for _,entry in ipairs(entries)do
            if not seen[entry.path] then
                seen[entry.path]=true;entry.cache=cache
                local size=math.max(0,tonumber(entry.size)or 0)
                result.total_bytes=result.total_bytes+size
                local key=(cache.directory or 'pages')..'_bytes'
                result[key]=(result[key]or 0)+size
                if entry.protected then result.protected_bytes=result.protected_bytes+size end
                result.entries[#result.entries+1]=entry
            end
        end
    end
    result.last_checked=self.last_checked;result.reason=self.last_reason
    return result
end
function Manager:_unschedule(callback)
    if callback and self.scheduler and self.scheduler.unschedule then pcall(self.scheduler.unschedule,self.scheduler,callback) end
end
function Manager:_later(delay,callback)
    if not self.scheduler or not self.scheduler.scheduleIn then return false end
    local ok,result=pcall(self.scheduler.scheduleIn,self.scheduler,delay,callback)
    return ok and result~=false
end
function Manager:_schedule(delay)
    if not self.active or self.timer then return end
    local callback
    callback=function()
        if self.timer~=callback or not self.active then return end
        self.timer=nil;self:check(false)
    end
    self.timer=callback
    if not self:_later(delay,callback) then self.timer=nil end
end
function Manager:request_check()
    if self.active and not self.operation and (not self.last_checked
        or self.clock()-self.last_checked>=self:policy().interval_minutes*60) then self:_schedule(0.05) end
    return true
end
function Manager:start()
    if self.active then return end
    self.active=true;self.closed=false;self.last_checked=nil;self:_schedule(0.05)
end
function Manager:stop()
    self.active=false;self.closed=true
    self:_unschedule(self.timer);self.timer=nil
    if self.operation then self:_unschedule(self.operation.step);self.operation=nil end
end
function Manager:configure(policy)
    local saved,reason=self.settings:save_cache_policy(policy)
    if not saved then return false,reason end
    local active=self.active
    self:stop();self.closed=false
    if active then self:start() end
    return true
end
function Manager:check(force,done)
    if self.closed then return false,'stopped' end
    if self.operation then
        if done then self.operation.callbacks[#self.operation.callbacks+1]=done end
        return true
    end
    local policy=self:policy()
    if not force and self.last_checked and self.clock()-self.last_checked<policy.interval_minutes*60 then
        self:_schedule(policy.interval_minutes*60-(self.clock()-self.last_checked));return true
    end
    local stats=self:stats()
    self.last_checked=self.clock()
    local operation={callbacks=done and {done}or {},entries=stats.entries,index=1,
        target=policy.lower_mb*MB,total=stats.total_bytes,freed=0,failed=false}
    self.operation=operation
    local function finish(reason)
        if self.operation~=operation then return end
        self.operation=nil;self.last_reason=reason
        local result=self:stats()
        result.freed_bytes=operation.freed;result.reason=reason
        self:_schedule(policy.interval_minutes*60)
        for _,callback in ipairs(operation.callbacks)do pcall(callback,result) end
    end
    if stats.scan_failed then finish('scan_failed');return false,'scan_failed' end
    if stats.total_bytes<=policy.upper_mb*MB then finish('below_upper');return true end
    table.sort(operation.entries,function(a,b)
        local at,bt=a.atime or a.mtime or 0,b.atime or b.mtime or 0
        if at~=bt then return at<bt end
        return a.path<b.path
    end)
    operation.step=function()
        if self.operation~=operation or self.closed then return end
        for _=1,self.batch_size do
            local entry=operation.entries[operation.index]
            if not entry or operation.total<=operation.target then
                local current=self:stats()
                local reason=current.total_bytes<=operation.target and 'cleaned'
                    or operation.failed and 'cleanup_failed' or 'protected_limit'
                return finish(reason)
            end
            operation.index=operation.index+1
            if not entry.protected then
                local ok,removed,reason=pcall(entry.cache.remove_entry,entry.cache,entry)
                if ok and removed then
                    operation.total=operation.total-entry.size;operation.freed=operation.freed+entry.size
                elseif not ok or reason=='remove_failed' then operation.failed=true end
            end
        end
        if not self:_later(0.01,operation.step) then finish('scheduler_unavailable') end
    end
    if not self:_later(0.01,operation.step) then finish('scheduler_unavailable');return false,'scheduler_unavailable' end
    return true
end
return Manager
