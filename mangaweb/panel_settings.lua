local copy=require('mangaweb.filter_presets').copy
local Settings={}
Settings.__index=Settings
local KEY='panel_preferences'
local DEFAULT={enabled=false,view='context',rotation=0,navigation='horizontal',
    reverse_navigation=false,order='follow',show_adjacent=true,margin_percent=0}
local VALID={view={context=true,cut=true,free=true},rotation={[0]=true,[90]=true,[180]=true,[270]=true},
    navigation={horizontal=true,vertical=true},order={follow=true,normal=true,manga=true},
    margin_percent={[0]=true,[2]=true,[5]=true,[10]=true}}
local function normalize(base,changes)
    if changes~=nil and type(changes)~='table' then return nil end
    local values=copy(base)
    for key,value in pairs(changes or {}) do
        if DEFAULT[key]==nil or (VALID[key] and not VALID[key][value])
            or (not VALID[key] and type(value)~='boolean') then return nil end
        values[key]=value
    end
    return values
end
local function comic_key(site,comic)
    site,comic=tostring(site or ''),tostring(comic or '')
    if site=='' or comic=='' or #site>64 or #comic>256 then return nil end
    return #site..':'..site..#comic..':'..comic
end
function Settings:new(options)
    local self=setmetatable({settings=assert(options.settings),sequence=0},Settings)
    local raw=self.settings:read(KEY,{})
    if type(raw)~='table' then raw={} end
    self.state={defaults=normalize(DEFAULT,raw.defaults) or copy(DEFAULT),books={}}
    for key,book in pairs(type(raw.books)=='table' and raw.books or {}) do
        if type(key)=='string' and type(book)=='table' then
            local values=normalize(DEFAULT,book.values)
            local used=tonumber(book.used)
            if values and used and used==used and used>=0 and used<math.huge then
                self.sequence=math.max(self.sequence,used)
                self.state.books[key]={values=values,used=used}
            end
        end
    end
    self:_trim(self.state)
    return self
end
function Settings:_trim(state)
    local count=0
    for _ in pairs(state.books) do count=count+1 end
    while count>64 do
        local oldest
        for key,book in pairs(state.books) do
            if not oldest or book.used<state.books[oldest].used
                or book.used==state.books[oldest].used and key<oldest then oldest=key end
        end
        state.books[oldest]=nil;count=count-1
    end
end
function Settings:for_comic(site,comic)
    local key=comic_key(site,comic)
    local book=key and self.state.books[key]
    if book then self.sequence=self.sequence+1;book.used=self.sequence end
    return copy(book and book.values or self.state.defaults)
end
function Settings:_persist(candidate)
    local previous=copy(self.state)
    local old=self.settings:read(KEY)
    local ok,result=pcall(function()
        if self.settings:write(KEY,copy(candidate))==false then return false end
        return self.settings:flush()~=false
    end)
    if not ok or result~=true then
        pcall(self.settings.write,self.settings,KEY,old)
        pcall(self.settings.flush,self.settings)
        self.state=previous
        return false,'panel_settings_failed'
    end
    self.state=candidate
    return true
end
function Settings:save(site,comic,changes,as_default)
    local key=comic_key(site,comic)
    if not key or type(changes)~='table' then return false,'invalid_panel_settings' end
    local values=normalize(self:for_comic(site,comic),changes)
    if not values then return false,'invalid_panel_settings' end
    local old=copy(self.state)
    local candidate=copy(self.state)
    self.sequence=self.sequence+1
    candidate.books[key]={values=values,used=self.sequence}
    if as_default then candidate.defaults=copy(values) end
    self:_trim(candidate)
    local saved,reason=self:_persist(candidate)
    if not saved then return false,reason end
    -- Session.configure may reject a rendered candidate after persistence.
    -- Restore the complete transaction, including a changed default and LRU.
    return true,nil,function() return self:_persist(old) end
end
return Settings
