local Definitions = {}
Definitions.__index = Definitions

Definitions.DEFAULT_ZERO_ORIGIN = "https://www.zerobyw33.com"
Definitions.RULE_FIELDS = {
    "list_path", "search_path", "list_block", "list_href", "list_title", "list_cover",
    "detail_title", "detail_cover", "detail_description", "chapter_block",
    "chapter_href", "chapter_title", "comic_id_pattern", "reader_path",
    "page_block", "page_image",
}

local REQUIRED = {
    list_path = true, list_block = true, list_href = true, list_title = true,
    list_cover = true, detail_title = true, detail_cover = true, page_image = true,
}
local PATHS = { list_path = true, search_path = true, reader_path = true }
local BLOCKS = { list_block = true, chapter_block = true, page_block = true }

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function has_capture(pattern)
    local index = 1
    while index <= #pattern do
        local character = pattern:sub(index, index)
        if character == "%" then index = index + 2
        elseif character == "(" then return true
        else index = index + 1 end
    end
    return false
end

function Definitions.validate_origin(value)
    value = trim(value)
    if #value > 255 or value:find("[%c%s\\]") then return nil, "invalid_origin" end
    if value:sub(1, 8):lower() ~= "https://" then return nil, "https_required" end
    local authority = value:sub(9):gsub("/$", "")
    if authority == "" or authority:find("[/%?#@]") then return nil, "invalid_origin" end
    local host, port = authority:match("^([%w%.%-]+):(%d+)$")
    if not host then host = authority end
    host = host:lower()
    if not host:match("^[%w%.%-]+$") or not host:find("%.")
        or host:find("%.%.") or host:match("^%.") or host:match("%.$")
        or host:match("^%d+%.%d+%.%d+%.%d+$") then return nil, "invalid_origin" end
    for label in host:gmatch("[^%.]+") do
        if label:match("^%-") or label:match("%-$") then return nil, "invalid_origin" end
    end
    if port and (tonumber(port) < 1 or tonumber(port) > 65535) then
        return nil, "invalid_origin"
    end
    return "https://" .. host .. (port and ":" .. port or "")
end

local function validate_rule(name, value)
    value = trim(value)
    if value == "" then
        if REQUIRED[name] then return nil, "missing_" .. name end
        return ""
    end
    if #value > 512 or value:find("[%c]") then return nil, "invalid_" .. name end
    if PATHS[name] then
        if value:sub(1, 1) ~= "/" or value:sub(1, 2) == "//"
            or value:find("://", 1, true) or value:find("\\", 1, true)
            or value:find("#", 1, true) then return nil, "invalid_" .. name end
        if name == "search_path" and not value:find("{query}", 1, true) then
            return nil, "missing_query_placeholder"
        end
        if name == "reader_path" and not value:find("{id}", 1, true) then
            return nil, "missing_id_placeholder"
        end
        return value
    end
    local valid = pcall(string.match, "example", value)
    if not valid then return nil, "invalid_" .. name end
    local matched = string.find("", value)
    if matched then return nil, "empty_match_" .. name end
    if not BLOCKS[name] and not has_capture(value) then
        return nil, "missing_capture_" .. name
    end
    return value
end

function Definitions.validate(definition)
    if type(definition) ~= "table" or type(definition.rules) ~= "table" then
        return nil, "invalid_definition"
    end
    local name = trim(definition.name)
    if name == "" or #name > 64 or name:find("[%c]") then return nil, "invalid_name" end
    local origin, origin_error = Definitions.validate_origin(definition.origin)
    if not origin then return nil, origin_error end
    local rules = {}
    for _, field in ipairs(Definitions.RULE_FIELDS) do
        local value, reason = validate_rule(field, definition.rules[field])
        if value == nil then return nil, reason end
        rules[field] = value
    end
    local chapters = rules.chapter_block ~= "" or rules.chapter_href ~= ""
        or rules.chapter_title ~= ""
    if chapters and (rules.chapter_block == "" or rules.chapter_href == ""
        or rules.chapter_title == "") then return nil, "incomplete_chapter_rules" end
    if rules.reader_path ~= "" and rules.comic_id_pattern == "" then
        return nil, "missing_comic_id_pattern"
    end
    return { name = name, origin = origin, rules = rules }
end

function Definitions:new(options)
    options = options or {}
    local settings = assert(options.settings, "settings is required")
    local raw = settings:read("site_definitions", {})
    if type(raw) ~= "table" then raw = {} end
    local config = {
        next_id = math.max(1, math.floor(tonumber(raw.next_id) or 1)),
        zero_origin = Definitions.validate_origin(raw.zero_origin)
            or Definitions.DEFAULT_ZERO_ORIGIN,
        sites = {},
    }
    for _, site in ipairs(type(raw.sites) == "table" and raw.sites or {}) do
        local valid = Definitions.validate(site)
        local number = type(site.id) == "string" and tonumber(site.id:match("^custom%-(%d+)$"))
        if valid and number and number >= 1 then
            valid.id = "custom-" .. tostring(number)
            config.sites[#config.sites + 1] = valid
            config.next_id = math.max(config.next_id, number + 1)
        end
    end
    return setmetatable({ settings = settings, config = config }, self)
end

function Definitions:_commit(candidate)
    local previous = copy(self.config)
    local wrote, result = pcall(self.settings.write, self.settings,
        "site_definitions", copy(candidate))
    if not wrote or result == false then
        pcall(self.settings.write, self.settings, "site_definitions", previous)
        return false, "settings_save_failed"
    end
    local flushed, saved = true, true
    if type(self.settings.flush) == "function" then
        flushed, saved = pcall(self.settings.flush, self.settings)
    end
    if not flushed or saved == false then
        pcall(self.settings.write, self.settings, "site_definitions", previous)
        if type(self.settings.flush) == "function" then
            pcall(self.settings.flush, self.settings)
        end
        return false, "settings_flush_failed"
    end
    self.config = candidate
    return true
end

function Definitions:list() return copy(self.config.sites) end
function Definitions:zero_origin() return self.config.zero_origin end

function Definitions:set_zero_origin(origin)
    local normalized, reason = Definitions.validate_origin(origin)
    if not normalized then return false, reason end
    local next_config = copy(self.config)
    next_config.zero_origin = normalized
    return self:_commit(next_config)
end

function Definitions:add(definition)
    local valid, reason = Definitions.validate(definition)
    if not valid then return nil, reason end
    local next_config = copy(self.config)
    valid.id = "custom-" .. tostring(next_config.next_id)
    next_config.next_id = next_config.next_id + 1
    next_config.sites[#next_config.sites + 1] = valid
    local saved, error_code = self:_commit(next_config)
    if not saved then return nil, error_code end
    return copy(valid)
end

function Definitions:update(id, definition)
    local valid, reason = Definitions.validate(definition)
    if not valid then return nil, reason end
    local next_config = copy(self.config)
    for index, site in ipairs(next_config.sites) do
        if site.id == id then
            valid.id = id
            next_config.sites[index] = valid
            local saved, error_code = self:_commit(next_config)
            if not saved then return nil, error_code end
            return copy(valid)
        end
    end
    return nil, "unknown_site"
end

function Definitions:remove(id)
    local next_config = copy(self.config)
    for index, site in ipairs(next_config.sites) do
        if site.id == id then
            table.remove(next_config.sites, index)
            return self:_commit(next_config)
        end
    end
    return false, "unknown_site"
end

return Definitions
