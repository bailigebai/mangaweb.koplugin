local Models = require("mangaweb.models")
local Bilibili = {}
Bilibili.__index = Bilibili
Bilibili.id = "bilibili"
Bilibili.name = "哔哩哔哩漫画"
Bilibili.origin = "https://manga.bilibili.com"
local NOTICE = "当前可浏览官网新作、封面和简介，也可加入本地收藏。章节和阅读预览暂不可用。"

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
    return setmetatable({api=assert(options.api),account_auth=options.account_auth,
        page_size=options.page_size or 16,clock=options.clock or os.time},self)
end

function Bilibili:meta() return {id=self.id,name=self.name,origin=self.origin} end
function Bilibili:capabilities()
    return {categories=false,tags=false,search=false,pages=false,login=false,
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

function Bilibili:detail(comic_id,callbacks)
    comic_id=id(comic_id)
    if not comic_id then return self:_error(callbacks,"parse_error","detail") end
    callbacks=callbacks or {}
    local function publish(catalogue)
        local detail=catalogue.details[comic_id]
        if not detail then return self:_error(callbacks,"metadata_unavailable","detail") end
        if callbacks.on_success then callbacks.on_success(Models.detail{
            card=Models.card(detail.card),description=detail.description,chapters={}}) end
    end
    if self.catalogue then publish(self.catalogue);return {cancel=function() end} end
    return self:_load{on_success=publish,on_error=callbacks.on_error}
end
return Bilibili
