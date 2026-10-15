-- Public-key verification only, for KOReader builds without exported RSA APIs.
-- Fixed product format: RSA-2048, e=65537, SPKI, PKCS1-v1.5 with SHA256.
local Rsa = {}
local floor = math.floor
local BASE, LIMBS = 65536, 128
local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local digits = {}
for index = 1, #alphabet do digits[alphabet:sub(index, index)] = index - 1 end

local function unhex(value)
    return (value:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end))
end
local SPKI_PREFIX = unhex('30820122300d06092a864886f70d01010105000382010f003082010a0282010100')
local SPKI_SUFFIX = unhex('0203010001')
local DIGEST_INFO = unhex('3031300d060960864801650304020105000420')

local function decode64(value)
    if #value == 0 or #value > 512 or #value % 4 ~= 0
        or value:find('[^A-Za-z0-9+/=]') then return nil end
    local padding = #(value:match('=*$') or '')
    if padding > 2 or value:sub(1, #value - padding):find('=', 1, true) then return nil end
    local output = {}
    for index = 1, #value, 4 do
        local a, b = digits[value:sub(index, index)], digits[value:sub(index + 1, index + 1)]
        local c, d = digits[value:sub(index + 2, index + 2)], digits[value:sub(index + 3, index + 3)]
        if not a or not b then return nil end
        if index == #value - 3 then
            if padding == 2 and b % 16 ~= 0 or padding == 1 and (not c or c % 4 ~= 0) then
                return nil
            end
        end
        local number = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        output[#output + 1] = string.char(floor(number / 65536))
        if c then output[#output + 1] = string.char(floor(number / 256) % 256) end
        if d then output[#output + 1] = string.char(number % 256) end
    end
    return table.concat(output)
end

local function limbs(bytes)
    local output = {}
    for index = 1, LIMBS do
        local position = 257 - 2 * index
        output[index] = bytes:byte(position) * 256 + bytes:byte(position + 1)
    end
    return output
end

local function at_least(left, right)
    for index = LIMBS, 1, -1 do
        if left[index] ~= right[index] then return left[index] > right[index] end
    end
    return true
end

local function subtract(value, modulus)
    local borrow = 0
    for index = 1, LIMBS do
        local difference = value[index] - modulus[index] - borrow
        borrow = difference < 0 and 1 or 0
        value[index] = difference + borrow * BASE
    end
    value[LIMBS + 1] = (value[LIMBS + 1] or 0) - borrow
end

-- Coarsely integrated Montgomery multiplication. Each intermediate is below
-- 2^33, so Lua 5.1 doubles represent every integer exactly (no 64-bit shifts).
local function multiply(left, right, modulus, inverse)
    local result = {}
    for index = 1, LIMBS + 2 do result[index] = 0 end
    for outer = 1, LIMBS do
        local carry = 0
        for index = 1, LIMBS do
            local number = result[index] + left[index] * right[outer] + carry
            result[index], carry = number % BASE, floor(number / BASE)
        end
        local number = result[LIMBS + 1] + carry
        result[LIMBS + 1], result[LIMBS + 2] = number % BASE, floor(number / BASE)
        local factor = (result[1] * inverse) % BASE
        carry = 0
        for index = 1, LIMBS do
            number = result[index] + factor * modulus[index] + carry
            if index > 1 then result[index - 1] = number % BASE end
            carry = floor(number / BASE)
        end
        number = result[LIMBS + 1] + carry
        result[LIMBS] = number % BASE
        result[LIMBS + 1] = result[LIMBS + 2] + floor(number / BASE)
        result[LIMBS + 2] = 0
    end
    if result[LIMBS + 1] > 0 or at_least(result, modulus) then subtract(result, modulus) end
    return result
end

local cached
local function parameters(pem)
    if cached and cached.pem == pem then return cached end
    local body = pem:match('^%s*%-%-%-%-%-BEGIN PUBLIC KEY%-%-%-%-%-%s*(.-)%s*%-%-%-%-%-END PUBLIC KEY%-%-%-%-%-%s*$')
    local der = body and decode64((body:gsub('%s', '')))
    -- This exact DER envelope fixes modulus width and exponent and rejects
    -- trailing data, negative/nonminimal integers and other key algorithms.
    if not der or #der ~= 294 or der:sub(1, 33) ~= SPKI_PREFIX
        or der:sub(290) ~= SPKI_SUFFIX then return nil end
    local bytes = der:sub(34, 289)
    if bytes:byte(1) < 128 or bytes:byte(256) % 2 ~= 1 then return nil end
    local modulus = limbs(bytes)
    local inverse = 1
    for _ = 1, 4 do inverse = (inverse * (2 - (modulus[1] * inverse) % BASE)) % BASE end
    inverse = (BASE - inverse) % BASE
    local r2 = {}
    for index = 1, LIMBS do r2[index] = index == 1 and 1 or 0 end
    -- R^2 mod n, R=2^2048, with exactly 4096 bounded doubling steps.
    for _ = 1, 4096 do
        local carry = 0
        for index = 1, LIMBS do
            local number = r2[index] * 2 + carry
            r2[index], carry = number % BASE, floor(number / BASE)
        end
        r2[LIMBS + 1] = carry
        if carry > 0 or at_least(r2, modulus) then subtract(r2, modulus) end
    end
    -- One public key only: repeated authorization checks cannot grow memory.
    cached = { pem = pem, modulus = modulus, inverse = inverse, r2 = r2 }
    return cached
end

function Rsa.verify(message, signature, pem, sha256)
    if type(message) ~= 'string' or #message > 256 or type(signature) ~= 'string'
        or #signature ~= 344 or type(pem) ~= 'string' or #pem > 8192
        or type(sha256) ~= 'function' then return false end
    local decoded = decode64(signature)
    if not decoded or #decoded ~= 256 then return false end
    local called, digest = pcall(sha256, message)
    if not called or type(digest) ~= 'string' or #digest ~= 64
        or digest:find('[^0-9a-f]') then return false end
    local key = parameters(pem)
    if not key then return false end
    local value = limbs(decoded)
    if at_least(value, key.modulus) then return false end
    local one = {}
    for index = 1, LIMBS do one[index] = index == 1 and 1 or 0 end
    local base = multiply(value, key.r2, key.modulus, key.inverse)
    local result = base
    for _ = 1, 16 do result = multiply(result, result, key.modulus, key.inverse) end
    result = multiply(result, base, key.modulus, key.inverse) -- exponent 65537
    result = multiply(result, one, key.modulus, key.inverse)
    local output = {}
    for index = LIMBS, 1, -1 do
        output[#output + 1] = string.char(floor(result[index] / 256), result[index] % 256)
    end
    local expected = '\000\001' .. string.rep('\255', 202) .. '\000' .. DIGEST_INFO .. unhex(digest)
    return table.concat(output) == expected
end

return Rsa
