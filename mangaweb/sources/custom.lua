local Base = require("mangaweb.sources.base")
local Models = require("mangaweb.models")
local Definitions = require("mangaweb.site_definitions")

local Custom = setmetatable({}, { __index = Base })
Custom.__index = Custom

local MAX_HTML_BYTES = 2 * 1024 * 1024
local MAX_CARDS, MAX_CHAPTERS, MAX_PAGES = 100, 500, 1000

local function authority(url)
    return type(url) == "string" and url:match("^https://([^/%?#]+)") or nil
end

local function same_origin(origin, url)
    local first, second = authority(origin), authority(url)
    return first and second and first:lower() == second:lower()
end

local function captured(body, pattern)
    if pattern == "" then return nil end
    local ok, value = pcall(string.match, body, pattern)
    return ok and value or nil
end

local function matches(body, pattern, limit)
    local result = {}
    local ok = pcall(function()
        for value in body:gmatch(pattern) do
            if type(value) == "string" and value ~= "" then
                result[#result + 1] = value
                if #result >= limit then break end
            end
        end
    end)
    return ok and result or nil
end

local function checked(self, body, stage)
    local value, error_result = Base.guard_body(body, self.id, stage)
    if not value then return nil, error_result end
    if #value > MAX_HTML_BYTES then
        return nil, self:_result_error(stage, "response_too_large")
    end
    return value
end

function Custom:new(options)
    options = options or {}
    local definition = assert(options.definition, "site definition is required")
    local valid, reason = Definitions.validate(definition)
    assert(valid, reason)
    options.id, options.name, options.origin = assert(definition.id), valid.name, valid.origin
    options.rules = valid.rules
    options.definition = nil
    return setmetatable(options, self)
end

function Custom:meta()
    return { id = self.id, name = self.name, origin = self.origin, custom = true }
end

function Custom:capabilities()
    return { categories = false, tags = false, search = self.rules.search_path ~= "",
        pages = true, cookie = true, login = false }
end

function Custom:_html_url(raw, base)
    local url = Base.absolute(base or self.origin, raw)
    return url and same_origin(self.origin, url) and url or nil
end

function Custom:_template(path, options)
    options = options or {}
    local page = tostring(math.max(1, math.floor(tonumber(options.page) or 1)))
    path = path:gsub("{page}", function() return page end)
    path = path:gsub("{query}", function() return Base.url_encode(options.query or "") end)
    return self:_html_url(path, self.origin)
end

function Custom:parse_list(body, page_url)
    local value, error_result = checked(self, body, "list")
    if not value then return error_result end
    local rules = self.rules
    local blocks = matches(value, rules.list_block, MAX_CARDS)
    if not blocks then return self:_result_error("list", "parse_error") end
    local cards, seen = {}, {}
    for _, block in ipairs(blocks) do
        local detail = self:_html_url(captured(block, rules.list_href), page_url or self.origin)
        local title = Base.text(captured(block, rules.list_title))
        local cover = Base.absolute(page_url or self.origin,
            captured(block, rules.list_cover))
        if detail and title ~= "" and cover and not seen[detail] then
            seen[detail] = true
            cards[#cards + 1] = Models.card{
                site_id = self.id, comic_id = detail, detail_url = detail,
                title = title, cover_url = cover, cover_headers = self:image_headers(cover),
            }
        end
    end
    if #cards == 0 then return self:_result_error("list", "parse_error") end
    return cards
end

function Custom:parse_detail(body, comic_id)
    local value, error_result = checked(self, body, "detail")
    if not value then return error_result end
    local rules = self.rules
    local title = Base.text(captured(value, rules.detail_title))
    local cover = Base.absolute(comic_id, captured(value, rules.detail_cover))
    if title == "" or not cover then return self:_result_error("detail", "parse_error") end
    local chapters = {}
    if rules.chapter_block ~= "" then
        local blocks = matches(value, rules.chapter_block, MAX_CHAPTERS)
        if not blocks then return self:_result_error("detail", "parse_error") end
        for _, block in ipairs(blocks) do
            local url = self:_html_url(captured(block, rules.chapter_href), comic_id)
            local name = Base.text(captured(block, rules.chapter_title))
            if url and name ~= "" then
                chapters[#chapters + 1] = { id = url, title = name }
            end
        end
        if #chapters == 0 then return self:_result_error("detail", "parse_error") end
    else
        chapters[1] = { id = comic_id, title = "默认章节" }
    end
    return Models.detail{
        card = Models.card{ site_id = self.id, comic_id = comic_id,
            detail_url = comic_id, title = title, cover_url = cover,
            cover_headers = self:image_headers(cover), page_count = #chapters },
        description = Base.text(captured(value, rules.detail_description)),
        chapters = chapters,
    }
end

function Custom:parse_pages(body, comic_id, page_url)
    local value, error_result = checked(self, body, "pages")
    if not value then return error_result end
    if self.rules.page_block ~= "" then
        local blocks = matches(value, self.rules.page_block, 1)
        if not blocks or #blocks == 0 then return self:_result_error("pages", "parse_error") end
        value = blocks[1]
    end
    local images = matches(value, self.rules.page_image, MAX_PAGES)
    if not images then return self:_result_error("pages", "parse_error") end
    local pages = {}
    for _, raw in ipairs(images) do
        raw = raw:gsub("\\/", "/"):gsub("\\u002[fF]", "/")
            :gsub("\\u003[aA]", ":")
        local url = Base.absolute(page_url, raw)
        if url and url:match("^https://") then
            pages[#pages + 1] = { url = url, headers = self:image_headers(url) }
        end
    end
    pages = Base.unique_pages(pages)
    if #pages == 0 then return self:_result_error("pages", "parse_error") end
    return Models.pages{ site_id = self.id, comic_id = comic_id, pages = pages }
end

function Custom:list(options, callback)
    options, callback = options or {}, callback or {}
    local query = tostring(options.query or "")
    local path = query ~= "" and self.rules.search_path or self.rules.list_path
    if path == "" then return callback.on_error(self:_result_error("list", "parse_error")) end
    local url = self:_template(path, options)
    if not url then return callback.on_error(self:_result_error("list", "parse_error")) end
    return self:_get(url, "list", {
        on_success = function(body)
            local cards = self:parse_list(body, url)
            if cards.code then return callback.on_error(cards) end
            local _, total = Base.pagination(body)
            return callback.on_success{ cards = cards, page = tonumber(options.page) or 1,
                total_pages = total }
        end,
        on_error = callback.on_error,
    })
end

function Custom:detail(comic_id, callback)
    callback = callback or {}
    local url = self:_html_url(comic_id, self.origin)
    if not url then return callback.on_error(self:_result_error("detail", "parse_error")) end
    return self:_get(url, "detail", {
        on_success = function(body)
            local result = self:parse_detail(body, url)
            if result.code then return callback.on_error(result) end
            return callback.on_success(result)
        end,
        on_error = callback.on_error,
    })
end

function Custom:pages(comic_id, chapter_id, callback)
    callback = callback or {}
    local target = chapter_id or comic_id
    if self.rules.reader_path ~= "" and tostring(target) == tostring(comic_id) then
        local id = captured(comic_id, self.rules.comic_id_pattern)
        if not id or id == "" then
            return callback.on_error(self:_result_error("pages", "parse_error"))
        end
        target = self.rules.reader_path:gsub("{id}", function() return Base.url_encode(id) end)
    end
    local url = self:_html_url(target, self.origin)
    if not url then return callback.on_error(self:_result_error("pages", "parse_error")) end
    return self:_get(url, "pages", {
        on_success = function(body)
            local result = self:parse_pages(body, comic_id, url)
            if result.code then return callback.on_error(result) end
            return callback.on_success(result)
        end,
        on_error = callback.on_error,
    })
end

function Custom:test_connection(callback)
    return self:list({ page = 1 }, callback)
end

return Custom
