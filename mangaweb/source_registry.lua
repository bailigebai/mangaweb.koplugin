local Registry = {}
Registry.__index = Registry

local function copy_state(state)
    local result = {}
    for key, value in pairs(state or {}) do result[key] = value end
    return result
end

local function ordered_ids(sources)
    local ids = {}
    for id in pairs(sources) do ids[#ids + 1] = id end
    table.sort(ids, function(first, second)
        if first == "zero" then return true end
        if second == "zero" then return false end
        local a, b = tonumber(first:match("^custom%-(%d+)$")),
            tonumber(second:match("^custom%-(%d+)$"))
        if a and b then return a < b end
        return first < second
    end)
    return ids
end

local function default_state()
    return { page = 1, query = "", category = nil, tag = nil, sort = "updated" }
end

function Registry:new(options)
    options = options or {}
    local sources = assert(options.sources, "sources are required")
    local ids = ordered_ids(sources)
    local settings = options.settings or {}
    local default_site = sources.zero and "zero" or ids[1]
    local read = settings.read or settings.readSetting
    local persisted_active_site = type(read) == "function"
        and read(settings, "active_site", nil) or nil
    local active = persisted_active_site or default_site
    if not sources[active] then active = ids[1] end
    local states = {}
    for _, id in ipairs(ids) do
        states[id] = default_state()
    end
    return setmetatable({
        sources = sources,
        ids_list = ids,
        active_id = active,
        persisted_active_site = persisted_active_site,
        states = states,
        settings = settings,
    }, self)
end

function Registry:ids()
    local result = {}
    for index, id in ipairs(self.ids_list) do result[index] = id end
    return result
end

function Registry:current()
    return self.sources[self.active_id]
end

function Registry:current_id()
    return self.active_id
end

function Registry:has_saved_active_site()
    return type(self.persisted_active_site) == "string" and self.sources[self.persisted_active_site] ~= nil
end

function Registry:state(site_id)
    return self.states[site_id]
end

function Registry:register(site_id, source)
    if type(site_id) ~= "string" or site_id == "" or type(source) ~= "table" then
        return false, "invalid_site"
    end
    self.sources[site_id] = source
    self.states[site_id] = self.states[site_id] or default_state()
    self.ids_list = ordered_ids(self.sources)
    return true
end

function Registry:remove(site_id)
    if site_id == "zero" or not self.sources[site_id] then return false, "unknown_site" end
    self.sources[site_id], self.states[site_id] = nil, nil
    self.ids_list = ordered_ids(self.sources)
    if self.active_id == site_id then
        return self:switch(self.sources.zero and "zero" or self.ids_list[1]) ~= nil
    end
    return true
end

function Registry:reset_state(site_id)
    if not self.sources[site_id] then return false, "unknown_site" end
    self.states[site_id] = default_state()
    return true
end

function Registry:switch(site_id)
    if not self.sources[site_id] then return nil, "unknown_site" end
    self.active_id = site_id
    self.persisted_active_site = site_id
    local write = self.settings.write or self.settings.saveSetting
    if type(write) == "function" then
        write(self.settings, "active_site", site_id)
        if type(self.settings.flush) == "function" then self.settings:flush() end
    end
    return self.sources[site_id]
end

return Registry
