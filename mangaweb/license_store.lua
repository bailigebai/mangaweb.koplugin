local LicenseJson = require("mangaweb.license_json")

local Store = {}
Store.__index = Store

local function default_read_file(path)
    return require("util").readFromFile(path, "rb")
end

local function default_write_file(data, path, force_flush, lua_ready, directory_updated)
    return require("util").writeToFile(
        data, path, force_flush, lua_ready, directory_updated
    )
end

local function default_fsync_directory(path)
    return require("ffi/util").fsyncDirectory(path)
end

local function default_path_exists(path)
    return require("util").pathExists(path) == true
end

function Store.default_path()
    return require("datastorage"):getSettingsDir() .. "/mangaweb-license.json"
end

function Store:new(dependencies)
    dependencies = dependencies or {}
    local path = dependencies.path or Store.default_path()
    local directory_path = path:match("^(.*)[/\\][^/\\]+$") or "."
    if directory_path == "" then directory_path = "/" end
    return setmetatable({
        path = path,
        temporary_path = path .. ".tmp",
        directory_path = directory_path,
        read_file = dependencies.read_file or default_read_file,
        write_file = dependencies.write_file or default_write_file,
        remove = dependencies.remove or os.remove,
        fsync_directory = dependencies.fsync_directory or default_fsync_directory,
        path_exists = dependencies.path_exists or default_path_exists,
    }, self)
end

function Store:_read_existing()
    local success, raw = pcall(self.read_file, self.path)
    if not success then return nil, "read_failed" end
    if raw ~= nil then return raw end
    local checked, exists = pcall(self.path_exists, self.path)
    if not checked or exists == true then return nil, "read_failed" end
    return nil, "not_found"
end

function Store:load()
    local raw, read_code = self:_read_existing()
    if raw == nil then return nil, read_code end
    local record = LicenseJson.decode_record(raw)
    if not record then return nil, "invalid_json" end
    return record
end

function Store:_cleanup_temporary()
    pcall(self.remove, self.temporary_path)
end

function Store:_replace(raw)
    self:_cleanup_temporary()
    local wrote, write_result = pcall(
        self.write_file, raw, self.path, true, false, true
    )
    if not wrote or write_result ~= true then
        return false
    end
    -- Match KOReader's own LuaSettings persistence path. Some Kindle user
    -- storage accepts flushed writes but rejects rename even when the target
    -- does not exist. save() keeps the previous bytes in memory and verifies
    -- the exact target bytes and JSON before accepting this direct write.
    pcall(self.fsync_directory, self.directory_path)
    return true
end

function Store:_restore(old_raw)
    self:_cleanup_temporary()
    if old_raw == nil then
        pcall(self.remove, self.path)
        pcall(self.fsync_directory, self.directory_path)
        self:_cleanup_temporary()
        return
    end
    self:_replace(old_raw)
    self:_cleanup_temporary()
end

function Store:save(record)
    local canonical = LicenseJson.encode_record(record)
    if not canonical then return nil, "save_failed" end
    canonical = canonical .. "\n"

    local old_raw, old_code = self:_read_existing()
    if old_raw == nil and old_code ~= "not_found" then
        return nil, "save_failed"
    end

    if not self:_replace(canonical) then
        self:_restore(old_raw)
        return nil, "save_failed"
    end

    local written = self:_read_existing()
    if written ~= canonical
        or LicenseJson.decode_record(written) == nil then
        self:_restore(old_raw)
        return nil, "save_failed"
    end
    return true
end

function Store:clear_receipt()
    local record, code = self:load()
    if not record then return nil, code end
    record.receipt = nil
    return self:save(record)
end

return Store
