local Base = require("mangaweb.sources.base")
local Models = require("mangaweb.models")

local Favorites = {}

local function class_has(tag, name)
    return (" " .. (Base.attr(tag, "class") or "") .. " "):find(" " .. name .. " ", 1, true) ~= nil
end

local function class_text(body, name)
    for tag, position in body:gmatch("(<[%w]+[^>]*>)()") do
        if class_has(tag, name) then return Base.text(body:sub(position):match("^(.-)</")) end
    end
    return ""
end

local function body_error(source, body, stage)
    local value, err = Base.guard_body(body, source.id, stage)
    if not value then return err end
    local lower = value:lower()
    if lower:find("/cdn-cgi/challenge-platform/", 1, true)
        or lower:find("cf-chl-", 1, true) then
        return source:_result_error(stage, "verification_required")
    end
    if Base.login_required(value) or lower:match("<input[^>]-type%s*=%s*[\"']password") then
        return source:_result_error(stage, "login_required")
    end
end

function Favorites.parse(source, body)
    local err = body_error(source, body, "favorites")
    if err then return err end
    local value = Base.visible_html(body)
    local count = tonumber(class_text(value, "list-summary"):match("(%d+)%s*条记录"))
    local title = Base.text(body:match("<title[^>]*>(.-)</title>"))
    if title ~= "我的收藏" or not count then return source:_result_error("favorites", "parse_error") end
    local cards, seen = {}, {}
    for opening, inner in value:gmatch("(<a[^>]*>)(.-)</a>") do
        if class_has(opening, "list-item") then
            local href = Base.attr(opening, "href") or ""
            local id = href:match("^/Android/details/%?kuid=(%d+)$")
            local name = class_text(inner, "item-title")
            if not id or name == "" then return source:_result_error("favorites", "parse_error") end
            if not seen[id] then
                seen[id] = true
                local image = Base.image_url(inner:match("<img[^>]*>") or "")
                local cover = Base.absolute(source.origin, image)
                cards[#cards + 1] = Models.card{
                    site_id = source.id, comic_id = id, title = name,
                    author = class_text(inner, "item-meta"):gsub("^作者：%s*", ""),
                    cover_url = cover, cover_headers = cover and source:image_headers(cover) or {},
                    detail_url = source.origin .. "/Android/details/?kuid=" .. id,
                }
            end
        end
    end
    if #cards == 0 and count ~= 0 or #cards > count then
        return source:_result_error("favorites", "parse_error")
    end
    local total_pages, has_pagination = 1, false
    for opening in value:gmatch("<a[^>]*>") do
        local href = Base.attr(opening, "href") or ""
        if href:match("^/Android/my/%?") and (href:match("[?&]type=fav&") or href:match("[?&]type=fav$"))
            and not href:match("[?&]action=") then
            local page = tonumber(href:match("[?&]page=(%d+)"))
            if page and page >= 1 and page <= 10000 then
                total_pages, has_pagination = math.max(total_pages, page), true
            end
        end
    end
    return { cards = cards, total_count = count, total_pages = total_pages, has_pagination = has_pagination }
end

local function cookie(source)
    local auth = source.auth
    if not auth then return "" end
    if type(auth.active_cookie) == "function" then return auth:active_cookie(source.id) or "" end
    return type(auth.cookie) == "function" and auth:cookie(source.id) or ""
end

local function has_auth(value)
    for name, entry in tostring(value):gmatch("([%w_%-]+)%s*=%s*([^;]+)") do
        if name:match("_auth$") and entry:match("%S") then return true end
    end
    return false
end

-- Each operation owns its active transport handle across GET -> POST, including inline callbacks.
-- Do not replay Zero's toggle endpoint: a retry could add the favorite back.
local function operation(source, stage, callbacks)
    callbacks = callbacks or {}
    local origin, account = source.origin, cookie(source)
    local state = { sequence = 0 }
    local function finish(ok, value)
        if state.done or state.canceled then return false end
        state.done = true
        state.handle = nil
        local callback = callbacks[ok and "on_success" or "on_error"]
        if callback then return callback(value) end
        return true
    end
    function state:cancel()
        if self.done or self.canceled then return end
        self.canceled = true
        if self.handle and self.handle.cancel then pcall(self.handle.cancel, self.handle) end
        self.handle = nil
    end
    function state:valid()
        if self.done or self.canceled then return false end
        if source.origin ~= origin or cookie(source) ~= account then
            finish(false, source:_result_error(stage, "login_required"))
            return false
        end
        return true
    end
    function state:request(method, path, fields, success, failure)
        if not self:valid() then return false end
        self.sequence = self.sequence + 1
        local sequence = self.sequence
        local url = origin .. path
        local headers = source:_headers(url)
        headers.Referer = origin .. "/Android/my/?type=fav"
        if method == "POST" then
            headers.Origin, headers.Referer = origin, url
            headers["X-Requested-With"] = "XMLHttpRequest"
        end
        local options = { site_id = source.id, stage = stage, headers = headers,
            inline_response = true, ui_nonblocking = true, no_replay = method == "POST" }
        local handlers = {
            on_success = function(body, response)
                if not self:valid() or self.sequence ~= sequence then return false end
                local status = tonumber((response or {}).status) or 0
                if status ~= 200 then
                    return failure(source:_result_error(stage, "http_error"))
                end
                source:_merge_set_cookie((response or {}).headers or {})
                account = cookie(source)
                local err = body_error(source, body, stage)
                if err then return failure(err) end
                return success(body)
            end,
            on_error = function(err)
                if not self:valid() or self.sequence ~= sequence then return false end
                return failure(err or source:_result_error(stage, "network_error"))
            end,
        }
        local ok, handle = pcall(function()
            if method == "POST" then return source.http:post_form(url, fields, options, handlers) end
            return source.http:get(url, options, handlers)
        end)
        if not ok then handlers.on_error(source:_result_error(stage, "network_error")) end
        if self.sequence == sequence and not self.done and not self.canceled then self.handle = handle end
        return handle
    end
    if type(origin) ~= "string" or not (origin:match("^https://[%w%.%-]+$")
        or origin:match("^https://[%w%.%-]+:%d+$")) then
        finish(false, source:_result_error(stage, "parse_error"))
    elseif not has_auth(account) then
        finish(false, source:_result_error(stage, "login_required"))
    end
    return state, finish
end

function Favorites.list(source, options, callbacks)
    local state, finish = operation(source, "favorites", callbacks)
    local page = math.max(1, math.min(10000, math.floor(tonumber((options or {}).page) or 1)))
    state:request("GET", "/Android/my/?type=fav" .. (page > 1 and "&page=" .. page or ""), nil,
        function(body)
            local result = Favorites.parse(source, body)
            if result.code then return finish(false, result) end
            result.page = result.has_pagination and page or 1
            result.total_pages = math.max(result.page, result.total_pages)
            return finish(true, result)
        end, function(err) return finish(false, err) end)
    return state
end

function Favorites.remove(source, comic_id, callbacks)
    local state, finish = operation(source, "favorite_remove", callbacks)
    comic_id = tostring(comic_id or "")
    if not comic_id:match("^%d+$") then
        finish(false, source:_result_error("favorite_remove", "parse_error"))
        return state
    end
    local function removed() return finish(true, { removed = true, comic_id = comic_id }) end
    local function uncertain(err)
        local code = err and err.code == "login_required" and "login_required"
            or "favorite_remove_uncertain"
        return finish(false, source:_result_error("favorite_remove", code))
    end
    state:request("GET", "/Android/details/?kuid=" .. comic_id, nil, function(body)
        local button
        for opening in Base.visible_html(body):gmatch("<a[^>]*>") do
            if Base.attr(opening, "id") == "btn-fav" then button = opening; break end
        end
        if not button or not class_has(button, "btn-fav") then
            return finish(false, source:_result_error("favorite_remove", "parse_error"))
        end
        if not class_has(button, "active") then return removed() end
        local formhash = body:match("formhash%s*:%s*[\"']([%w]+)[\"']")
            or body:match("[\"']formhash[\"']%s*:%s*[\"']([%w]+)[\"']")
        if not formhash or #formhash > 64 or #formhash < 4
            or not body:match("action%s*:%s*[\"']toggle_fav[\"']") then
            return finish(false, source:_result_error("favorite_remove", "parse_error"))
        end
        state:request("POST", "/Android/details/?kuid=" .. comic_id,
            { action = "toggle_fav", formhash = formhash }, function(response)
                local ok, json = pcall(require, "rapidjson")
                local decoded, result = false, nil
                if ok then decoded, result = pcall(json.decode, response) end
                if not decoded or type(result) ~= "table" then return uncertain() end
                if result.status == 0 then return removed() end
                if result.status == -1 then return uncertain({ code = "login_required" }) end
                return uncertain()
            end, uncertain)
    end, function(err) return finish(false, err) end)
    return state
end

return Favorites
