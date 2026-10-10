local PageCache = require("mangaweb.page_cache")
local Catalogue = {}
Catalogue.__index = Catalogue
local MAX_BYTES = 512 * 1024
local FIELDS = { "site_id", "comic_id", "title", "author", "cover_url", "detail_url" }

local function field(value)
    value = tostring(value or "")
    return #value .. ":" .. value
end

local function valid_key(key)
    return type(key) == "string" and #key == 64 and key:match("^[0-9a-f]+$")
end

local function integer(value, fallback, minimum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return math.max(minimum, math.floor(value))
end

local function clean(result)
    if type(result) ~= "table" or type(result.cards) ~= "table" then return nil end
    local cards = {}
    for _, item in ipairs(result.cards) do
        if #cards >= 250 then return nil end
        if type(item) ~= "table" then return nil end
        local card = { tags = {} }
        for _, name in ipairs(FIELDS) do
            local value = item[name]
            if value ~= nil then
                if type(value) ~= "string" or #value > 4096 then return nil end
                card[name] = value
            end
        end
        if not card.comic_id or not card.site_id then return nil end
        if card.cover_url and card.cover_url ~= "" and not card.cover_url:match("^https?://") then return nil end
        for i, tag in ipairs(type(item.tags) == "table" and item.tags or {}) do
            if i > 30 then break end
            if type(tag) == "string" and #tag <= 256 then card.tags[#card.tags + 1] = tag end
        end
        card.page_count = integer(item.page_count, 0, 0)
        cards[#cards + 1] = card
    end
    return { cards = cards, page = integer(result.page, 1, 1),
        total_pages = integer(result.total_pages, 1, 1), total_count = integer(result.total_count, nil, 0) }
end

function Catalogue:new(options)
    options = options or {}
    local storage = options.storage or PageCache:new{ directory = "catalogues" }
    local json = options.json
    if not json then local ok, value = pcall(require, "rapidjson"); if ok then json = value end end
    if not storage or not json then return nil end
    local listed, entries = pcall(storage.fs.list, storage.fs, storage.root)
    for _, entry in ipairs(listed and entries or {}) do
        local key = entry.name:match("^([0-9a-f]+)%.json%.part$")
        if entry.mode == "file" and valid_key(key) then
            pcall(storage.fs.remove, storage.fs, storage.root .. "/" .. entry.name)
        end
    end
    return setmetatable({ storage = storage, json = json,
        max_entries = options.max_entries or 16 }, self)
end

function Catalogue:key(source, request, kind)
    local cookie, auth = "", source.auth
    if auth then
        local method = auth.active_cookie or auth.cookie
        if type(method) == "function" then
            local ok, value = pcall(method, auth, source.id)
            if not ok then return nil end
            cookie = value or ""
        end
    end
    local parts = { field(source.id), field(source.origin), field(kind), field(cookie) }
    for _, name in ipairs{ "page", "query", "category", "tag", "sort" } do
        parts[#parts + 1] = field((request or {})[name])
    end
    local ok, key = pcall(self.storage.sha256, table.concat(parts))
    return ok and valid_key(key) and key or nil
end

function Catalogue:invalidate(key)
    if valid_key(key) then pcall(self.storage.fs.remove, self.storage.fs, self.storage.root .. "/" .. key .. ".json") end
end

function Catalogue:get(key)
    if not valid_key(key) then return nil end
    local ok, body = pcall(self.storage.fs.read, self.storage.fs, self.storage.root .. "/" .. key .. ".json", MAX_BYTES + 1)
    if not ok or type(body) ~= "string" then return nil end
    local decoded, value
    if #body <= MAX_BYTES then decoded, value = pcall(self.json.decode, body) end
    local sanitized = decoded and clean(value)
    if not sanitized then self:invalidate(key) end
    return sanitized
end

function Catalogue:put(key, result)
    if not valid_key(key) then return false end
    local value = clean(result)
    if not value then return false end
    local encoded, body = pcall(self.json.encode, value)
    if not encoded or type(body) ~= "string" or #body > MAX_BYTES then return false end
    local storage = self.storage
    if not storage:_ensure_dir() then return false end
    local path = storage.root .. "/" .. key .. ".json"
    local temporary = path .. ".part"
    local ok, wrote = pcall(storage.fs.write, storage.fs, temporary, body)
    if not ok or wrote ~= true then pcall(storage.fs.remove, storage.fs, temporary); return false end
    local renamed, success = pcall(storage.fs.rename, storage.fs, temporary, path)
    if not renamed or success ~= true then pcall(storage.fs.remove, storage.fs, temporary); return false end
    local listed, entries = pcall(storage.fs.list, storage.fs, storage.root)
    local snapshots = {}
    for _, entry in ipairs(listed and entries or {}) do
        local digest = entry.name:match("^([0-9a-f]+)%.json$")
        if entry.mode == "file" and valid_key(digest) then snapshots[#snapshots + 1] = entry end
    end
    table.sort(snapshots, function(a, b)
        if a.name == key .. ".json" then return false end
        if b.name == key .. ".json" then return true end
        if a.mtime ~= b.mtime then return a.mtime < b.mtime end
        return a.name < b.name
    end)
    for i = 1, #snapshots - self.max_entries do
        pcall(storage.fs.remove, storage.fs, storage.root .. "/" .. snapshots[i].name)
    end
    return true
end

return Catalogue
