local Base = {}
Base.__index = Base

local MOBILE_USER_AGENT = "Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36"

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function decode(value)
    value = tostring(value or "")
    value = value:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'")
    value = value:gsub("&#(%d+);", function(number) return string.char(tonumber(number)) end)
    return value
end

local function strip(value)
    return decode(tostring(value or ""):gsub("<[^>]+>", ""):gsub("%s+", " ")):match("^%s*(.-)%s*$")
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

function Base.attr(tag, name)
    if type(tag) ~= "string" or type(name) ~= "string" then return nil end
    local quoted = tag:match("%f[%w]" .. name .. "%s*=%s*\"(.-)\"")
        or tag:match("%f[%w]" .. name .. "%s*=%s*'(.-)'")
        or tag:match("%f[%w]" .. name .. "%s*=%s*([^%s>]+)")
    return quoted and decode(quoted) or nil
end

function Base.text(value) return strip(value) end

function Base.visible_html(body)
    body = tostring(body or "")
    local folded = body:lower()
    local invisible = { script = true, style = true, template = true,
        noscript = true, textarea = true, title = true }
    local result, stack, cursor, position = {}, {}, 1, 1
    local function markup_end(first, reject_nested)
        local quote
        for index = first, #body do
            local character = body:sub(index, index)
            if quote then
                if character == quote then quote = nil end
            elseif character == '"' or character == "'" then
                quote = character
            elseif reject_nested and character == "<" then return nil, true
            elseif character == ">" then return index + 1, false end
        end
        return nil, false
    end
    local function tag_at(first)
        local start, _, closing, name, after = folded:find("<(/?)([%a][%w:%-]*)()", first)
        if start ~= first or not body:sub(after, after):match("[%s/>]") then return end
        local last, nested = markup_end(after, true)
        return closing, name, last, nested
    end
    while position <= #body do
        local current = stack[#stack]
        if current and current ~= "template" then
            local _, last = folded:find("</" .. current .. "%s*>", position)
            if not last then return table.concat(result) end
            stack[#stack] = nil
            position, cursor = last + 1, last + 1
        else
            local first = body:find("<", position, true)
            if not first then break end
            if body:sub(first, first + 3) == "<!--" then
                if not current then result[#result + 1] = body:sub(cursor, first - 1) end
                local last = body:find("-->", first + 4, true)
                if not last then return table.concat(result) end
                position, cursor = last + 3, last + 3
            elseif body:sub(first, first + 1) == "<!" or body:sub(first, first + 1) == "<?" then
                if not current then result[#result + 1] = body:sub(cursor, first - 1) end
                local last = markup_end(first + 2, false)
                if not last then return table.concat(result) end
                position, cursor = last, last
            else
                local closing, name, last, nested = tag_at(first)
                if not name or nested then
                    position = first + 1
                elseif not last then
                    if not current then result[#result + 1] = body:sub(cursor, first - 1) end
                    return table.concat(result)
                elseif invisible[name] and closing == "" then
                    if not current then result[#result + 1] = body:sub(cursor, first - 1) end
                    stack[#stack + 1] = name
                    position, cursor = last, last
                elseif current and closing == "/" and name == current then
                    stack[#stack] = nil
                    position, cursor = last, last
                else
                    if not current then
                        result[#result + 1] = body:sub(cursor, first)
                        result[#result + 1] = body:sub(first + 1, last - 1):gsub("<", "&lt;")
                        cursor = last
                    end
                    position = last
                end
            end
        end
    end
    if #stack == 0 then result[#result + 1] = body:sub(cursor) end
    return table.concat(result)
end

function Base.image_url(tag)
    for _, name in ipairs({ "data-src", "data-original", "data-lazy-src", "src" }) do
        local value = trim(Base.attr(tag, name))
        if value ~= "" then return value end
    end
    return nil
end

function Base.url_encode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
end

function Base.absolute(origin, url)
    if type(url) ~= "string" then return nil end
    url = trim(decode(url))
    if url == "" or url:match("^[Jj][Aa][Vv][Aa][Ss][Cc][Rr][Ii][Pp][Tt]:")
        or url:match("^[Dd][Aa][Tt][Aa]:") then return nil end
    url = url:gsub("^//+", "//")
    if url:match("^https?://") then return url end
    origin = trim(origin)
    local scheme = origin:match("^(https?):") or "https"
    if url:match("^//") then return scheme .. ":" .. url end
    local authority, base_path = origin:match("^(https?://[^/]+)(/.*)$")
    if not authority then authority, base_path = origin:match("^(https?://[^/]+)$"), "/" end
    if not authority then return nil end
    if url:sub(1, 1) == "/" then
        base_path = url
    else
        local directory = base_path:sub(-1) == "/" and base_path or (base_path:match("^(.*)/") or "/")
        base_path = directory .. "/" .. url
    end
    local trailing_slash = base_path:sub(-1) == "/"
    local parts = {}
    for part in base_path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then parts[#parts] = nil end
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    local result = authority .. "/" .. table.concat(parts, "/")
    if trailing_slash and result:sub(-1) ~= "/" then result = result .. "/" end
    return result
end

function Base.malformed_html(body)
    if type(body) ~= "string" then return true end
    local void = { area = true, base = true, br = true, col = true, embed = true, hr = true,
        img = true, input = true, link = true, meta = true, param = true, source = true, track = true, wbr = true }
    local stack = {}
    for closing, name, tail in body:gmatch("<%s*(/?)%s*([%w][%w%-]*)%s*([^>]*)>") do
        name = name:lower()
        if closing == "/" then
            if stack[#stack] ~= name then return true end
            stack[#stack] = nil
        elseif not void[name] and not tail:match("/%s*$") then
            stack[#stack + 1] = name
        end
    end
    return #stack > 0 or body:match("<[^>]*$") ~= nil
end

function Base.tags_in(fragment)
    local tags = {}
    for anchor in tostring(fragment or ""):gmatch("<a[^>]*>(.-)</a>") do
        local value = strip(anchor)
        if value ~= "" then tags[#tags + 1] = value end
    end
    return tags
end

function Base.unique_pages(pages)
    local result, seen = {}, {}
    for _, page in ipairs(pages or {}) do
        if type(page) == "table" and type(page.url) == "string" and page.url ~= "" and not seen[page.url] then
            seen[page.url] = true
            page.index = #result + 1
            result[#result + 1] = page
        end
    end
    return result
end

function Base:new(options) return setmetatable(options or {}, self) end
function Base:meta() return { id = self.id, name = self.name, origin = self.origin } end
function Base:capabilities() return { categories = true, tags = true, search = true, pages = true, login = false } end
function Base:set_cookie(cookie) return self.auth and self.auth:set_cookie(self.id, cookie) or false, "auth_unavailable" end
function Base:clear_session() return self.auth and self.auth:clear(self.id) or false end

function Base:_headers(url)
    local headers = self.auth and self.auth.headers and self.auth:headers(self.id, url) or {}
    headers["User-Agent"] = headers["User-Agent"] or MOBILE_USER_AGENT
    headers["Accept-Encoding"] = headers["Accept-Encoding"] or "identity"
    return headers
end

function Base:image_headers(url)
    local headers = self:_headers(url)
    headers.Referer = headers.Referer or (self.origin .. "/")
    headers["User-Agent"] = headers["User-Agent"] or MOBILE_USER_AGENT
    return headers
end

function Base.error(site_id, stage, code, detail)
    return { code = code or "parse_error", site_id = site_id, stage = stage, detail = detail }
end

function Base:_result_error(stage, code) return Base.error(self.id, stage, code) end

function Base.guard_body(body, site_id, stage)
    if type(body) ~= "string" then return nil, Base.error(site_id, stage, "parse_error") end
    if trim(body) == "" then return nil, Base.error(site_id, stage, "empty_result") end
    return body
end

function Base.pagination(body)
    local total, current = 1, 1
    if type(body) ~= "string" then return current, total end
    for href, text in body:gmatch("<a[^>]-href=[\"']([^\"']+)[\"'][^>]*>(.-)</a>") do
        local page = tonumber(href:match("[?&]page=([%d]+)") or Base.text(text):match("^%d+$"))
        if page and page > total then total = page end
        if page and href:match("[?&]page=") then current = page end
    end
    local declared = body:match("data%-total%-pages%s*=%s*[\"'](%d+)[\"']")
        or body:match("total[_%-]?pages%s*[:=]%s*[\"']?(%d+)")
    if tonumber(declared) and tonumber(declared) > total then total = tonumber(declared) end
    return current, total
end

function Base.params(options, keys)
    options = options or {}
    local params = {}
    for _, pair in ipairs(keys or {}) do
        local key, value = pair[1], options[pair[2] or pair[1]]
        if type(value) == "table" then value = value.id or value.value or value.name end
        if value ~= nil and tostring(value) ~= "" then params[#params + 1] = key .. "=" .. Base.url_encode(value) end
    end
    return params
end

function Base.with_query(url, params)
    if params and #params > 0 then return url .. (url:find("?", 1, true) and "&" or "?") .. table.concat(params, "&") end
    return url
end

function Base.login_required(body)
    if type(body) ~= "string" then return false end
    local lower = body:lower()
    return lower:find("login-required", 1, true) ~= nil
        or lower:find("login required", 1, true) ~= nil
        or lower:find("please log in", 1, true) ~= nil
        or body:find("请先登录", 1, true) ~= nil
        or body:find("登录后", 1, true) ~= nil
end

function Base.login_outcome(body, site_id, stage)
    local checked, error_result = Base.guard_body(body, site_id, stage)
    if not checked then return error_result end
    local lower = checked:lower()
    if lower:find("invalid", 1, true) or lower:find("incorrect", 1, true)
        or lower:find("login failed", 1, true) or checked:find("密码错误", 1, true)
        or checked:find("登录失败", 1, true) then
        return Base.error(site_id, stage, "invalid_credentials")
    end
    if checked:match("<input[^>]+type%s*=%s*[\"']password") and checked:match("<form") then
        return Base.error(site_id, stage, "invalid_credentials")
    end
    return nil
end

function Base:_merge_set_cookie(headers)
    if not self.auth or not self.auth.set_cookie then return end
    local raw = headers and (headers["set-cookie"] or headers["Set-Cookie"])
    if not raw then return end
    local values, order, seen = {}, {}, {}
    local function add_pair(pair)
        local name, value = pair:match("^%s*([%w_%-]+)%s*=(.*)$")
        if not name then return end
        if not seen[name] then order[#order + 1], seen[name] = name, true end
        if trim(value) == "" then
            values[name] = nil
        else
            values[name] = trim(pair)
        end
    end
    local function add(value, cookie_header)
        if type(value) ~= "string" then return end
        add_pair(value:match("^%s*([^;\r\n]+)") or value)
        if cookie_header then
            for pair in value:gmatch(";%s*([%w_%-]+%s*=%s*[^;,%s]+)") do add_pair(pair) end
        end
        for pair in value:gmatch(",%s*([%w_%-]+%s*=%s*[^;,\r\n]+)") do
            add_pair(pair)
        end
    end
    local existing = self.auth.active_cookie and self.auth:active_cookie(self.id)
        or self.auth.cookie and self.auth:cookie(self.id) or ""
    add(existing, true)
    if type(raw) == "table" then for _, value in ipairs(raw) do add(value) end else add(raw) end
    local result = {}
    for _, name in ipairs(order) do if values[name] then result[#result + 1] = values[name] end end
    if #result > 0 then self.auth:set_cookie(self.id, table.concat(result, "; ")) end
end

function Base:_get(url, stage, callbacks)
    callbacks = callbacks or {}
    local redirects = 0
    local empty_retries = 0
    local max_redirects = 5
    local request
    request = function(target)
        return self.http:get(target, { site_id = self.id, stage = stage, headers = self:_headers(target),
            inline_response = true, ui_nonblocking = stage == "pages" }, {
            on_success = function(body, response)
                local status = response and tonumber(response.status)
                local headers = response and response.headers or {}
                self:_merge_set_cookie(headers)
                local location = headers.location or headers.Location
                if type(location) == "table" then location = location[1] end
                if redirects < max_redirects and trim(body) == "" and status and status >= 200 and status < 400
                    and type(location) == "string" then
                    local redirected = Base.absolute(self.origin, location)
                    local redirected_origin = redirected and https_origin(redirected)
                    local source_origin = https_origin(self.origin)
                    if redirected_origin and source_origin and redirected_origin == source_origin then
                        redirects = redirects + 1
                        return request(redirected)
                    end
                end
                if empty_retries < 1 and trim(body) == "" and status and status >= 200 and status < 400 then
                    empty_retries = empty_retries + 1
                    return request(target)
                end
                if status and status >= 400 then
                    return callbacks.on_error(Base.error(self.id, stage, "http_error", status))
                end
                return callbacks.on_success(body, response)
            end,
            on_error = function(error)
                error = error or Base.error(self.id, stage, "network_error")
                error.site_id, error.stage = self.id, stage
                return callbacks.on_error(error)
            end,
        })
    end
    return request(url)
end

function Base:_post_form(url, fields, stage, callbacks, extra_headers)
    callbacks = callbacks or {}
    local headers = self:_headers(url)
    for name, value in pairs(extra_headers or {}) do headers[name] = value end
    local redirects = 0
    local max_redirects = 5
    local request_get
    request_get = function(target)
        return self.http:get(target, { site_id = self.id, stage = stage, headers = self:_headers(target),
            inline_response = true }, {
            on_success = function(body, response)
                self:_merge_set_cookie(response and response.headers or {})
                local status = response and tonumber(response.status)
                local response_headers = response and response.headers or {}
                local location = response_headers.location or response_headers.Location
                if type(location) == "table" then location = location[1] end
                if redirects < max_redirects and trim(body) == "" and status and status >= 200 and status < 400
                    and type(location) == "string" then
                    local redirected = Base.absolute(self.origin, location)
                    local redirected_origin = redirected and https_origin(redirected)
                    local source_origin = https_origin(self.origin)
                    if redirected_origin and source_origin and redirected_origin == source_origin then
                        redirects = redirects + 1
                        return request_get(redirected)
                    end
                end
                if status and status >= 400 then
                    return callbacks.on_error(Base.error(self.id, stage, "http_error", status))
                end
                return callbacks.on_success(body, response)
            end,
            on_error = function(error)
                error = error or Base.error(self.id, stage, "network_error")
                error.site_id, error.stage = self.id, stage
                return callbacks.on_error(error)
            end,
        })
    end
    return self.http:post_form(url, fields, {
        site_id = self.id, stage = stage, headers = headers, inline_response = true,
    }, {
        on_success = function(body, response)
            self:_merge_set_cookie(response and response.headers or {})
            local status = response and tonumber(response.status)
            local response_headers = response and response.headers or {}
            local location = response_headers.location or response_headers.Location
            if type(location) == "table" then location = location[1] end
            if redirects < max_redirects and trim(body) == "" and status and status >= 200 and status < 400
                and type(location) == "string" then
                local redirected = Base.absolute(self.origin, location)
                local redirected_origin = redirected and https_origin(redirected)
                local source_origin = https_origin(self.origin)
                if redirected_origin and source_origin and redirected_origin == source_origin then
                    redirects = redirects + 1
                    return request_get(redirected)
                end
            end
            if status and status >= 400 then
                return callbacks.on_error(Base.error(self.id, stage, "http_error", status))
            end
            return callbacks.on_success(body, response)
        end,
        on_error = function(error)
            error = error or Base.error(self.id, stage, "network_error")
            error.site_id, error.stage = self.id, stage
            return callbacks.on_error(error)
        end,
    })
end

return Base
