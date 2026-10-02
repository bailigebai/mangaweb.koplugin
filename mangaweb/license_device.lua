local Crypto = require("mangaweb.license_crypto")
local Protocol = require("mangaweb.license_protocol")

local Device = {}
Device.__index = Device

local HARDWARE_PATHS = {
    "/proc/usid",
    "/sys/devices/soc0/serial_number",
}

local function default_read_file(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local value = handle:read(129)
    handle:close()
    if type(value) ~= "string" or #value > 128 then return nil end
    return value
end

local function default_random_bytes(path, count)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local value = handle:read(count)
    handle:close()
    return value
end

local function trim_ascii(value)
    local first, last = 1, #value
    while first <= last do
        local byte = value:byte(first)
        if byte ~= 32 and not (byte >= 9 and byte <= 13) then break end
        first = first + 1
    end
    while last >= first do
        local byte = value:byte(last)
        if byte ~= 32 and not (byte >= 9 and byte <= 13) then break end
        last = last - 1
    end
    return value:sub(first, last)
end

local function normalize_serial(value)
    if type(value) ~= "string" then return nil end
    value = trim_ascii(value)
    if #value < 8 or #value > 128 or value:find("[^A-Za-z0-9_-]")
        or not value:find("[^0]") then
        return nil
    end
    return value:upper()
end

local function to_hex(value)
    return (value:gsub(".", function(character)
        return string.format("%02x", character:byte())
    end))
end

local function valid_installation_id(value)
    return type(value) == "string" and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

function Device:new(dependencies)
    dependencies = dependencies or {}
    return setmetatable({
        read_file = dependencies.read_file or default_read_file,
        random_bytes = dependencies.random_bytes or default_random_bytes,
        crypto = dependencies.crypto or Crypto,
    }, self)
end

function Device:_hardware_material()
    for _, path in ipairs(HARDWARE_PATHS) do
        local success, value = pcall(self.read_file, path, 128)
        if success then
            local serial = normalize_serial(value)
            if serial then return serial end
        end
    end
    return nil
end

function Device:_device_id(material)
    local digest = self.crypto.sha256(Protocol.PRODUCT_ID .. "\n" .. material)
    if type(digest) ~= "string" then return nil, "crypto_unavailable" end
    return digest
end

function Device:resolve(identity)
    if identity ~= nil and (not Protocol.is_object_table(identity)
        or identity.schema_version ~= 1) then
        return nil, nil, "invalid_identity"
    end

    if identity and identity.identity_source == "hardware" then
        if identity.fallback_installation_id ~= nil then
            return nil, nil, "invalid_identity"
        end
        local material = self:_hardware_material()
        if not material then return nil, nil, "device_unavailable" end
        local device_id, code = self:_device_id(material)
        if not device_id then return nil, nil, code end
        return device_id, identity
    end

    if identity and identity.identity_source == "installation" then
        local material = identity.fallback_installation_id
        if not valid_installation_id(material) then
            return nil, nil, "invalid_identity"
        end
        local device_id, code = self:_device_id(material)
        if not device_id then return nil, nil, code end
        return device_id, identity
    end

    if identity ~= nil then return nil, nil, "invalid_identity" end

    local hardware_material = self:_hardware_material()
    if hardware_material then
        local device_id, code = self:_device_id(hardware_material)
        if not device_id then return nil, nil, code end
        return device_id, {
            schema_version = 1,
            identity_source = "hardware",
        }
    end

    local success, random = pcall(self.random_bytes, "/dev/urandom", 32)
    if not success or type(random) ~= "string" or #random ~= 32 then
        return nil, nil, "entropy_unavailable"
    end
    local installation_id = to_hex(random)
    local device_id, code = self:_device_id(installation_id)
    if not device_id then return nil, nil, code end
    return device_id, {
        schema_version = 1,
        identity_source = "installation",
        fallback_installation_id = installation_id,
    }
end

return Device
