local Auth={}
Auth.__index=Auth
local LABEL={idle='未登录',generating='正在生成二维码',waiting_scan='请使用哔哩哔哩手机端扫码',
    waiting_confirm='已扫码，请在手机上确认',verifying='正在验证账号和漫画服务',connected='已登录',
    expired='二维码等待已结束，请重新生成',error='登录或验证失败，请重试'}
local function cancel(handle) if handle and handle.cancel then pcall(handle.cancel,handle) end end
local function default_scheduler()
    local manager=require('ui/uimanager')
    return {after=function(seconds,callback)
        manager:scheduleIn(seconds,callback)
        return {cancel=function() manager:unschedule(callback) end}
    end}
end
function Auth:new(options)
    return setmetatable({api=assert(options.api),session=assert(options.session),
        scheduler=options.scheduler or default_scheduler(),logger=options.logger,
        on_account_changed=options.on_account_changed,generation=0,state='idle',verified=false},self)
end
function Auth:model()
    local account=self.session:account()
    return {state=self.state,status=account and self.state=='idle' and '已保存账号，尚待验证' or LABEL[self.state],
        account=account,verified=self.verified,
        qr_url=(self.state=='waiting_scan' or self.state=='waiting_confirm') and self.qr_url or nil}
end
function Auth:_emit(state)
    self.state=state
    local generation=self.generation
    if self.listener then pcall(self.listener,self:model()) end
    return generation==self.generation
end
function Auth:_stop()
    self.generation=self.generation+1;self.active=false
    local ticket=self.ticket;self.ticket=nil
    cancel(ticket and ticket.handle);cancel(self.poll_timer);cancel(self.deadline)
    self.poll_timer,self.deadline,self.qr_url,self.key=nil,nil,nil,nil
end
function Auth:cancel()
    self:_stop();self.listener=nil
    self.state=self.verified and self.session:account() and 'connected' or 'idle'
    return true
end
function Auth:_fail(state)
    self:_stop();self:_emit(state or 'error')
end
function Auth:_request(method,args,success)
    if not self.active then return end
    local generation=self.generation
    local ticket={};self.ticket=ticket
    local function valid() return self.active and self.generation==generation and self.ticket==ticket and not ticket.done end
    local callbacks={on_success=function(data)
        if not valid() then return end
        ticket.done=true;self.ticket=nil
        local ok=pcall(success,data,generation)
        if not ok and self.generation==generation then self:_fail() end
    end,on_error=function()
        if not valid() then return end
        ticket.done=true;self.ticket=nil;self:_fail()
    end}
    local params={};for _,value in ipairs(args or {}) do params[#params+1]=value end
    params[#params+1]=callbacks
    local ok,handle=pcall(self.api[method],self.api,unpack(params))
    ticket.handle=ok and handle or nil
    if generation~=self.generation then cancel(ticket.handle)
    elseif not ok and not ticket.done then self:_fail() end
end
function Auth:_schedule_poll()
    if not self.active then return end
    local generation=self.generation
    self.poll_timer=self.scheduler.after(2,function()
        self.poll_timer=nil
        if not self.active or generation~=self.generation then return end
        self:_request('poll_qr',{self.key},function(result)
            if result.code==86038 then self:_fail('expired')
            elseif result.code==86101 or result.code==86090 then
                if self:_emit(result.code==86101 and 'waiting_scan' or 'waiting_confirm') then self:_schedule_poll() end
            elseif result.code==0 then
                local cookie=self.session:candidate(result.headers)
                if not cookie then self:_fail();return end
                self:_verify(cookie,true)
            else self:_fail() end
        end)
    end)
end
function Auth:_verify(cookie,persist)
    if not self:_emit('verifying') then return end
    self:_request('verify_account',{cookie},function(account,generation)
        if not persist and (not self.session:account() or account.uid~=self.session:account().uid) then self:_fail();return end
        self:_request('verify_manga',{cookie},function()
            local valid=function() return self.active and generation==self.generation end
            if not valid() then return end
            if persist then
                local saved=self.session:save(account,cookie,valid)
                if not valid() then return end
                if not saved then self:_fail();return end
            end
            if not valid() then return end
            self.verified=true
            self:_stop()
            if persist and self.on_account_changed then pcall(self.on_account_changed) end
            self:_emit('connected')
        end)
    end)
end
function Auth:start(listener)
    self:_stop();self.listener=listener;self.active=true
    local generation=self.generation
    if not self:_emit('generating') then return false end
    self.deadline=self.scheduler.after(300,function()
        if self.active and generation==self.generation then self:_fail('expired') end
    end)
    self:_request('generate_qr',{},function(result)
        self.qr_url,self.key=result.url,result.key
        if self:_emit('waiting_scan') then self:_schedule_poll() end
    end)
    return true
end
function Auth:regenerate() return self:start(self.listener) end
function Auth:verify_saved(listener)
    self:_stop();self.listener=listener
    -- Rechecking this account invalidates its previous verification, while a
    -- failed candidate switch must keep the current account's verified state.
    self.verified=false
    local headers=self.session:headers('https://api.bilibili.com/x/web-interface/nav')
    if not headers.Cookie then self:_emit('idle');return false end
    self.active=true
    local generation=self.generation
    self.deadline=self.scheduler.after(300,function()
        if self.active and generation==self.generation then self:_fail() end
    end)
    self:_verify(headers.Cookie,false)
    return true
end
function Auth:logout(listener)
    self:_stop();self.listener=listener
    if not self.session:clear() then self:_emit('error');return false end
    self.verified=false
    if self.on_account_changed then pcall(self.on_account_changed) end
    self:_emit('idle');return true
end
return Auth
