local Settings = {}
Settings.__index = Settings

local READER_DEFAULTS = {
    preload_pages = 3, direction = "ltr", fit_mode = "page",
    split_enabled = false, split_min_ratio = 1.20, split_max_ratio = 2.20,
    split_cut_percent = 50, split_first_segment = "auto",
    gray_enabled = false, gray_preset = "original",
    tone_enabled = false, tone_preset = "original",
    cache_upper_mb = 256, cache_lower_mb = 192,
}

local function is_integer(value)
    return type(value) == "number" and value == math.floor(value)
end

local function one_of(value, choices)
    return choices[value] == true
end

local function invalid_reader_field(values)
    if type(values) ~= "table" then return "invalid_reader_settings" end
    if not is_integer(values.preload_pages) or values.preload_pages < 0 or values.preload_pages > 10 then
        return "invalid_preload_pages"
    end
    if not one_of(values.direction, { ltr = true, rtl = true }) then return "invalid_direction" end
    if not one_of(values.fit_mode, { page = true, width = true }) then return "invalid_fit_mode" end
    if type(values.split_enabled) ~= "boolean" then return "invalid_split_enabled" end
    if type(values.split_min_ratio) ~= "number" or values.split_min_ratio < 1 or values.split_min_ratio > 4 then
        return "invalid_split_min_ratio"
    end
    if type(values.split_max_ratio) ~= "number" or values.split_max_ratio < 1 or values.split_max_ratio > 4 then
        return "invalid_split_max_ratio"
    end
    if values.split_min_ratio > values.split_max_ratio then return "invalid_split_ratio_range" end
    if not is_integer(values.split_cut_percent) or values.split_cut_percent < 10 or values.split_cut_percent > 90 then
        return "invalid_split_cut_percent"
    end
    if not one_of(values.split_first_segment, { auto = true, left = true, right = true }) then
        return "invalid_split_first_segment"
    end
    if type(values.gray_enabled) ~= "boolean" then return "invalid_gray_enabled" end
    if not one_of(values.gray_preset, { original = true, clear = true, strong = true }) then
        return "invalid_gray_preset"
    end
    if type(values.tone_enabled) ~= "boolean" then return "invalid_tone_enabled" end
    if not one_of(values.tone_preset, { original = true, bright = true, contrast = true }) then
        return "invalid_tone_preset"
    end
    if not is_integer(values.cache_upper_mb) or values.cache_upper_mb < 64
        or values.cache_upper_mb > 2048 then return "invalid_cache_upper_mb" end
    if not is_integer(values.cache_lower_mb) or values.cache_lower_mb < 0
        or values.cache_lower_mb >= values.cache_upper_mb then return "invalid_cache_lower_mb" end
end

local function normalize_reader(values, strict)
    if strict then
        local reason = invalid_reader_field(values)
        if reason then return nil, reason end
    end
    local normalized = {}
    for key, default in pairs(READER_DEFAULTS) do
        local candidate = type(values) == "table" and values[key]
        local probe = {}
        for field, fallback in pairs(READER_DEFAULTS) do
            if field == key then probe[field] = candidate else probe[field] = fallback end
        end
        local invalid = invalid_reader_field(probe)
        if key == "cache_upper_mb" then
            invalid = not is_integer(candidate) or candidate < 64 or candidate > 2048
        elseif key == "cache_lower_mb" then
            invalid = not is_integer(candidate) or candidate < 0 or candidate >= 2048
        end
        normalized[key] = invalid and default or candidate
    end
    if normalized.split_min_ratio > normalized.split_max_ratio then
        normalized.split_min_ratio = READER_DEFAULTS.split_min_ratio
        normalized.split_max_ratio = READER_DEFAULTS.split_max_ratio
    end
    if normalized.cache_lower_mb >= normalized.cache_upper_mb then
        normalized.cache_lower_mb = math.max(0, normalized.cache_upper_mb - 64)
    end
    return normalized
end

function Settings:new(options)
    options = options or {}
    local store = options.store
    if not store then
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        local path = options.path or (DataStorage:getSettingsDir() .. "/mangaweb.lua")
        store = LuaSettings:open(path)
    end
    return setmetatable({ store = store }, self)
end

function Settings:read(key, fallback)
    return self.store:readSetting(key, fallback)
end

function Settings:write(key, value)
    return self.store:saveSetting(key, value)
end

function Settings:active_site()
    return self:read("active_site", "zero")
end

function Settings:set_active_site(site_id)
    self:write("active_site", site_id)
end

function Settings:site_filters(site_id)
    return self:read("filters:" .. tostring(site_id), {
        page = 1, query = "", category = nil, tag = nil, sort = "updated",
    })
end

function Settings:set_site_filters(site_id, filters)
    self:write("filters:" .. tostring(site_id), filters or {})
end

function Settings:flush()
    if self.store.flush then return self.store:flush() end
    return true
end

function Settings:reader_settings()
    return assert(normalize_reader(self:read("reader", READER_DEFAULTS), false))
end

function Settings:save_reader_settings(values)
    local normalized, reason = normalize_reader(values, true)
    if not normalized then return false, reason end
    local previous = self:read("reader", READER_DEFAULTS)
    local wrote, result = pcall(self.store.saveSetting, self.store, "reader", normalized)
    if not wrote or result == false then
        pcall(self.store.saveSetting, self.store, "reader", previous)
        pcall(self.flush, self)
        return false, "settings_save_failed"
    end
    local flushed, flush_result = pcall(self.flush, self)
    if flushed and flush_result ~= false then return true end
    pcall(self.store.saveSetting, self.store, "reader", previous)
    pcall(self.flush, self)
    return false, "settings_flush_failed"
end

return Settings
