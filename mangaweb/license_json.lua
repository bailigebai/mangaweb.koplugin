local Protocol = require("mangaweb.license_protocol")
local rapidjson = require("rapidjson")

local LicenseJson = {}
LicenseJson.MAX_BYTES = 16384

local RECORD_KEYS = {
    schema_version = true,
    identity_source = true,
    fallback_installation_id = true,
    receipt = true,
}
local RECEIPT_KEYS = {
    version = true,
    product = true,
    device_id = true,
    key_id = true,
    issued_at = true,
    signature = true,
}
local RESPONSE_KEYS = {
    ok = true,
    receipt = true,
    error = true,
}
local RESPONSE_ERRORS = {
    invalid_request = true,
    invalid_key = true,
    key_bound_to_other_device = true,
    rate_limited = true,
    service_unavailable = true,
}

local function valid_utf8(value)
    local index, length = 1, #value
    while index <= length do
        local first = value:byte(index)
        if first <= 0x7F then
            index = index + 1
        elseif first >= 0xC2 and first <= 0xDF then
            local second = value:byte(index + 1)
            if not second or second < 0x80 or second > 0xBF then return false end
            index = index + 2
        elseif first == 0xE0 then
            local second, third = value:byte(index + 1, index + 2)
            if not third or second < 0xA0 or second > 0xBF
                or third < 0x80 or third > 0xBF then return false end
            index = index + 3
        elseif first >= 0xE1 and first <= 0xEC or first >= 0xEE and first <= 0xEF then
            local second, third = value:byte(index + 1, index + 2)
            if not third or second < 0x80 or second > 0xBF
                or third < 0x80 or third > 0xBF then return false end
            index = index + 3
        elseif first == 0xED then
            local second, third = value:byte(index + 1, index + 2)
            if not third or second < 0x80 or second > 0x9F
                or third < 0x80 or third > 0xBF then return false end
            index = index + 3
        elseif first == 0xF0 then
            local second, third, fourth = value:byte(index + 1, index + 3)
            if not fourth or second < 0x90 or second > 0xBF
                or third < 0x80 or third > 0xBF
                or fourth < 0x80 or fourth > 0xBF then return false end
            index = index + 4
        elseif first >= 0xF1 and first <= 0xF3 then
            local second, third, fourth = value:byte(index + 1, index + 3)
            if not fourth or second < 0x80 or second > 0xBF
                or third < 0x80 or third > 0xBF
                or fourth < 0x80 or fourth > 0xBF then return false end
            index = index + 4
        elseif first == 0xF4 then
            local second, third, fourth = value:byte(index + 1, index + 3)
            if not fourth or second < 0x80 or second > 0x8F
                or third < 0x80 or third > 0xBF
                or fourth < 0x80 or fourth > 0xBF then return false end
            index = index + 4
        else
            return false
        end
    end
    return true
end

local function unique_plain_keys(raw)
    local seen = {}
    local index, length = 1, #raw
    while index <= length do
        if raw:byte(index) ~= 34 then
            index = index + 1
        else
            local first = index + 1
            local cursor = first
            local escaped = false
            while cursor <= length do
                local byte = raw:byte(cursor)
                if byte == 34 then break end
                if byte < 32 then return false end
                if byte == 92 then
                    escaped = true
                    cursor = cursor + 1
                    if cursor > length then return false end
                    local escape = raw:sub(cursor, cursor)
                    if not escape:match('^["\\/bfnrtu]$') then return false end
                    if escape == "u" then
                        local hex = raw:sub(cursor + 1, cursor + 4)
                        if #hex ~= 4 or not hex:match("^[0-9A-Fa-f]+$") then return false end
                        cursor = cursor + 4
                    end
                end
                cursor = cursor + 1
            end
            if cursor > length then return false end
            local after = cursor + 1
            while after <= length and raw:sub(after, after):match("[%s]") do
                after = after + 1
            end
            if raw:sub(after, after) == ":" then
                if escaped then return false end
                local key = raw:sub(first, cursor - 1)
                if seen[key] then return false end
                seen[key] = true
            end
            index = cursor + 1
        end
    end
    return true
end

local function exact_keys(value, allowed)
    if not Protocol.is_object_table(value) then return false end
    for key in pairs(value) do
        if type(key) ~= "string" or not allowed[key] then return false end
    end
    return true
end

local function valid_receipt(receipt)
    if not exact_keys(receipt, RECEIPT_KEYS) then return false end
    local count = 0
    for _ in pairs(receipt) do count = count + 1 end
    if count ~= 6 then return false end
    return Protocol.validate_receipt(receipt, receipt.device_id) ~= nil
end

local function valid_record(record)
    if not exact_keys(record, RECORD_KEYS) or record.schema_version ~= 1 then return false end
    if record.identity_source == "hardware" then
        if record.fallback_installation_id ~= nil then return false end
    elseif record.identity_source == "installation" then
        local fallback = record.fallback_installation_id
        if type(fallback) ~= "string" or #fallback ~= 64
            or fallback:match("^[0-9a-f]+$") == nil then return false end
    else
        return false
    end
    if record.receipt ~= nil and not valid_receipt(record.receipt) then return false end
    return true
end

local function decode(raw)
    if type(raw) ~= "string" or #raw == 0 or #raw > LicenseJson.MAX_BYTES
        or not valid_utf8(raw) or not unique_plain_keys(raw) then
        return nil
    end
    local success, value, error_message = pcall(rapidjson.decode, raw)
    if not success or value == nil or error_message ~= nil then return nil end
    return value
end

function LicenseJson.decode_record(raw)
    local value = decode(raw)
    if not valid_record(value) then return nil, "invalid_json" end
    return value
end

function LicenseJson.decode_response(raw)
    local value = decode(raw)
    if not exact_keys(value, RESPONSE_KEYS) then return nil, "invalid_json" end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    if value.ok == true then
        if count ~= 2 or not valid_receipt(value.receipt) then
            return nil, "invalid_json"
        end
    elseif value.ok == false then
        if count ~= 2 or type(value.error) ~= "string" or not RESPONSE_ERRORS[value.error] then
            return nil, "invalid_json"
        end
    else
        return nil, "invalid_json"
    end
    return value
end

local function encode_receipt(receipt)
    return '{"version":1,"product":"' .. receipt.product
        .. '","device_id":"' .. receipt.device_id
        .. '","key_id":"' .. receipt.key_id
        .. '","issued_at":' .. string.format("%.0f", receipt.issued_at)
        .. ',"signature":"' .. receipt.signature .. '"}'
end

function LicenseJson.encode_record(record)
    if not valid_record(record) then return nil, "invalid_record" end
    local parts = {
        '{"schema_version":1,"identity_source":"',
        record.identity_source,
        '"',
    }
    if record.identity_source == "installation" then
        parts[#parts + 1] = ',"fallback_installation_id":"'
        parts[#parts + 1] = record.fallback_installation_id
        parts[#parts + 1] = '"'
    end
    if record.receipt ~= nil then
        parts[#parts + 1] = ',"receipt":'
        parts[#parts + 1] = encode_receipt(record.receipt)
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

return LicenseJson
