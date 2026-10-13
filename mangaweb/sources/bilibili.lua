local Models = require("mangaweb.models")
local Bilibili = {}
Bilibili.__index = Bilibili
Bilibili.id = "bilibili"
Bilibili.name = "哔哩哔哩漫画"
Bilibili.origin = "https://manga.bilibili.com"
local NOTICE = "章节目录已支持；正文与阅读预览尚未接通。"

local function id(value)
    if type(value)=="number" and (value<1 or value>=9007199254740992 or value~=math.floor(value)) then return nil end
    if type(value)~="string" and type(value)~="number" then return nil end
    value=tostring(value)
    return #value<=16 and value:match("^[1-9]%d*$") and value or nil
end

local function text(value,limit,multiline)
    if type(value)~="string" or #value>limit then return nil end
    local checked=multiline and value:gsub("[\r\n\t]","") or value
    return not checked:find("[%c]") and value or nil
end

local function cover(value)
    value=text(value,2048)
    if not value then return nil end
    value=value:gsub("^//","https://")
    local extension=value:match("%.([%w]+)$")
    if not value:match("^https://i[012]%.hdslb%.com/bfs/manga%-static/[%w%-%._/]+$")
        or not ({jpg=true,jpeg=true,png=true,webp=true})[extension] then return nil end
    return value.."@240w_360h_1c.jpg"
end

local function array(value,limit)
    if type(value)~="table" or #value>limit then return false end
    local count=0
    for key in pairs(value) do
        if type(key)~="number" or key~=math.floor(key) or key<1 or key>#value then return false end
        count=count+1
    end
    return count==#value
end

function Bilibili:new(options)
    options=options or {}
    local instance=setmetatable({api=assert(options.api),account_auth=options.account_auth,
        session=options.session or options.account_auth and options.account_auth.session,
        page_size=options.page_size or 16,clock=options.clock or os.time},self)
    if instance.session then
        -- The existing catalogue/detail cache hashes this value. Credentials
        -- stay local and are never attached to cover/body CDN requests.
        instance.auth={active_cookie=function()
            local headers=instance.session:headers(instance.origin..'/')
            return headers.Cookie or ''
        end}
    end
    return instance
end

function Bilibili:meta() return {id=self.id,name=self.name,origin=self.origin} end
function Bilibili:capabilities()
    return {categories=false,tags=false,search=false,chapters=true,pages=false,login=false,
        qr_login=self.account_auth~=nil}
end
function Bilibili:image_headers()
    return {Referer=self.origin.."/",["User-Agent"]="Mozilla/5.0"}
end

function Bilibili:_error(callbacks,code,stage)
    if callbacks and callbacks.on_error then callbacks.on_error(Models.error({code=code},self.id,stage)) end
    return {cancel=function() end}
end

function Bilibili:_parse(data)
    local values=type(data)=="table" and type(data.latestWorks)=="table" and data.latestWorks.list
    if not array(values,250) then return nil end
    local details,order,seen={}, {}, {}
    for _,raw in ipairs(values) do
        if type(raw)~="table" then return nil end
        local comic_id,title,url=id(raw.comic_id),text(raw.title,512),cover(raw.vertical_cover)
        if not comic_id or not title or title=="" or not url or seen[comic_id] then return nil end
        local authors={}
        if not array(raw.author,20) then return nil end
        for _,author in ipairs(raw.author) do
            author=text(author,256)
            if not author then return nil end
            authors[#authors+1]=author
        end
        local description=text(raw.comic_introduction or "",16384,true)
        if not description then return nil end
        local card=Models.card{site_id=self.id,comic_id=comic_id,title=title,
            author=table.concat(authors," / "),cover_url=url,cover_headers=self:image_headers(url),
            detail_url=self.origin.."/detail/mc"..comic_id,page_count=0}
        details[comic_id]=Models.detail{card=card,description=NOTICE.."\n\n"..description,chapters={}}
        order[#order+1]=comic_id;seen[comic_id]=true
    end
    return {details=details,order=order,time=self.clock()}
end

function Bilibili:_load(callbacks)
    callbacks=callbacks or {}
    return self.api:homepage{on_success=function(data)
        local catalogue=self:_parse(data)
        if not catalogue then return self:_error(callbacks,"parse_error","list") end
        self.catalogue=catalogue
        if callbacks.on_success then callbacks.on_success(catalogue) end
    end,on_error=callbacks.on_error}
end

function Bilibili:list(options,callbacks)
    options,callbacks=options or {},callbacks or {}
    for _,field in ipairs{"query","category","tag"} do
        if options[field]~=nil and tostring(options[field])~="" then
            return self:_error(callbacks,"unsupported_filter","list")
        end
    end
    local page=tonumber(options.page) or 1
    if page~=page or page==math.huge or page==-math.huge then page=1 end
    page=math.max(1,math.floor(page))
    local function publish(catalogue)
        local total=math.max(1,math.ceil(#catalogue.order/self.page_size))
        local selected=math.min(page,total)
        local cards={}
        for index=(selected-1)*self.page_size+1,math.min(selected*self.page_size,#catalogue.order) do
            cards[#cards+1]=Models.card(catalogue.details[catalogue.order[index]].card)
        end
        if callbacks.on_success then callbacks.on_success{cards=cards,page=selected,total_pages=total} end
    end
    if page>1 and not options.refresh and self.catalogue and self.clock()-self.catalogue.time<60 then
        publish(self.catalogue);return {cancel=function() end}
    end
    return self:_load{on_success=publish,on_error=callbacks.on_error}
end

function Bilibili:_parse_detail(data,comic_id)
    local raw=type(data)=='table' and data.seasonData
    if type(raw)~='table' or id(raw.id)~=comic_id or data.detailCode~=0
        or not array(raw.ep_list,5000) or not array(raw.author_name,20) then return nil end
    local title,url,description=text(raw.title,512),cover(raw.vertical_cover),text(raw.evaluate or '',16384,true)
    if not title or title=='' or not url or not description then return nil end
    local authors,chapters,seen={}, {}, {}
    for _,author in ipairs(raw.author_name) do
        author=text(author,256)
        if not author then return nil end
        authors[#authors+1]=author:gsub('^作者:%s*','')
    end
    for _,ep in ipairs(raw.ep_list) do
        if type(ep)~='table' then return nil end
        local episode,short,name=id(ep.id),text(ep.short_title,256),text(ep.title,512)
        local order,count=tonumber(ep.ord),tonumber(ep.image_count)
        if not episode or seen[episode] or not short or not name or type(ep.is_locked)~='boolean'
            or not order or order~=order or math.abs(order)==math.huge or order<0
            or not count or count~=math.floor(count) or count<0 or count>10000 then return nil end
        chapters[#chapters+1]={id=episode,title=short..' '..name..(ep.is_locked and '（未解锁）' or ''),
            page_count=count,order=order}
        seen[episode]=true
    end
    table.sort(chapters,function(a,b)
        return a.order<b.order or a.order==b.order and tonumber(a.id)<tonumber(b.id)
    end)
    return Models.detail{card=Models.card{site_id=self.id,comic_id=comic_id,title=title,
        author=table.concat(authors,' / '),cover_url=url,cover_headers=self:image_headers(),
        detail_url=self.origin..'/detail/mc'..comic_id,
        page_count=chapters[1] and chapters[1].page_count or 0},
        description=NOTICE..'\n\n'..description,chapters=chapters}
end

function Bilibili:detail(comic_id,callbacks)
    comic_id=id(comic_id)
    if not comic_id then return self:_error(callbacks,'parse_error','detail') end
    callbacks=callbacks or {}
    local url=self.origin..'/m/detail/mc'..comic_id
    local headers,scope={},self.session and self.session:scope()
    if self.session then
        local reason
        headers,reason=self.session:headers(url)
        if reason then return self:_error(callbacks,'auth_required','detail') end
    end
    return self.api:mobile_detail(comic_id,headers.Cookie,{
        on_success=function(data)
            if self.session and self.session:scope()~=scope then
                return self:_error(callbacks,'auth_required','detail')
            end
            local detail=self:_parse_detail(data,comic_id)
            if not detail then return self:_error(callbacks,'parse_error','detail') end
            if callbacks.on_success then callbacks.on_success(detail) end
        end,on_error=callbacks.on_error})
end
return Bilibili
