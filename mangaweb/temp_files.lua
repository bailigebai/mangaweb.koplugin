local TempFiles = {}
TempFiles.__index = TempFiles
local image_kind = require("mangaweb.page_cache").image_kind
local MAX_IMAGE_BYTES = 64 * 1048576

local function mkdir(path, fs)
    if fs and type(fs.mkdir) == "function" then
        local ok, made = pcall(fs.mkdir, fs, path)
        return ok and made == true
    end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.mkdir then
        if lfs.attributes(path, "mode") == "directory" then return true end
        local made, result = pcall(lfs.mkdir, path)
        return made and result == true
    end
    return false
end

local function file_size(path, fs)
    if fs and type(fs.size) == "function" then return fs:size(path) end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    return ok and lfs and lfs.attributes(path, "size") or nil
end

local function read_header(path, fs)
    if fs and type(fs.read) == "function" then return fs:read(path, 12) end
    local file = io.open(path, "rb")
    if not file then return nil end
    local header = file:read(12)
    file:close()
    return header
end

local function rename_file(source, target, fs)
    if fs and type(fs.rename) == "function" then return fs:rename(source, target) end
    return os.rename(source, target) ~= nil
end

local function create_empty(path, fs)
    if fs and type(fs.write) == "function" then
        local ok, written = pcall(fs.write, fs, path, "")
        return ok and written == true
    end
    local file = io.open(path, "wb")
    if not file then return false end
    return file:close() ~= nil
end

local function remove_file(path, fs)
    if fs and type(fs.remove) == "function" then return pcall(fs.remove, fs, path) end
    return pcall(os.remove, path)
end

local function remove_directory(path, fs)
    if fs and type(fs.rmdir) == "function" then return pcall(fs.rmdir, fs, path) end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.rmdir then return pcall(lfs.rmdir, path) end
    return false
end

function TempFiles:new(options)
    options = options or {}
    local root = options.root or "."
    mkdir(root, options.fs)
    return setmetatable({ root = root, fs = options.fs, counter = 0,
        sessions = {}, reservations = {} }, self)
end

function TempFiles:new_session()
    self.counter = self.counter + 1
    local session = tostring(os.time()) .. "-" .. tostring(self.counter)
    self.sessions[session] = {}
    mkdir(self.root .. "/" .. session, self.fs)
    return session
end

function TempFiles:path(session, index, extension)
    extension = extension or "jpg"
    return self.root .. "/" .. tostring(session) .. "/" .. tostring(index) .. "." .. extension
end

function TempFiles:write(session, index, body, extension)
    local path = self:path(session, index, extension)
    if self.fs and self.fs.write then
        self.fs:write(path, body)
    else
        local handle, error_value = io.open(path, "wb")
        if not handle then return nil, error_value end
        handle:write(body or "")
        handle:close()
    end
    return self:track(session, path)
end

function TempFiles:reserve(session, _name)
    if not self.sessions[session] or not mkdir(self.root .. "/" .. session, self.fs) then
        return nil
    end
    self.counter = self.counter + 1
    local part = self.root .. "/" .. session .. "/stream_"
        .. tostring(self.counter) .. ".part"
    if not create_empty(part, self.fs) then
        remove_file(part, self.fs)
        return nil
    end
    self.reservations[part] = session
    return part
end

function TempFiles:discard(part_path)
    local session = self.reservations[part_path]
    if not session then return false end
    self.reservations[part_path] = nil
    remove_file(part_path, self.fs)
    if not self.sessions[session] then
        remove_directory(self.root .. "/" .. session, self.fs)
    end
    return true
end

function TempFiles:publish(session, part_path, extension, reported_bytes)
    if self.reservations[part_path] ~= session then return nil, "invalid_part" end
    local size_ok, size = pcall(file_size, part_path, self.fs)
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
    local read_ok, header = pcall(read_header, part_path, self.fs)
    local actual_extension = read_ok and image_kind(header) or nil
    if not actual_extension or extension and actual_extension ~= extension then
        self:discard(part_path)
        return nil, "invalid_image"
    end
    if not self.sessions[session] then
        self:discard(part_path)
        return nil, "session_closed"
    end
    local final = part_path:sub(1, -6) .. "." .. actual_extension
    local renamed, success = pcall(rename_file, part_path, final, self.fs)
    if not renamed or success ~= true then
        self:discard(part_path)
        return nil, "storage_error"
    end
    self.reservations[part_path] = nil
    return self:track(session, final)
end

function TempFiles:track(session, path)
    self.sessions[session] = self.sessions[session] or {}
    for _, existing in ipairs(self.sessions[session]) do
        if existing == path then return path end
    end
    self.sessions[session][#self.sessions[session] + 1] = path
    return path
end

function TempFiles:remove_session(session)
    if not self.sessions[session] then return true end
    for _, path in ipairs(self.sessions[session] or {}) do remove_file(path, self.fs) end
    self.sessions[session] = nil
    remove_directory(self.root .. "/" .. tostring(session), self.fs)
    return true
end

function TempFiles:remove(path)
    if not path then return false end
    local registered = false
    for _, paths in pairs(self.sessions) do
        for index = #paths, 1, -1 do
            if paths[index] == path then table.remove(paths, index); registered = true end
        end
    end
    if registered then remove_file(path, self.fs); return true end
    return false
end

function TempFiles:remove_all_stale()
    return true
end

return TempFiles
