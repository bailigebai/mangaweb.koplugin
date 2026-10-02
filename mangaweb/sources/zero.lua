local Base = require("mangaweb.sources.base")
local Models = require("mangaweb.models")

local Zero = setmetatable({}, { __index = Base })
Zero.__index = Zero
Zero.id = "zero"
Zero.name = "Zero 搬运网"
Zero.origin = "https://www.zerobyw33.com"

function Zero:new(options)
    options = options or {}
    options.id, options.name, options.origin = self.id, self.name,
        options.origin or self.origin
    return setmetatable(options, self)
end

function Zero:meta() return { id = self.id, name = self.name, origin = self.origin } end
function Zero:capabilities()
    return { categories = true, tags = true, search = true, pages = true, login = true,
        combined_filters = false }
end

local function checked(body, stage, site_id)
    return Base.guard_body(body, site_id, stage)
end

local function has_auth_cookie(value)
    for pair in tostring(value or ""):gmatch("[^;]+") do
        local name, cookie_value = pair:match("^%s*([%w_%-]+)%s*=%s*(.-)%s*$")
        if name and name:lower():match("_auth$") and cookie_value ~= "" then return true end
    end
    return false
end

local function current_cookie(auth, site_id)
    if not auth then return "" end
    if type(auth.active_cookie) == "function" then return auth:active_cookie(site_id) end
    if type(auth.cookie) == "function" then return auth:cookie(site_id) end
    return ""
end

local function is_login_page(body)
    body = Base.visible_html(body)
    if Base.login_required(body) or body:match("name%s*=%s*[\"']android_my_login[\"']") then return true end
    for opening, fields in body:gmatch("(<form[^>]*>)(.-)</form>") do
        local action = tostring(Base.attr(opening, "action") or ""):lower()
        local class = tostring(Base.attr(opening, "class") or ""):lower()
        if (action:find("/android/my/", 1, true) or action:find("member.php?mod=logging", 1, true)
            or class:find("my-login-form", 1, true)
            or tostring(Base.attr(opening, "id") or ""):lower() == "loginform")
            and fields:lower():match("<input[^>]*type%s*=%s*[\"']password[\"']") then return true end
    end
    return false
end

local function is_logged_in(body)
    local visible = Base.visible_html(body)
    for opening in visible:gmatch("<button[^>]*>") do
        local class = " " .. tostring(Base.attr(opening, "class") or ""):lower() .. " "
        if class:find(" btn-logout ", 1, true)
            or tostring(Base.attr(opening, "id") or ""):lower() == "btn-logout" then return true end
    end
    for opening, label in visible:gmatch("(<a[^>]*>)(.-)</a>") do
        local href = tostring(Base.attr(opening, "href") or ""):lower()
        local text = Base.text(label)
        if href:find("logout", 1, true) or text:find("退出登录", 1, true)
            or text:find("注销", 1, true) then return true end
    end
    if visible:match("<[^>]+class=[\"'][^\"']*%f[%w]user%-card%f[%W][^\"']*[\"']")
        and visible:match("<[^>]+class=[\"'][^\"']*%f[%w]u%-name%f[%W][^\"']*[\"']") then
        return true
    end
    return false
end

local function class_text(block, class)
    local value = block:match("class=[\"'][^\"']*" .. class .. "[^\"']*[\"'][^>]*>(.-)</")
    return Base.text(value)
end

local function first_image(block)
    return Base.image_url(block:match("<img[^>]*>") or "")
end

local function image_absolute(origin, raw)
    -- Zero currently serves its tupa CDN over HTTP for covers and uses
    -- protocol-relative URLs for reader pages. Preserve that CDN protocol so
    -- Kindle does not have to negotiate a second TLS/SNI endpoint for every
    -- manga image; no account cookie is sent to this separate host.
    if type(raw) == "string" and raw:match("^//tupa%.zerobyw33%.com/") then
        return "http:" .. raw
    end
    return Base.absolute(origin, raw)
end

local function card_blocks(body)
    local blocks = {}
    for block in body:gmatch("(<a[^>]*>.-</a>)") do
        local opening = block:match("^<a[^>]*>") or ""
        local href = Base.attr(opening, "href") or ""
        if href:find("kuid=", 1, true) then
            blocks[#blocks + 1] = block
        end
    end
    return blocks
end

local function page_count(value)
    value = Base.text(value)
    return tonumber(value:match("(%d+)%s*[话頁页]") or value:match("[%-%～~]%s*(%d+)")
        or value:match("(%d+)%s*[Pp]")) or 0
end

local function collect_images(source, body)
    local pages = {}
    for tag in body:gmatch("<img[^>]*>") do
        local classes = " " .. tostring(Base.attr(tag, "class") or "") .. " "
        if classes:find(" comic%-page ") or classes:find(" manga%-img ") then
            local raw = Base.image_url(tag)
            local url = image_absolute(source.origin, raw)
            if url then pages[#pages + 1] = { url = url, headers = source:image_headers(url) } end
        end
    end
    return Base.unique_pages(pages)
end

local function empty_or_parse(body, stage, site_id)
    local value, error_result = checked(body, stage, site_id)
    if not value then return error_result end
    return nil
end

function Zero:parse_list(body)
    local value, error_result = checked(body, "list", self.id)
    if not value then return error_result end
    if Base.login_required(value) or is_login_page(value) then
        return self:_result_error("list", "login_required")
    end
    local cards = {}
    for _, block in ipairs(card_blocks(value)) do
        local href = Base.attr(block, "href")
        local id = href and href:match("kuid=([^&\"'#]+)")
        local raw_cover = first_image(block)
    local cover = image_absolute(self.origin, raw_cover)
        if id and cover then
            local title = class_text(block, "manga%-name")
            if title == "" then title = class_text(block, "manga%-card%-title") end
            if title == "" then title = Base.attr(block:match("<img[^>]*>") or "", "alt") or "" end
            local meta = class_text(block, "meta%-summary")
            if meta == "" then meta = class_text(block, "manga%-card%-meta") end
            cards[#cards + 1] = Models.card{
                site_id = self.id, comic_id = id, title = title,
                cover_url = cover, cover_headers = self:image_headers(cover),
                detail_url = Base.absolute(self.origin, href),
                page_count = page_count(meta), tags = Base.tags_in(block:match("class=[\"'][^\"']*tags?[^\"']*[\"'][^>]*>(.-)</div>") or ""),
            }
        end
    end
    if #cards == 0 then
        if self.logger and type(self.logger.warn) == "function" then
            pcall(self.logger.warn, "MangaWeb Zero parse_list empty", "bytes", tostring(#value))
        end
        return self:_result_error("list", value:match("<%s*[Hh][Tt][Mm][Ll]") and (Base.malformed_html(value) and "parse_error" or "empty_result") or "parse_error")
    end
    return cards
end

function Zero:parse_detail(body, comic_id)
    local value, error_result = checked(body, "detail", self.id)
    if not value then return error_result end
    local title = Base.text(value:match("class=[\"'][^\"']*m%-title[^\"']*[\"'][^>]*>(.-)</"))
    if title == "" then title = Base.text(value:match("<h1[^>]*>(.-)</h1>")) end
    local id = value:match("kuid=([%w%-]+)") or tostring(comic_id or "")
    local cover_tag = value:match("<img[^>]*class=[\"'][^\"']*cover%-img[^\"']*[\"'][^>]*>")
        or value:match("<img[^>]*class=[\"'][^\"']*cover[^\"']*[\"'][^>]*>") or ""
    local cover = image_absolute(self.origin, Base.image_url(cover_tag))
    if title == "" or id == "" or not cover then return self:_result_error("detail", "parse_error") end
    local chapters, chapter_count = {}, 0
    for opening, inner in value:gmatch("(<a[^>]*class=[\"'][^\"']*chapter%-item[^\"']*[\"'][^>]*>)(.-)</a>") do
        local chapter_url = Base.attr(opening, "href")
        local chapter_id = chapter_url and chapter_url:match("zjid=([^&\"'#]+)")
        if chapter_id then
            chapters[#chapters + 1] = { id = chapter_id, title = Base.text(inner), page_count = 0 }
        end
    end
    if #chapters == 0 then
        for opening, inner in value:gmatch("(<a[^>]*class=[\"'][^\"']*chapter[^\"']*[\"'][^>]*>)(.-)</a>") do
            local chapter_url = Base.attr(opening, "href")
            local chapter_id = chapter_url and chapter_url:match("[?&]zjid=([^&\"'#]+)")
            chapters[#chapters + 1] = { id = chapter_id or chapter_url or tostring(#chapters + 1),
                title = Base.text(inner), page_count = 0 }
        end
    end
    -- The current site also exposes a primary “阅读” link whose class is not
    -- chapter-item. Keep that link as the default chapter when the chapter
    -- list is rendered with a different class or wrapper.
    if #chapters == 0 then
        for href in value:gmatch("href=[\"']([^\"']*[?&]zjid=([^&\"'#]+)[^\"']*)[\"']") do
            local chapter_id = href:match("[?&]zjid=([^&\"'#]+)")
            if chapter_id then
                chapters[#chapters + 1] = { id = chapter_id, title = "默认章节", page_count = 0 }
                break
            end
        end
    end
    if #chapters == 0 and Base.login_required(value) then return self:_result_error("detail", "login_required") end
    chapter_count = #chapters
    local author = class_text(value, "author")
    if author == "" then
        author = Base.text(value:match("class=[\"'][^\"']*my%-tag[^\"']*[\"'][^>]*>[%s]*作者:%s*(.-)</span>"))
    end
    local card = Models.card{
        site_id = self.id, comic_id = id, title = title,
        author = author,
        cover_url = cover, cover_headers = self:image_headers(cover),
        page_count = chapter_count,
        tags = Base.tags_in(value:match("class=[\"'][^\"']*tags[^\"']*[\"'][^>]*>(.-)</div>") or ""),
    }
    return Models.detail{
        card = card,
        description = Base.text(value:match("class=[\"'][^\"']*description[^\"']*[\"'][^>]*>(.-)</")
            or value:match("class=[\"'][^\"']*summary%-box[^\"']*[\"'][^>]*>(.-)</")),
        chapters = chapters,
    }
end

function Zero:parse_pages(body, comic_id)
    local value, error_result = checked(body, "pages", self.id)
    if not value then return error_result end
    local pages = collect_images(self, value)
    if #pages == 0 then
        return self:_result_error("pages", Base.login_required(value) and "login_required" or "parse_error")
    end
    return Models.pages{ site_id = self.id, comic_id = comic_id, pages = pages }
end

local function parse_categories(body, source, stage)
    local value, error_result = checked(body, stage, source.id)
    if not value then return nil, error_result end
    local result = {}
    for href, text in value:gmatch("<a[^>]*href=[\"']([^\"']*category[^\"']*)[\"'][^>]*>(.-)</a>") do
        local name = Base.text(text)
        local id = Base.absolute(source.origin, href)
        if name ~= "" and id then result[#result + 1] = { id = id, name = name } end
    end
    if #result == 0 then return nil, source:_result_error(stage, "empty_result") end
    return result
end

function Zero:list_categories(callback)
    callback = callback or {}
    return self:_get(self.origin .. "/Android/Android/", "categories", {
        on_success = function(body)
            local result, error_result = parse_categories(body, self, "categories")
            if result then return callback.on_success(result) end
            return callback.on_error(error_result)
        end,
        on_error = callback.on_error,
    })
end

function Zero:list_tags(query, callback)
    callback = callback or {}
    local url = self.origin .. "/Android/Android/"
    if query and query ~= "" then url = Base.with_query(url, { "tag=" .. Base.url_encode(query) }) end
    return self:_get(url, "tags", {
        on_success = function(body)
            local value, error_result = checked(body, "tags", self.id)
            if not value then return callback.on_error(error_result) end
            local result = {}
            for opening, inner in value:gmatch("(<a[^>]*class=[\"'][^\"']*filter%-item[^\"']*[\"'][^>]*>)(.-)</a>") do
                local href = Base.attr(opening, "href") or ""
                if href:find("shuxing", 1, true) or href:find("jindu", 1, true) then
                    local name = Base.text(inner)
                    if name ~= "" then result[#result + 1] = { id = Base.absolute(self.origin, href), name = name } end
                end
            end
            if #result == 0 then for href, text in value:gmatch("<a[^>]*href=[\"']([^\"']*tag[^\"']*)[\"'][^>]*>(.-)</a>") do
                local name = Base.text(text)
                if name ~= "" then result[#result + 1] = { id = Base.absolute(self.origin, href), name = name } end
            end end
            if #result == 0 then return callback.on_error(self:_result_error("tags", "empty_result")) end
            return callback.on_success(result)
        end,
        on_error = callback.on_error,
    })
end

function Zero:primary_channels()
    return { { id = "home", name = "首页", options = {} } }
end

local function rule_value(url, key, fallback)
    local value = type(url) == "string" and url:match("[?&]" .. key .. "=([^&#]*)") or nil
    if value == nil then return fallback end
    if value:find("%%[%da-fA-F][%da-fA-F]") then return value end
    return Base.url_encode(value)
end

function Zero:list(options, callback)
    options = options or {}; callback = callback or {}
    local url = self.origin .. "/Android/Android/"
    local query = tostring(options.query or "")
    local category = options.category
    if type(category) == "table" then category = category.id or category.value end
    category = tostring(category or "")
    if query ~= "" and category == "" and tostring(options.tag or "") == "" then
        return self:search(query, options, callback)
    end
    local category_id = category:match("category_id=([^&]+)") or (category:match("^%d+$") and category)
    local tag = tostring(options.tag or "")
    local rule_url = category:find("[?&]category_id=", 1) and category or nil
    if not rule_url and tag:find("[?&]category_id=", 1) then rule_url = tag end
    category_id = category_id or (rule_url and rule_url:match("[?&]category_id=([^&]+)"))
    local params
    if category_id or rule_url or (category == "" and tag == "") then
        params = {
            "category_id=" .. rule_value(rule_url, "category_id", category_id and Base.url_encode(category_id) or "0"),
            "jindu=" .. rule_value(rule_url, "jindu", ""),
            "shuxing=" .. rule_value(rule_url, "shuxing", ""),
            "order=" .. rule_value(rule_url, "order", "addtime"),
            "dir=" .. rule_value(rule_url, "dir", "desc"),
            "page=" .. tostring(math.max(1, math.floor(tonumber(options.page) or 1))),
        }
    else
        params = Base.params(options, {
            { "category", "category" }, { "tag", "tag" }, { "sort", "sort" },
            { "keyword", "query" }, { "page", "page" },
        })
    end
    url = Base.with_query(url, params)
    local function fetch(target, fallback_depth)
        fallback_depth = tonumber(fallback_depth) or 0
        return self:_get(target, "list", {
            on_success = function(body)
                local result = self:parse_list(body)
                if result.code then
                    if result.code == "empty_result" and query == "" and fallback_depth < 2 then
                        local fallback = fallback_depth == 0
                            and self.origin .. "/Android/Android/?dir=desc&page=1"
                            or self.origin .. "/Android/Android/"
                        if fallback ~= target then return fetch(fallback, fallback_depth + 1) end
                    end
                    return callback.on_error(result)
                end
                local current, total = Base.pagination(body)
                return callback.on_success{ cards = result, page = tonumber(options.page) or current, total_pages = total }
            end,
            on_error = callback.on_error,
        })
    end
    return fetch(url, 0)
end

function Zero:search(keyword, options, callback)
    options = options or {}; options.query = keyword
    local url = self.origin .. "/Android/souo/"
    local params = { "keyword=" .. Base.url_encode(keyword or "") }
    if tonumber(options.page) then params[#params + 1] = "page=" .. math.floor(options.page) end
    return self:_get(Base.with_query(url, params), "list", {
        on_success = function(body)
            local result = self:parse_list(body)
            if result.code then return callback.on_error(result) end
            local current, total = Base.pagination(body)
            return callback.on_success{ cards = result, page = tonumber(options.page) or current, total_pages = total }
        end,
        on_error = callback.on_error,
    })
end

function Zero:detail(comic_id, callback)
    if type(comic_id) ~= "string" or comic_id == "" then return callback.on_error(self:_result_error("detail", "parse_error")) end
    return self:_get(self.origin .. "/Android/details/?kuid=" .. Base.url_encode(comic_id), "detail", {
        on_success = function(body)
            local result = self:parse_detail(body, comic_id)
            if result.code then return callback.on_error(result) end
            return callback.on_success(result)
        end,
        on_error = callback.on_error,
    })
end

function Zero:pages(comic_id, chapter_id, callback)
    if type(comic_id) ~= "string" or comic_id == "" then return callback.on_error(self:_result_error("pages", "parse_error")) end
    if not chapter_id or chapter_id == "" then
        -- Some authenticated detail responses omit the chapter list but keep
        -- the primary “阅读” link. Resolve that link once before declaring the
        -- reader unavailable, so Start Reading and previews share one path.
        return self:_get(self.origin .. "/Android/details/?kuid=" .. Base.url_encode(comic_id), "detail", {
            on_success = function(body)
                local detail = self:parse_detail(body, comic_id)
                if detail.code then return callback.on_error(self:_result_error("pages", detail.code)) end
                local first = detail.chapters and detail.chapters[1]
                if not first or not first.id or first.id == "" then
                    return callback.on_error(self:_result_error("pages", "parse_error"))
                end
                return self:pages(comic_id, first.id, callback)
            end,
            on_error = callback.on_error,
        })
    end
    local url = self.origin .. "/Android/view/?zjid=" .. Base.url_encode(chapter_id)
    return self:_get(url, "pages", {
        on_success = function(body)
            local result = self:parse_pages(body, comic_id)
            if result.code then return callback.on_error(result) end
            return callback.on_success(result)
        end,
        on_error = callback.on_error,
    })
end

local function login_fields(form)
    local username, password, fields = nil, nil, {}
    for tag in form:gmatch("<input[^>]*>") do
        local name, kind = Base.attr(tag, "name"), (Base.attr(tag, "type") or "text"):lower()
        local value = Base.attr(tag, "value") or ""
        local disabled = tag:lower():match("%f[%w]disabled%f[%W]") ~= nil
        local checked = tag:lower():match("%f[%w]checked%f[%W]") ~= nil
        local excluded = kind == "submit" or kind == "button" or kind == "reset"
            or kind == "image" or kind == "file"
        if name and name ~= "" and not disabled and not excluded
            and (kind ~= "checkbox" and kind ~= "radio" or checked) then fields[name] = value end
        if name and name ~= "" and not disabled and kind == "password" then password = password or name end
        if name and name ~= "" and not disabled and kind ~= "hidden" and kind ~= "password" and not excluded then
            if not username and (name:lower():find("user", 1, true) or name:lower():find("name", 1, true)
                or name:lower():find("account", 1, true) or kind == "email") then username = name end
        end
    end
    for opening, options in form:gmatch("(<select[^>]*>)(.-)</select>") do
        local name = Base.attr(opening, "name")
        if name and name ~= "" and not opening:lower():match("%f[%w]disabled%f[%W]") then
            local selected
            for option in options:gmatch("<option[^>]*>") do
                if not selected or option:lower():match("%f[%w]selected%f[%W]") then
                    selected = Base.attr(option, "value") or ""
                    if option:lower():match("%f[%w]selected%f[%W]") then break end
                end
            end
            fields[name] = selected or ""
        end
    end
    for tag in form:gmatch("<button[^>]*>") do
        local name = Base.attr(tag, "name")
        local kind = (Base.attr(tag, "type") or "submit"):lower()
        if name and name ~= "" and kind == "submit"
            and not tag:lower():match("%f[%w]disabled%f[%W]") then
            fields[name] = Base.attr(tag, "value") or ""
        end
    end
    return username, password, fields
end

local function https_origin(url)
    if type(url) ~= "string" or url:find("[%s\\]") then return nil end
    local authority = url:match("^https://([^/%?#]+)")
    if not authority then return nil end
    local host, port = authority:match("^([%w%.%-]+):(%d+)$")
    if not host then host, port = authority:match("^([%w%.%-]+)$"), "443" end
    port = tonumber(port)
    if not host or not port or port < 1 or port > 65535 then return nil end
    return host:lower() .. ":" .. port
end

function Zero:login(credentials, callback)
    credentials, callback = credentials or {}, callback or {}
    if self.auth and self.auth.clear then pcall(self.auth.clear, self.auth, self.id) end
    local login_url = self.origin .. "/Android/my/"
    local legacy_login_url = self.origin .. "/login.php?referer=%2FAndroid%2Fmy%2F&mobile=2"
    local anonymous_login_url = self.origin:gsub("^https:", "http:") .. "/Android/my/"
    local function load_login_form(url, allow_legacy, allow_http)
        local handlers = {
            on_success = function(body)
                local value, error_result = checked(body, "login_form", self.id)
                if not value then
                    if allow_legacy and error_result.code == "empty_result" then
                        return load_login_form(legacy_login_url, false, allow_http)
                    elseif allow_http and error_result.code == "empty_result" then
                        return load_login_form(anonymous_login_url, false, false)
                    end
                    return callback.on_error(error_result)
                end
            local form_tag, form
            for candidate_tag, candidate in value:gmatch("(<form[^>]*>)(.-)</form>") do
                if candidate:match("<input[^>]+type%s*=%s*[\"']password") or candidate:match("<input[^>]*password") then
                    form_tag, form = candidate_tag, candidate
                    break
                end
            end
            form_tag = form_tag or value:match("<form[^>]*>") or ""
            form = form or value:match("<form[^>]*>(.-)</form>") or value
            local user_field, pass_field, fields = login_fields(form)
            if form_tag == "" or not user_field or not pass_field then return callback.on_error(self:_result_error("login_form", "parse_error")) end
            fields[user_field], fields[pass_field] = credentials.username or "", credentials.password or ""
            if fields.questionid ~= nil and credentials.question_id ~= nil then
                fields.questionid = tostring(credentials.question_id)
            end
            if fields.answer ~= nil and credentials.answer ~= nil then
                fields.answer = tostring(credentials.answer)
            end
            local raw_action = (Base.attr(form_tag, "action") or "/login/check"):match("^%s*(.-)%s*$")
            if raw_action:match("^[%a][%w+%.%-]*:") and not raw_action:match("^https://") then
                return callback.on_error(self:_result_error("login_form", "parse_error"))
            end
            local action = Base.absolute(self.origin, raw_action)
            local origin = https_origin(self.origin)
            if not origin or https_origin(action) ~= origin then
                return callback.on_error(self:_result_error("login_form", "parse_error"))
            end
                return self:_post_form(action, fields, "login", {
                    on_success = function(result_body)
                        -- The authenticated account page contains a password-change form.
                        -- Only run login-form heuristics while the response is still a login page.
                        if tostring(result_body or "") ~= "" and is_login_page(result_body) then
                            local outcome = Base.login_outcome(result_body, self.id, "login")
                            if outcome then return callback.on_error(outcome) end
                        end
                        local cookie = current_cookie(self.auth, self.id)
                        if not has_auth_cookie(cookie) then
                            return callback.on_error(self:_result_error("login", "invalid_credentials"))
                        end
                        return self:test_connection{
                            on_success = function(result)
                                return callback.on_success{ verified = true, result = result }
                            end,
                            on_error = function(result)
                                if result and result.code == "login_required" then
                                    result.code, result.stage = "invalid_credentials", "login"
                                end
                                return callback.on_error(result)
                            end,
                        }
                    end,
                    on_error = callback.on_error,
                }, { Origin = self.origin, Referer = login_url })
            end,
            on_error = function(error_result)
                if allow_legacy and error_result and error_result.code == "empty_result" then
                    return load_login_form(legacy_login_url, false, allow_http)
                elseif allow_http and error_result and error_result.code == "empty_result" then
                    return load_login_form(anonymous_login_url, false, false)
                end
                return callback.on_error(error_result)
            end,
        }
        if url ~= anonymous_login_url then return self:_get(url, "login_form", handlers) end
        local headers = self:_headers(url)
        for name in pairs(headers) do
            local lower = tostring(name):lower()
            if lower == "cookie" or lower == "authorization" then headers[name] = nil end
        end
        return self.http:get(url, { site_id = self.id, stage = "login_form",
            headers = headers, inline_response = false }, {
            on_success = function(body, response)
                self:_merge_set_cookie(response and response.headers or {})
                return handlers.on_success(body, response)
            end,
            on_error = handlers.on_error,
        })
    end
    return load_login_form(login_url, true, true)
end

function Zero:test_connection(callback)
    callback = callback or {}
    local cookie = current_cookie(self.auth, self.id)
    if not has_auth_cookie(cookie) then
        return callback.on_error(self:_result_error("connection_test", "login_required"))
    end
    -- ponytail: list fallback proves reachability, not account identity; use a stable account API when available.
    local function verify_from_list(plain)
        local url = plain
            and self.origin .. "/Android/Android/?dir=desc&page=1"
            or self.origin .. "/Android/Android/?category_id=0&jindu=&shuxing=&order=addtime&dir=desc&page=1"
        return self:_get(url,
            "connection_test", {
                on_success = function(body)
                    local result = self:parse_list(body)
                    if type(result) == "table" and not result.code and #result > 0 then
                        return callback.on_success{ verified = true, site_id = self.id, fallback = "list" }
                    end
                    if not plain and type(result) == "table" and result.code == "empty_result" then
                        return verify_from_list(true)
                    end
                    return callback.on_error(self:_result_error("connection_test", "login_unverified"))
                end,
                on_error = function(error_result)
                    if error_result and error_result.code == "empty_result" then
                        if not plain then return verify_from_list(true) end
                        return callback.on_error(self:_result_error("connection_test", "login_unverified"))
                    end
                    return callback.on_error(error_result)
                end,
            })
    end
    local function handle_connection_error(error_result)
        if error_result and error_result.code == "empty_result" then
            return verify_from_list()
        end
        return callback.on_error(error_result)
    end
    return self:_get(self.origin .. "/Android/my/", "connection_test", {
        on_success = function(body)
            local value, error_result = checked(body, "connection_test", self.id)
            if not value then
                if error_result and error_result.code == "empty_result" then
                    return verify_from_list()
                end
                return callback.on_error(error_result)
            end
            if is_login_page(value) then
                return callback.on_error(self:_result_error("connection_test", "login_required"))
            end
            if not is_logged_in(value) then
                return callback.on_error(self:_result_error("connection_test", "login_unverified"))
            end
            return callback.on_success{ verified = true, site_id = self.id }
        end,
        on_error = handle_connection_error,
    })
end

return Zero
