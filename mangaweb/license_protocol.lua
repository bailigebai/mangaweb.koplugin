local Protocol = {
    PRODUCT_ID = "mangaweb-image-reader",
    RECEIPT_VERSION = 1,
    SIGNING_PREFIX = "MANGAWEB-IMAGE-READER-LICENSE-1",
}

local ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
local allowed = {}
for index = 1, #ALPHABET do allowed[ALPHABET:sub(index, index)] = true end

local receipt_keys = {
    version = true,
    product = true,
    device_id = true,
    key_id = true,
    issued_at = true,
    signature = true,
}

local function is_ascii(value)
    for index = 1, #value do
        if value:byte(index) > 127 then return false end
    end
    return true
end

local function is_ascii_space(byte)
    return byte == 32 or byte >= 9 and byte <= 13
end

local function trim_ascii(value)
    local first, last = 1, #value
    while first <= last and is_ascii_space(value:byte(first)) do first = first + 1 end
    while last >= first and is_ascii_space(value:byte(last)) do last = last - 1 end
    return value:sub(first, last)
end

local function lowercase_hex64(value)
    return type(value) == "string" and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

function Protocol.is_object_table(value)
    if type(value) ~= "table" then return false end
    -- KOReader's native lua-rapidjson marks every decoded object with this
    -- shared metatable. Arrays use "array" and must remain invalid here.
    local metatable = getmetatable(value)
    return metatable == nil
        or (type(metatable) == "table"
            and rawget(metatable, "__jsontype") == "object")
end

local function canonical_signature(value)
    if type(value) ~= "string" or #value ~= 344 or value:sub(-2) ~= "==" then
        return false
    end
    local encoded = value:sub(1, 342)
    if not encoded:match("^[A-Za-z0-9+/]+$") then return false end
    return encoded:sub(-1):match("^[AQgw]$") ~= nil
end

function Protocol.normalize_key(raw)
    if type(raw) ~= "string" or not is_ascii(raw) then
        return nil, "invalid_key_format"
    end
    raw = trim_ascii(raw):upper()
    if #raw == 14 then
        if raw:sub(5, 5) ~= "-" or raw:sub(10, 10) ~= "-" then
            return nil, "invalid_key_format"
        end
        if raw:sub(1, 4):find("-", 1, true)
            or raw:sub(6, 9):find("-", 1, true)
            or raw:sub(11, 14):find("-", 1, true) then
            return nil, "invalid_key_format"
        end
    elseif #raw ~= 12 or raw:find("-", 1, true) then
        return nil, "invalid_key_format"
    end
    local token = #raw == 14 and (raw:sub(1, 4) .. raw:sub(6, 9) .. raw:sub(11, 14)) or raw
    for index = 1, 12 do
        if not allowed[token:sub(index, index)] then
            return nil, "invalid_key_format"
        end
    end
    return token:sub(1, 4) .. "-" .. token:sub(5, 8) .. "-" .. token:sub(9, 12)
end

function Protocol.validate_receipt(receipt, current_device_id)
    if not Protocol.is_object_table(receipt) then
        return nil, "invalid_receipt"
    end
    local count = 0
    for key in pairs(receipt) do
        if not receipt_keys[key] then return nil, "invalid_receipt" end
        count = count + 1
    end
    if count ~= 6 or receipt.version ~= Protocol.RECEIPT_VERSION then
        return nil, "invalid_receipt"
    end
    if receipt.product ~= Protocol.PRODUCT_ID then return nil, "wrong_product" end
    if not lowercase_hex64(current_device_id) or not lowercase_hex64(receipt.device_id)
        or receipt.device_id ~= current_device_id then
        return nil, "wrong_device"
    end
    if not lowercase_hex64(receipt.key_id) then return nil, "invalid_receipt" end
    local issued_at = receipt.issued_at
    if type(issued_at) ~= "number" or issued_at ~= issued_at or issued_at == math.huge
        or issued_at == -math.huge or issued_at < 1 or issued_at ~= math.floor(issued_at)
        or issued_at > 9007199254740991 then
        return nil, "invalid_receipt"
    end
    if not canonical_signature(receipt.signature) then return nil, "invalid_signature" end
    return Protocol.SIGNING_PREFIX .. "\n" .. receipt.device_id .. "\n"
        .. receipt.key_id .. "\n" .. string.format("%.0f", issued_at)
end

return Protocol
