local Settings = {}
Settings.__index = Settings
local Presets = require("mangaweb.filter_presets")

local READER_DEFAULTS = {
    preload_pages = 3, direction = "ltr", fit_mode = "page",
    split_enabled = false, split_min_ratio = 1.20, split_max_ratio = 2.20,
    split_cut_percent = 50, split_first_segment = "auto",
    gray_enabled = false, gray_preset = "original",
    tone_enabled = false, tone_preset = "original",
    gray_custom_presets = {}, tone_custom_presets = {},
    cache_upper_mb = 256, cache_lower_mb = 192,
    graydither_enabled = false, graydither_refresh_enabled = false,
    graydither_refresh_interval = 5, graydither_refresh_mode = "native",
    graydither_refresh_hold = 0.30,
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
    if not Presets.valid_list("gray", values.gray_custom_presets) then return "invalid_gray_preset" end
    if not Presets.find("gray", values.gray_preset, values.gray_custom_presets) then
        return "invalid_gray_preset"
    end
    if type(values.tone_enabled) ~= "boolean" then return "invalid_tone_enabled" end
    if not Presets.valid_list("tone", values.tone_custom_presets) then return "invalid_tone_preset" end
    if not Presets.find("tone", values.tone_preset, values.tone_custom_presets) then
        return "invalid_tone_preset"
    end
    if not is_integer(values.cache_upper_mb) or values.cache_upper_mb < 64
        or values.cache_upper_mb > 2048 then return "invalid_cache_upper_mb" end
    if not is_integer(values.cache_lower_mb) or values.cache_lower_mb < 0
        or values.cache_lower_mb >= values.cache_upper_mb then return "invalid_cache_lower_mb" end
    if type(values.graydither_enabled) ~= "boolean" then return "invalid_graydither_enabled" end
    if type(values.graydither_refresh_enabled) ~= "boolean" then return "invalid_graydither_refresh_enabled" end
    if not is_integer(values.graydither_refresh_interval) or values.graydither_refresh_interval < 1
        or values.graydither_refresh_interval > 50 then return "invalid_graydither_refresh_interval" end
    if not one_of(values.graydither_refresh_mode, { native = true, flash = true }) then
        return "invalid_graydither_refresh_mode"
    end
    if type(values.graydither_refresh_hold) ~= "number" or values.graydither_refresh_hold ~= values.graydither_refresh_hold
        or values.graydither_refresh_hold < 0.10 or values.graydither_refresh_hold > 1.00 then
        return "invalid_graydither_refresh_hold"
    end
end

local function normalize_reader(values, strict)
    if strict then
        local reason = invalid_reader_field(values)
        if reason then return nil, reason end
    end
    local normalized = {
        gray_custom_presets = Presets.sanitize("gray", type(values) == "table" and values.gray_custom_presets),
        tone_custom_presets = Presets.sanitize("tone", type(values) == "table" and values.tone_custom_presets),
    }
    for key, default in pairs(READER_DEFAULTS) do
        if key ~= "gray_custom_presets" and key ~= "tone_custom_presets" then
            local candidate = type(values) == "table" and values[key]
            local probe = {}
            for field, fallback in pairs(READER_DEFAULTS) do
                if field == key then probe[field] = candidate else probe[field] = fallback end
            end
            probe.gray_custom_presets = normalized.gray_custom_presets
            probe.tone_custom_presets = normalized.tone_custom_presets
            local invalid = invalid_reader_field(probe)
            if key == "cache_upper_mb" then
                invalid = not is_integer(candidate) or candidate < 64 or candidate > 2048
            elseif key == "cache_lower_mb" then
                invalid = not is_integer(candidate) or candidate < 0 or candidate >= 2048
            end
            normalized[key] = invalid and default or candidate
        end
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

-- The shared plugin sees only this reader's preferences. Reuse the existing
-- validated save/flush/rollback path without reprocessing downloaded images.
function Settings:graydither_store()
    local settings = self
    local function supported(key)
        return type(key) == "string" and key:match("^graydither_")
            and READER_DEFAULTS[key] ~= nil
    end
    local store = {}
    function store:readSetting(key, fallback)
        if not supported(key) then return fallback end
        return settings:reader_settings()[key]
    end
    function store:saveSetting(key, value)
        assert(supported(key), "invalid_graydither_setting")
        local values = settings:reader_settings()
        values[key] = value
        local saved, reason = settings:save_reader_settings(values)
        -- The shared preferences use the host LuaSettings convention: failed
        -- persistence throws, while nil or true may denote a successful write.
        if not saved then error(reason or "settings_save_failed") end
        return true
    end
    function store:delSetting(key)
        assert(supported(key), "invalid_graydither_setting")
        return self:saveSetting(key, READER_DEFAULTS[key])
    end
    return store
end

return Settings
