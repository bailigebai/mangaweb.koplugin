-- Short, bounded session snapshots avoid another HTML round trip on return.
-- Nothing here is written to disk; the key uses the current source and login.
local Catalogue = require("mangaweb.catalogue_cache")
local Crypto = require("mangaweb.license_crypto")
local Cache = {}
Cache.__index = Cache

local function copy(value, budget, depth)
    if depth > 16 then return nil, false end
    local kind = type(value)
    if kind == "string" then
        budget.bytes = budget.bytes - #value
        return value, budget.bytes >= 0
    end
    if kind == "number" then return value, value == value and math.abs(value) ~= math.huge end
    if kind == "boolean" then return value, true end
    if kind ~= "table" then return nil, false end
    local result = {}
    for key, item in pairs(value) do
        budget.nodes = budget.nodes - 1
        if budget.nodes < 0 or (type(key) ~= "string" and type(key) ~= "number") then return nil, false end
        if type(key) == "string" then budget.bytes = budget.bytes - #key end
        local cloned, ok = copy(item, budget, depth + 1)
        if not ok then return nil, false end
        result[key] = cloned
    end
    return result, budget.bytes >= 0
end

local function snapshot(value)
    return copy(value, {bytes=512*1024,nodes=10000}, 0)
end

function Cache:new(options)
    options = options or {}
    return setmetatable({ entries = {}, serial = 0, ttl = options.ttl or 60,
        max_entries = options.max_entries or 16, clock = options.clock or os.time,
        keyer = options.keyer or { storage = {sha256=Crypto.sha256}, key = Catalogue.key } }, self)
end

function Cache:key(source, comic, chapter, kind)
    if not source then return nil end
    local ok, key = pcall(self.keyer.key, self.keyer, source,
        {query=comic,category=chapter}, "detail-session:" .. kind)
    return ok and key and (tostring(source) .. ":" .. key) or nil
end

function Cache:get(source, comic, chapter, kind)
    local key = self:key(source, comic, chapter, kind)
    local entry = key and self.entries[key]
    if not entry then return nil end
    if self.clock() - entry.time >= self.ttl then self.entries[key] = nil; return nil end
    return snapshot(entry.value)
end

function Cache:invalidate(source, comic, chapter, kind)
    local key = self:key(source, comic, chapter, kind)
    if key then self.entries[key] = nil end
end

function Cache:put(source, comic, chapter, kind, value, expected_key)
    local key = self:key(source, comic, chapter, kind)
    if not key or (expected_key and key ~= expected_key) then return false end
    local cloned, valid = snapshot(value)
    if not valid then return false end
    self.serial = self.serial + 1
    self.entries[key] = {value=cloned,time=self.clock(),order=self.serial}
    local count, oldest, order = 0, nil, math.huge
    for name, entry in pairs(self.entries) do
        count = count + 1
        if entry.order < order then oldest, order = name, entry.order end
    end
    if count > self.max_entries then self.entries[oldest] = nil end
    return true
end

function Cache:clear() self.entries = {} end
return Cache
