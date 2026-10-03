local ToneAdjust = {}
local Presets = require("mangaweb.filter_presets")

ToneAdjust.presets = Presets.all("tone")

function ToneAdjust.find(id, custom)
    return Presets.find("tone", id, custom)
end

function ToneAdjust.build_lut(preset)
    preset = preset or ToneAdjust.find("original")
    local brightness, contrast = tonumber(preset.brightness), tonumber(preset.contrast)
    if not brightness or not contrast or brightness ~= math.floor(brightness) or contrast ~= math.floor(contrast)
        or brightness < -100 or brightness > 100
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
