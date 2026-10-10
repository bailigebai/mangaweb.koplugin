local Models=require('mangaweb.models')
local Base=require('mangaweb.sources.base')
local Api={}
Api.__index=Api
local MANGA='https://manga.bilibili.com'
local PASSPORT='https://passport.bilibili.com'
local ENDPOINTS={ClassPage='/comic.v1.Comic/ClassPage',ComicDetail='/comic.v1.Comic/ComicDetail',
    Search='/comic.v1.Comic/Search',GetImageIndex='/comic.v1.Comic/GetImageIndex',
    ImageToken='/comic.v1.Comic/ImageToken',GetNewbieInfo='/user.v1.User/GetNewbieInfo'}
local function encode(value)
    return tostring(value):gsub('([^%w%-_%.~])',function(c) return ('%%%02X'):format(c:byte()) end)
end
function Api:new(options)
    return setmetatable({http=assert(options.http),json=options.json,
        logger=options.logger,max_bytes=8*1024*1024},self)
end
function Api:_request(url,method,fields,cookie,parser,callbacks,decode_body)
    callbacks=callbacks or {}
    local finished,cancelled=false,false
    local function error(code,status)
        if finished or cancelled then return end
        finished=true
        if self.logger and type(self.logger.warn)=='function' then
            pcall(self.logger.warn,'MangaWeb Bilibili','request',code)
        end
        if callbacks.on_error then callbacks.on_error(Models.error({code=code,status=status},'bilibili','request')) end
    end
    if not self.json then
        local ok,json=pcall(require,'rapidjson')
        if not ok then error('http_unavailable');return {cancel=function() end} end
        self.json=json
    end
    if cookie and (type(cookie)~='string' or #cookie>16384 or cookie:find('[%c]')) then
        error('auth_required');return {cancel=function() end}
    end
    local headers={['User-Agent']='Mozilla/5.0',['Referer']=MANGA..'/',Origin=MANGA}
    if cookie and cookie~='' then headers.Cookie=cookie end
    local body
    if method=='POST' then
        local ok,value=pcall(self.json.encode,fields or {})
        if not ok or type(value)~='string' then error('parse_error');return {cancel=function() end} end
        body=value;headers['Content-Type']='application/json'
    end
    local ok,request=pcall(self.http.request,self.http,{url=url,method=method,headers=headers,body=body,
        site_id='bilibili',stage='request',follow_redirects=false,no_replay=true,ui_nonblocking=true}, {
        on_success=function(text,meta)
            if finished or cancelled then return end
            if type(text)~='string' or #text>self.max_bytes then error('response_too_large');return end
            local status=meta and tonumber(meta.status)
            if not status or status<200 or status>=300 then error('http_error',status);return end
            local decoded,data=pcall(decode_body or self.json.decode,text)
            if not decoded or type(data)~='table' or type(data.code)~='number' then error('parse_error');return end
            if data.code~=0 then error(data.code==-101 and 'auth_required' or 'api_error');return end
            local parsed,result=pcall(parser,data.data,meta)
            if not parsed or not result then error('parse_error');return end
            finished=true
            if callbacks.on_success then callbacks.on_success(result) end
        end,
        on_error=function(raw)
            local code=type(raw)=='table' and raw.code or 'transport_error'
            error(code=='ui_nonblocking_unavailable' and 'http_unavailable' or code)
        end,
    })
    if not ok then error('transport_error') end
    return {cancel=function()
        if cancelled then return end
        cancelled=true
        if ok and request and request.cancel then pcall(request.cancel,request) end
    end}
end
-- The official homepage embeds public catalogue data. It does not require a
-- signed comic RPC or an account cookie, and must never be parsed as JavaScript.
function Api:homepage(callbacks)
    return self:_request(MANGA..'/','GET',nil,nil,function(data)
        return type(data)=='table' and data or nil
    end,callbacks,function(body)
        local fragment
        for opening,content in body:gmatch('(<script[^>]*>)(.-)</script>') do
            if Base.attr(opening,'id')=='vike_pageContext' then
                if fragment or Base.attr(opening,'type')~='application/json' then return nil end
                fragment=content
            end
        end
        if not fragment then return nil end
        local context=self.json.decode(fragment)
        if type(context)~='table' or type(context.data)~='table' then return nil end
        return {code=0,data=context.data}
    end)
end
function Api:generate_qr(callbacks)
    return self:_request(PASSPORT..'/x/passport-login/web/qrcode/generate?source=main_web&go_url='..encode(MANGA..'/'),
        'GET',nil,nil,function(data)
            if type(data)~='table' or type(data.url)~='string' or #data.url>2953 or data.url:find('[%c]')
                or not (data.url:match('^https://passport%.bilibili%.com/')
                    or data.url:match('^https://account%.bilibili%.com/'))
                or type(data.qrcode_key)~='string' or #data.qrcode_key>128
                or not data.qrcode_key:match('^[%w_%-]+$') then return nil end
            return {url=data.url,key=data.qrcode_key}
        end,callbacks)
end
function Api:poll_qr(key,callbacks)
    return self:_request(PASSPORT..'/x/passport-login/web/qrcode/poll?qrcode_key='..encode(key)..'&source=main_web',
        'GET',nil,nil,function(data,meta)
            if type(data)~='table' or (data.code~=0 and data.code~=86101 and data.code~=86090 and data.code~=86038) then return nil end
            return {code=data.code,headers=meta.headers,url=data.url}
        end,callbacks)
end
function Api:verify_account(cookie,callbacks)
    return self:_request('https://api.bilibili.com/x/web-interface/nav','GET',nil,cookie,function(data)
        if type(data)~='table' or data.isLogin~=true or type(data.mid)~='number'
            or data.mid<1 or data.mid~=math.floor(data.mid) or type(data.uname)~='string'
            or #data.uname>256 or data.uname:find('[%c]') then return nil end
        return {uid=tostring(data.mid),name=data.uname}
    end,callbacks)
end
function Api:manga(name,fields,cookie,callbacks)
    local endpoint=ENDPOINTS[name]
    if not endpoint then
        if callbacks and callbacks.on_error then callbacks.on_error(Models.error({code='api_error'},'bilibili','request')) end
        return {cancel=function() end}
    end
    return self:_request(MANGA..'/twirp'..endpoint..'?device=pc&platform=web&nov=27','POST',fields,cookie,
        function(data) return type(data)=='table' and data or nil end,callbacks)
end
function Api:verify_manga(cookie,callbacks) return self:manga('GetNewbieInfo',{},cookie,callbacks) end
return Api
