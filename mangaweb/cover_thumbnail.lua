local ImageDimensions = require("mangaweb.image_dimensions")
local ImageIdentity = require("mangaweb.image_identity")
local Thumbnail = {}

local function target(value, fallback, maximum)
    value = tonumber(value)
    if not value or value ~= value or value <= 0 then value = fallback end
    return math.min(maximum, math.max(64, math.ceil(value / 64) * 64))
end

function Thumbnail.profile(width, height)
    return { target_width = target(width, 320, 640),
        target_height = target(height, 480, 960), extension = "jpg" }
end

function Thumbnail.identity(spec, profile, sha256)
    local scope = ImageIdentity.scope(spec.headers, sha256)
    if not scope then return nil end
    return { site_id = spec.site_id, comic_id = spec.comic_id, index = 1,
        chapter_id = "cover-v1:" .. profile.target_width .. "x" .. profile.target_height .. ":" .. scope,
        url = spec.url }
end

function Thumbnail.process(source, output, profile, renderer)
    if not renderer then
        local ok, value = pcall(require, "ui/renderimage")
        if ok then renderer = value end
    end
    if not renderer or type(renderer.renderImageFile) ~= "function" then
        return nil, "thumbnail_renderer_unavailable"
    end
    local ok, buffer = pcall(renderer.renderImageFile, renderer, source, false,
        profile.target_width, profile.target_height)
    if not ok or not buffer then return nil, "thumbnail_decode_failed" end
    local wrote, success = pcall(function() return buffer:writeToFile(output, "jpg", 75) end)
    if type(buffer.free) == "function" then pcall(buffer.free, buffer) end
    if not wrote or success ~= true then return nil, "thumbnail_encode_failed" end
    local width, height = ImageDimensions.from_file(output)
    if not width or not height or width > profile.target_width or height > profile.target_height then
        return nil, "thumbnail_validation_failed"
    end
    return { width = width, height = height, thumbnail = true }
end

return Thumbnail
