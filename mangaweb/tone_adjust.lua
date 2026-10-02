local ToneAdjust = {}

ToneAdjust.presets = {
    { id = "original", name = "原图", brightness = 0, contrast = 100 },
    { id = "bright", name = "提亮", brightness = 10, contrast = 100 },
    { id = "contrast", name = "高对比", brightness = 0, contrast = 120 },
}

local function copy(preset)
    local result = {}
    for key, value in pairs(preset) do result[key] = value end
    return result
end

function ToneAdjust.find(id)
    for _, preset in ipairs(ToneAdjust.presets) do
        if preset.id == id then return copy(preset) end
    end
end

function ToneAdjust.build_lut(preset)
    preset = preset or ToneAdjust.find("original")
    local brightness, contrast = tonumber(preset.brightness), tonumber(preset.contrast)
    if not brightness or not contrast or brightness < -100 or brightness > 100
        or contrast < 0 or contrast > 200 then return nil end
    local lut, offset, factor = {}, brightness * 255 / 100, contrast / 100
    for input = 0, 255 do
        lut[input] = math.max(0, math.min(255,
            math.floor((input - 127.5) * factor + 127.5 + offset + 0.5)))
    end
    return lut
end

function ToneAdjust.combine_lut(first, second)
    if type(first) ~= "table" then return second end
    if type(second) ~= "table" then return first end
    local result = {}
    for input = 0, 255 do result[input] = second[first[input]] end
    return result
end

function ToneAdjust.fingerprint(gray, tone)
    gray, tone = gray or {}, tone or ToneAdjust.find("original")
    return table.concat({
        tostring(gray.black or 0), tostring(gray.white or 255), tostring(gray.gamma or 1),
        tostring(tone.brightness or 0), tostring(tone.contrast or 100),
    }, ":")
end

return ToneAdjust
