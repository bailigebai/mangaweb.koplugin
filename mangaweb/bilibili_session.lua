local copy=require('mangaweb.filter_presets').copy
local Identity=require('mangaweb.image_identity')
local Session={}
Session.__index=Session
local KEY='bilibili_account'
local HOSTS={['api.bilibili.com']=true,['manga.bilibili.com']=true,['passport.bilibili.com']=true}
local COOKIES={SESSDATA=true,DedeUserID=true,DedeUserID__ckMd5=true,bili_jct=true}
local MONTH={Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
local function expired(attributes)
    local age=attributes:lower():match('max%-age%s*=%s*(-?%d+)')
    if age then return tonumber(age)<=0 end
    local date=attributes:match('[Ee][Xx][Pp][Ii][Rr][Ee][Ss]%s*=%s*([^;]+)')
    if not date then return false end
    local d,month,y,h,m,s=date:match(',%s*(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+GMT')
    if not y or not MONTH[month] then return false end
    return ('%04d%02d%02d%02d%02d%02d'):format(tonumber(y),MONTH[month],tonumber(d),tonumber(h),tonumber(m),tonumber(s))
        <=os.date('!%Y%m%d%H%M%S')
end
local function parse(cookie)
    if type(cookie)~='string' or #cookie>16384 or cookie:find('[%c]') then return nil end
    local values={}
    for name,value in cookie:gmatch('([%w_]+)%s*=%s*([^;%s]+)') do
        if COOKIES[name] then
            if values[name] or value:find('[,]') then return nil end
            values[name]=value
        end
    end
    if not values.SESSDATA or not values.DedeUserID or not values.DedeUserID:match('^%d+$') then return nil end
    local names={};for name in pairs(values) do names[#names+1]=name end;table.sort(names)
    local entries={};for _,name in ipairs(names) do entries[#entries+1]=name..'='..values[name] end
    return table.concat(entries,'; '),values.DedeUserID
end
local function valid_account(account)
    return type(account)=='table' and type(account.uid)=='string' and account.uid:match('^%d+$')
        and #account.uid<=32 and type(account.name)=='string' and #account.name<=256
        and not account.name:find('[%c]')
end
function Session:new(options)
    local self=setmetatable({settings=assert(options.settings),sha256=options.sha256},Session)
    local raw=self.settings:read(KEY)
    if type(raw)=='table' and valid_account(raw.account) then
        local cookie,uid=parse(raw.cookie)
        if cookie and uid==raw.account.uid then self.record={account=copy(raw.account),cookie=cookie} end
    end
    return self
end
function Session:candidate(headers)
    local lines={}
    local function collect(value)
        if type(value)=='string' then lines[#lines+1]=value
        elseif type(value)=='table' then for _,item in ipairs(value) do collect(item) end end
    end
    for name,value in pairs(headers or {}) do if tostring(name):lower()=='set-cookie' then collect(value) end end
    local values={}
    for _,line in ipairs(lines) do
        if #line>16384 or line:find('[%c]') then return nil,'invalid_cookie' end
        -- Split combined headers only where a new name=value begins; the
        -- comma in an RFC Expires date is retained inside its cookie.
        line=line:gsub(',%s*([%w_%-]+)%s*=','\n%1=')
        for item in (line..'\n'):gmatch('(.-)\n') do
            local name,value,attributes=item:match('^%s*([%w_]+)%s*=%s*([^;]*)(.*)$')
            if COOKIES[name] then
                local domain=attributes:lower():match('domain%s*=%s*([^;%s]+)')
                if domain and domain~='.bilibili.com' and domain~='bilibili.com' and not HOSTS[domain] then
                    return nil,'invalid_cookie'
                end
                if expired(attributes) or value=='' then values[name]=nil else values[name]=value end
            end
        end
    end
    local entries={};for name,value in pairs(values) do entries[#entries+1]=name..'='..value end
    local cookie=parse(table.concat(entries,'; '))
    if not cookie then return nil,'auth_required' end
    return cookie
end
function Session:headers(url,candidate)
    local authority=type(url)=='string' and url:match('^https://([^/?:#]+)[/?#]?')
    local host=authority and authority:lower()
    if not host or not HOSTS[host] or url:find('[%c]') or url:match('^https://[^/]+:') then
        return {},'credential_destination_rejected'
    end
    local cookie=candidate or self.record and self.record.cookie
    if not cookie then return {} end
    local valid=parse(cookie)
    if not valid then return {},'invalid_cookie' end
    return {Cookie=valid}
end
function Session:account() return self.record and copy(self.record.account) or nil end
function Session:scope()
    if not self.record then return 'public' end
    return Identity.scope({Cookie=self.record.cookie},self.sha256)
end
function Session:_persist(record,guard)
    local previous=self.record
    local old=self.settings:read(KEY)
    local ok,saved=pcall(function()
        if guard and not guard() then return false end
        if self.settings:write(KEY,copy(record))==false then return false end
        return self.settings:flush()~=false and (not guard or guard())
    end)
    if not ok or not saved then
        pcall(self.settings.write,self.settings,KEY,old);pcall(self.settings.flush,self.settings)
        self.record=previous;return false,'account_save_failed'
    end
    self.record=record
    return true
end
function Session:save(account,cookie,guard)
    local valid,uid=parse(cookie)
    if not valid_account(account) or not valid or uid~=account.uid then return false,'invalid_account' end
    return self:_persist({account={uid=account.uid,name=account.name},cookie=valid},guard)
end
function Session:clear() return self:_persist(nil) end
return Session
