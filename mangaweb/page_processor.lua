local GrayEnhance = require("mangaweb.gray_enhance")
local PageSequence = require("mangaweb.page_sequence")
local ToneAdjust = require("mangaweb.tone_adjust")
local ImageDimensions = require("mangaweb.image_dimensions")
local Presets = require("mangaweb.filter_presets")

local PageProcessor = {}

local function positive(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or value <= 0 then return nil end
    return value
end

local function target_size(width, height, settings, content_w, content_h)
    width, height = positive(width), positive(height)
    content_w, content_h = positive(content_w), positive(content_h)
    if not width or not height or not content_w or not content_h then return nil end
    local split = #PageSequence.segments(width, height, settings) == 2
    local scale
    if split then
        local cut = math.max(0.1, math.min(0.9, (tonumber(settings.split_cut_percent) or 50) / 100))
        scale = math.min(content_w / math.max(width * cut, width * (1 - cut)), content_h / height)
    elseif settings.fit_mode == "width" then
        scale = content_w / width
    else
        scale = math.min(content_w / width, content_h / height)
    end
    scale = math.min(scale, math.sqrt((2 * content_w * content_h) / (width * height)))
    return math.max(1, math.floor(width * scale)), math.max(1, math.floor(height * scale))
end

function PageProcessor.profile(image, settings, content_w, content_h)
    image, settings = image or {}, settings or {}
    if settings.gray_enabled ~= true and settings.tone_enabled ~= true then return nil end
    local gray = settings.gray_enabled and GrayEnhance.find(settings.gray_preset or "original", settings.gray_custom_presets) or nil
    local tone = settings.tone_enabled and ToneAdjust.find(settings.tone_preset or "original", settings.tone_custom_presets) or nil
    if settings.gray_enabled and not gray then return nil, "invalid_gray_preset" end
    if settings.tone_enabled and not tone then return nil, "invalid_tone_preset" end
    local lut = ToneAdjust.combine_lut(gray and GrayEnhance.build_lut(gray) or nil,
        tone and ToneAdjust.build_lut(tone) or nil)
    local changed = false
    for input = 0, 255 do if lut and lut[input] ~= input then changed = true; break end end
    if not changed then return nil end
    local width, height = positive(image.width), positive(image.height)
    if not width or not height then
        return { id = table.concat({"pending",tostring(content_w),tostring(content_h),ToneAdjust.fingerprint(gray,tone)}, ":"),
            settings = Presets.copy(settings), content_width = content_w, content_height = content_h }
    end
    local target_width, target_height = target_size(width, height, settings, content_w, content_h)
    if not target_width then return nil, "invalid_image_dimensions" end
    local split_cut_percent = tonumber(settings.split_cut_percent) or 50
    local split = #PageSequence.segments(width, height, settings) == 2
    return {
        id = table.concat({
            target_width .. "x" .. target_height, tostring(settings.fit_mode or "page"),
            split and "split" or "whole", tostring(split_cut_percent), ToneAdjust.fingerprint(gray, tone),
        }, ":"),
        target_width = target_width,
        target_height = target_height,
        lut = lut, source_width = width, source_height = height,
        fit_mode = settings.fit_mode or "page",
        split_cut_percent = split_cut_percent,
    }
end

local function free(buffer)
    if buffer and type(buffer.free) == "function" then pcall(buffer.free, buffer) end
end

function PageProcessor.process(source_path, output_path, profile, deps)
    if type(profile) ~= "table" or type(output_path) ~= "string" then return nil, "invalid_processing_profile" end
    deps = deps or {}
    local renderer = deps.renderer
    if not renderer then
        local ok, loaded = pcall(require, "ui/renderimage")
        if ok then renderer = loaded end
    end
    if not renderer or type(renderer.renderImageFile) ~= "function" then return nil, "image_renderer_unavailable" end
    if profile.settings then
        -- Resolve unknown dimensions in this processing worker, never by
        -- fully decoding the first JPEG on the UI thread.
        local width, height = ImageDimensions.from_file(source_path)
        if not width or not height then
            local decoded, probe = pcall(renderer.renderImageFile, renderer, source_path, false)
            if not decoded or not probe then return nil, "image_decode_failed" end
            local measured, w, h = pcall(function() return probe:getWidth(), probe:getHeight() end)
            free(probe)
            if not measured then return nil, "invalid_image_dimensions" end
            width, height = w,h
        end
        local resolved, reason = PageProcessor.profile({width=width,height=height}, profile.settings,
            profile.content_width,profile.content_height)
        if not resolved or not resolved.target_width then return nil, reason or "invalid_processing_profile" end
        profile = resolved
    end
    local decoded, buffer, decode_reason = pcall(renderer.renderImageFile, renderer,
        source_path, false, profile.target_width, profile.target_height)
    if not decoded or not buffer then return nil, decode_reason or "image_decode_failed" end
    local apply_lut = deps.lut_applier or GrayEnhance.apply_lut
    if profile.lut then
        local applied, result, reason = pcall(apply_lut, buffer, profile.lut, true)
        if not applied or result ~= true then
            free(buffer)
            return nil, reason or "gray_processing_failed"
        end
    end
    local wrote, result, write_reason = pcall(buffer.writePNG, buffer, output_path)
    free(buffer)
    if not wrote or result == false then return nil, write_reason or "png_write_failed" end
    local metadata = { width = profile.target_width, height = profile.target_height, format = "png" }
    if deps.image_probe then
        local inspected, probe_result, probe_reason = pcall(deps.image_probe, output_path)
        if not inspected or not probe_result then return nil, probe_reason or "png_validation_failed" end
        metadata = probe_result
        metadata.format = "png"
    end
    metadata.source_width, metadata.source_height = profile.source_width, profile.source_height
    return metadata
end

return PageProcessor
