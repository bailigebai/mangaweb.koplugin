local GrayEnhance = {}

GrayEnhance.presets = {
    { id = "original", name = "原图" },
    { id = "clear", name = "清晰", black = 40, white = 238, gamma = 1.20 },
    { id = "strong", name = "强力", black = 55, white = 228, gamma = 1.30 },
}

local MAX_PIXELS = 8 * 1024 * 1024
local MAX_WORK_BYTES = 40 * 1024 * 1024

local function copy(preset)
    local result = {}
    for key, value in pairs(preset) do result[key] = value end
    return result
end

function GrayEnhance.find(id)
    for _, preset in ipairs(GrayEnhance.presets) do
        if preset.id == id then return copy(preset) end
    end
end

function GrayEnhance.build_lut(preset)
    if not preset or preset.id == "original" then return nil end
    local black, white, gamma = tonumber(preset.black), tonumber(preset.white), tonumber(preset.gamma)
    if not black or not white or not gamma or black < 0 or white > 255 or black >= white or gamma <= 0 then
        return nil
    end
    local lut, span = {}, white - black
    for value = 0, 255 do
        local output = value <= black and 0 or value >= white and 255
            or math.floor(math.pow((value - black) / span, gamma) * 255 + 0.5)
        lut[value] = math.max(0, math.min(255, output))
    end
    return lut
end

local function layout(buffer, ffi, BB)
    if type(buffer) ~= "cdata" then return nil, "gray_unsupported_buffer" end
    local step
    if ffi.istype("BlitBuffer8", buffer) and buffer:getType() == BB.TYPE_BB8 then
        step = 1
    elseif ffi.istype("BlitBuffer8A", buffer) and buffer:getType() == BB.TYPE_BB8A then
        step = 2
    elseif ffi.istype("BlitBufferRGB24", buffer) and buffer:getType() == BB.TYPE_BBRGB24 then
        step = 3
    elseif ffi.istype("BlitBufferRGB32", buffer) and buffer:getType() == BB.TYPE_BBRGB32 then
        step = 4
    else
        return nil, "gray_unsupported_buffer"
    end
    local width, height, stride = tonumber(buffer.w), tonumber(buffer.h), tonumber(buffer.stride)
    if not width or not height or not stride or width < 1 or height < 1
        or stride < width * step or buffer.data == nil then
        return nil, "gray_invalid_buffer"
    end
    if width * height > MAX_PIXELS or width * height * step * 2 > MAX_WORK_BYTES then
        return nil, "gray_image_too_large"
    end
    return { width = width, height = height, stride = stride, step = step }
end

local function map_pixels(buffer, values, ffi, BB)
    local info, reason = layout(buffer, ffi, BB)
    if not info then return false, reason end
    local inverse = buffer:getInverse() == 1
    local lut = ffi.new("uint8_t[256]")
    for value = 0, 255 do
        local mapped = tonumber(values[value])
        if not mapped or mapped ~= math.floor(mapped) or mapped < 0 or mapped > 255 then
            return false, "invalid_gray_lut"
        end
        lut[value] = inverse and (255 - values[255 - value]) or mapped
    end
    local raw = ffi.cast("uint8_t*", buffer.data)
    for row = 0, info.height - 1 do
        local line = raw + row * info.stride
        for offset = 0, info.width * info.step - 1, info.step do
            if info.step == 1 or info.step == 2 then
                line[offset] = lut[line[offset]]
            else
                local red, green, blue = line[offset], line[offset + 1], line[offset + 2]
                if inverse then red, green, blue = 255 - red, 255 - green, 255 - blue end
                local luminance = math.floor(0.299 * red + 0.587 * green + 0.114 * blue + 0.5)
                local mapped = lut[inverse and 255 - luminance or luminance]
                line[offset], line[offset + 1], line[offset + 2] = mapped, mapped, mapped
            end
        end
    end
    return true
end

function GrayEnhance.apply_lut(buffer, values)
    if type(values) ~= "table" then return false, "invalid_gray_lut" end
    local ffi_ok, ffi = pcall(require, "ffi")
    local bb_ok, BB = pcall(require, "ffi/blitbuffer")
    if not ffi_ok or not bb_ok then return false, "gray_native_unavailable" end
    local ok, applied, reason = pcall(map_pixels, buffer, values, ffi, BB)
    if not ok then return false, "gray_processing_failed" end
    return applied, reason
end

return GrayEnhance
