local Crypto = require("mangaweb.license_crypto")

local PageCache = {}
PageCache.__index = PageCache

local EXTENSIONS = { jpg = true, png = true, webp = true, gif = true }
local MAX_IMAGE_BYTES = 64 * 1048576

local function image_kind(body)
    if type(body) ~= "string" or #body < 12 then return nil end
    if body:sub(1, 3) == "\255\216\255" then return "jpg" end
    if body:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if body:sub(1, 6) == "GIF87a" or body:sub(1, 6) == "GIF89a" then return "gif" end
    if body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP" then return "webp" end
end

PageCache.image_kind = image_kind

local function runtime_root(directory)
    local source = debug.getinfo(1, "S").source
    local plugin = type(source) == "string" and source:sub(1, 1) == "@"
        and source:sub(2):match("^(.*)[/\\]mangaweb[/\\]page_cache%.lua$")
    return plugin and (plugin:gsub("\\", "/") .. "/cache/" .. directory) or nil
end

local function default_fs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    if not ok or not lfs then return nil end
    local fs = {}
    function fs:mkdir(path)
        if lfs.attributes(path, "mode") == "directory" then return true end
        local created = lfs.mkdir(path)
        return created == true or lfs.attributes(path, "mode") == "directory"
    end
    function fs:read(path, limit)
        local handle = io.open(path, "rb")
        if not handle then return nil end
        local body = handle:read(limit)
        handle:close()
        return body
    end
    function fs:write(path, body)
        local handle = io.open(path, "wb")
        if not handle then return false end
        local written = handle:write(body)
        local closed = handle:close()
        return written ~= nil and closed ~= nil
    end
    function fs:size(path) return lfs.attributes(path, "size") end
    function fs:rename(source, target) return os.rename(source, target) ~= nil end
    function fs:remove(path) return os.remove(path) ~= nil end
    function fs:list(root)
        local entries = {}
        local success, iterator, state = pcall(lfs.dir, root)
        if not success then return entries end
        for name in iterator, state do
            local attrs = lfs.symlinkattributes and lfs.symlinkattributes(root .. "/" .. name)
                or lfs.attributes(root .. "/" .. name)
            if attrs and attrs.mode == "file" then
                entries[#entries + 1] = { name = name, size = attrs.size or 0,
                    mtime = attrs.modification or 0, mode = attrs.mode }
            end
        end
        return entries
    end
    return fs
end

local function digest(sha, value)
    local ok, hash = pcall(sha, value)
    return ok and type(hash) == "string" and #hash == 64
        and hash:match("^[0-9a-f]+$") and hash or nil
end

local function field(value)
    value = tostring(value or "")
    return tostring(#value) .. ":" .. value
end

function PageCache:new(options)
    options = options or {}
    local directory = ({ covers = true, catalogues = true })[options.directory] and options.directory or "pages"
    local root = options.root or runtime_root(directory)
    if type(root) ~= "string" or root == "" then return nil end
    root = root:gsub("\\", "/"):gsub("/+$", "")
    local fs = options.fs or default_fs()
    if not fs then return nil end
    local object = setmetatable({ root = root, fs = fs,
        sha256 = options.sha256 or Crypto.sha256,
        upper_bytes = options.upper_bytes or 256 * 1048576,
        lower_bytes = options.lower_bytes or 192 * 1048576,
        pins = {}, current = nil, serial = 0, reservations = {},
    }, self)
    object:_cleanup_parts()
    return object
end

function PageCache:_cleanup_parts()
    local ok, entries = pcall(self.fs.list, self.fs, self.root)
    if not ok or type(entries) ~= "table" then return end
    for _, entry in ipairs(entries) do
        local name = type(entry) == "table" and entry.name
        local prefix, number, hash, extension, stamp, serial
        if type(name) == "string" then
            prefix, number, hash, extension, stamp, serial = name:match(
                "^([0-9a-f]+)_([0-9]+)_([0-9a-f]+)%.(%a+)%.(%d+)%.(%d+)%.part$")
        end
        if entry.mode == "file" and prefix and #prefix == 16
            and #number == 8 and #hash == 64 and EXTENSIONS[extension]
            and stamp and serial then
            pcall(self.fs.remove, self.fs, self.root .. "/" .. name)
        end
    end
end

function PageCache:_name(identity, extension)
    if type(identity) ~= "table" then return nil end
    local index = tonumber(identity.index)
    if not index or index < 1 or index ~= math.floor(index) or index > 99999999 then return nil end
    local chapter = field(identity.site_id) .. field(identity.comic_id)
        .. field(identity.chapter_id)
    local prefix = digest(self.sha256, chapter)
    local key = digest(self.sha256, chapter .. field(index) .. field(identity.url))
    if not prefix or not key then return nil end
    local stem = prefix:sub(1, 16) .. "_" .. string.format("%08d", index) .. "_" .. key
    return extension and (stem .. "." .. extension) or stem, prefix:sub(1, 16), index
end

function PageCache:_ensure_dir()
    local parent = self.root:match("^(.*)/pages$") or self.root:match("^(.*)/covers$")
        or self.root:match("^(.*)/catalogues$")
    if not parent then return false end
    local ok1, made1 = pcall(self.fs.mkdir, self.fs, parent)
    local ok2, made2 = pcall(self.fs.mkdir, self.fs, self.root)
    return ok1 and made1 == true and ok2 and made2 == true
end

local function marker(name)
    if type(name) ~= "string" then return end
    local owner, prefix, index, hash = name:match("^([0-9a-f]+)%.([0-9a-f]+)_([0-9]+)_([0-9a-f]+)%.keep$")
    if owner and #owner == 64 and #prefix == 16 and #index == 8 and #hash == 64 then
        return owner, prefix .. "_" .. index .. "_" .. hash
    end
end

function PageCache:sync_protected(owner, identities, replace)
    local scope = digest(self.sha256, owner)
    if not scope or not self:_ensure_dir() then return false end
    local ok, entries = pcall(self.fs.list, self.fs, self.root)
    if not ok or type(entries) ~= "table" then return false end
    local existing, wanted = {}, {}
    for _, entry in ipairs(entries) do
        local group, stem = marker(entry.name)
        if entry.mode == "file" and group == scope then existing[stem] = entry.name end
    end
    for _, identity in ipairs(identities or {}) do
        local stem = self:_name(identity)
        if not stem then return false end
        wanted[stem] = true
        if not existing[stem] then
            local wrote, success = pcall(self.fs.write, self.fs, self.root .. "/" .. scope .. "." .. stem .. ".keep", "")
            if not wrote or success ~= true then return false end
        end
    end
    if replace then
        for stem, name in pairs(existing) do
            if not wanted[stem] then pcall(self.fs.remove, self.fs, self.root .. "/" .. name) end
        end
    end
    self:trim()
    return true
end

function PageCache:_entries()
    local ok, entries = pcall(self.fs.list, self.fs, self.root)
    if not ok or type(entries) ~= "table" then return {} end
    local valid, protected = {}, {}
    for _, entry in ipairs(entries) do
        local name = type(entry) == "table" and entry.name
        local _, stem = marker(name)
        if entry.mode == "file" and stem then protected[stem] = true end
        local prefix, number, hash, extension
        if type(name) == "string" then
            prefix, number, hash, extension =
                name:match("^([0-9a-f]+)_([0-9]+)_([0-9a-f]+)%.(%a+)$")
        end
        if entry.mode == "file" and prefix and #prefix == 16 and #number == 8
            and #hash == 64 and EXTENSIONS[extension] then
            valid[#valid + 1] = { path = self.root .. "/" .. name,
                name = name, prefix = prefix, index = tonumber(number),
                size = tonumber(entry.size) or 0, mtime = tonumber(entry.mtime) or 0 }
        end
    end
    return valid, protected
end

function PageCache:size_bytes()
    local total = 0
    for _, entry in ipairs(self:_entries()) do total = total + entry.size end
    return total
end

function PageCache:configure(upper_bytes, lower_bytes)
    upper_bytes, lower_bytes = tonumber(upper_bytes), tonumber(lower_bytes)
    if not upper_bytes or not lower_bytes or upper_bytes < 64 * 1048576
        or upper_bytes > 2048 * 1048576 or lower_bytes < 0
        or lower_bytes >= upper_bytes then return false end
    self.upper_bytes, self.lower_bytes = upper_bytes, lower_bytes
    return self:trim()
end

function PageCache:get(identity)
    local stem = self:_name(identity)
    if not stem then return nil end
    for _, extension in ipairs{ "jpg", "png", "webp", "gif" } do
        local path = self.root .. "/" .. stem .. "." .. extension
        local ok, header = pcall(self.fs.read, self.fs, path, 12)
        if ok and type(header) == "string" then
            if image_kind(header) == extension then return path end
            pcall(self.fs.remove, self.fs, path)
        end
    end
end

function PageCache:invalidate(identity)
    local stem = self:_name(identity)
    if not stem then return false end
    for _, extension in ipairs{ "jpg", "png", "webp", "gif" } do
        local path = self.root .. "/" .. stem .. "." .. extension
        pcall(self.fs.remove, self.fs, path)
    end
    return true
end

function PageCache:pin(identity)
    local stem = self:_name(identity)
    if not stem then return false end
    self.pins[stem] = (self.pins[stem] or 0) + 1
    return true
end

function PageCache:unpin(identity)
    local stem = self:_name(identity)
    if not stem then return false end
    local count = self.pins[stem] or 0
    if count <= 1 then self.pins[stem] = nil else self.pins[stem] = count - 1 end
    -- Writes/configuration already measure usage. Releasing an ordinary cached
    -- thumbnail must not rescan every file and every protection marker.
    if self.needs_trim then self:trim() end
    return true
end

function PageCache:set_position(identity)
    local _, prefix, index = self:_name(identity)
    if prefix then self.current = { prefix = prefix, index = index } end
    return self:trim()
end

function PageCache:put(identity, body, extension)
    local kind = image_kind(body)
    if not kind or (extension and extension ~= kind) then return nil end
    local name = self:_name(identity, kind)
    if not name or not self:_ensure_dir() then return nil end
    local existing = self:get(identity)
    if existing then return existing end
    local path = self.root .. "/" .. name
    self.serial = self.serial + 1
    local temporary = path .. "." .. tostring(os.time()) .. "." .. self.serial .. ".part"
    local wrote, result = pcall(self.fs.write, self.fs, temporary, body)
    if not wrote or result ~= true then
        pcall(self.fs.remove, self.fs, temporary)
        return nil
    end
    local renamed, published = pcall(self.fs.rename, self.fs, temporary, path)
    if not renamed or published ~= true then
        pcall(self.fs.remove, self.fs, temporary)
        return nil
    end
    self:trim()
    return path
end

function PageCache:put_file(identity, source, limit)
    limit = tonumber(limit) or MAX_IMAGE_BYTES
    if limit < 12 or limit > MAX_IMAGE_BYTES then return nil end
    local ok, body = pcall(self.fs.read, self.fs, source, limit + 1)
    if not ok or type(body) ~= "string" or #body > limit then return nil end
    return self:put(identity, body)
end

function PageCache:reserve(identity)
    local stem = self:_name(identity)
    if not stem or not self:_ensure_dir() then return nil end
    self.serial = self.serial + 1
    local part = self.root .. "/" .. stem .. ".jpg."
        .. tostring(os.time()) .. "." .. tostring(self.serial) .. ".part"
    local opened, written = pcall(self.fs.write, self.fs, part, "")
    if not opened or written ~= true then
        pcall(self.fs.remove, self.fs, part)
        return nil
    end
    self.reservations[part] = stem
    return part
end

function PageCache:discard(part_path)
    if not self.reservations[part_path] then return false end
    self.reservations[part_path] = nil
    pcall(self.fs.remove, self.fs, part_path)
    return true
end

function PageCache:publish(identity, part_path, reported_bytes)
    local stem = self:_name(identity)
    if not stem or self.reservations[part_path] ~= stem then
        return nil, "invalid_part"
    end
    local size_ok, size = pcall(self.fs.size, self.fs, part_path)
    size = size_ok and tonumber(size) or nil
    local reported = tonumber(reported_bytes)
    if not size or size < 1 or not reported or reported ~= size then
        self:discard(part_path)
        return nil, "size_mismatch"
    end
    if size > MAX_IMAGE_BYTES then
        self:discard(part_path)
        return nil, "response_too_large"
    end
    local read_ok, header = pcall(self.fs.read, self.fs, part_path, 12)
    local kind = read_ok and image_kind(header) or nil
    if not kind then
        self:discard(part_path)
        return nil, "invalid_image"
    end
    local existing = self:get(identity)
    if existing then
        self:discard(part_path)
        return existing
    end
    local final = self.root .. "/" .. stem .. "." .. kind
    local renamed, success = pcall(self.fs.rename, self.fs, part_path, final)
    if not renamed or success ~= true then
        self:discard(part_path)
        return nil, "storage_error"
    end
    self.reservations[part_path] = nil
    self:trim()
    return final
end

function PageCache:trim()
    local entries, protected = self:_entries()
    protected = protected or {}
    local total = 0
    for _, entry in ipairs(entries) do total = total + entry.size end
    if total <= self.upper_bytes and not self.needs_trim then return true end
    local current = self.current
    local function rank(entry)
        if not current or entry.prefix ~= current.prefix then return 1 end
        if entry.index < current.index then return 0 end
        if entry.index > current.index then return 2 end
        return 3
    end
    table.sort(entries, function(a, b)
        local ar, br = rank(a), rank(b)
        if ar ~= br then return ar < br end
        if ar == 0 then return a.index < b.index end
        if ar == 2 then return a.index > b.index end
        if a.mtime ~= b.mtime then return a.mtime < b.mtime end
        return a.name < b.name
    end)
    for _, entry in ipairs(entries) do
        if total <= self.lower_bytes then break end
        local stem = entry.name:match("^(.*)%.[^.]+$")
        local is_current = current and entry.prefix == current.prefix
            and entry.index == current.index
        if not self.pins[stem] and not protected[stem] and not is_current then
            local removed, value = pcall(self.fs.remove, self.fs, entry.path)
            if removed and value == true then total = total - entry.size end
        end
    end
    self.needs_trim = total > self.lower_bytes
    return not self.needs_trim, self.needs_trim and "protected_limit" or nil
end

return PageCache
