local PageSequence = {}

function PageSequence.segments(width, height, settings)
    settings = settings or {}
    if settings.split_enabled ~= true or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return { "whole" }
    end
    local ratio = width / height
    local minimum = tonumber(settings.split_min_ratio) or 1.20
    local maximum = tonumber(settings.split_max_ratio) or 2.20
    if ratio < minimum or ratio > maximum then return { "whole" } end
    local first = settings.split_first_segment
    if first == "auto" then first = settings.direction == "rtl" and "right" or "left" end
    return first == "right" and { "right", "left" } or { "left", "right" }
end

function PageSequence.viewport(width, height, segment, cut_percent)
    width = tonumber(width) or 0
    height = tonumber(height) or 0
    local cut = math.floor(width * (tonumber(cut_percent) or 50) / 100)
    if segment == "left" then return { x = 0, y = 0, w = cut, h = height } end
    if segment == "right" then return { x = cut, y = 0, w = width - cut, h = height } end
    return { x = 0, y = 0, w = width, h = height }
end

local function segment_index(segment, segments)
    for index, value in ipairs(segments or {}) do
        if value == segment then return index end
    end
end

function PageSequence.next(position, segments, physical_count)
    local index = tonumber(position and position.index)
    local count = math.floor(tonumber(physical_count) or 0)
    if not index or index < 1 or index > count then return nil end
    local segment = segment_index(position.segment, segments)
    if segment and segments[segment + 1] then return { index = index, segment = segments[segment + 1] } end
    if index >= count then return nil end
    return { index = index + 1, segment = "whole" }
end

function PageSequence.previous(position, segments, physical_count)
    local index = tonumber(position and position.index)
    local count = math.floor(tonumber(physical_count) or 0)
    if not index or index < 1 or index > count then return nil end
    local segment = segment_index(position.segment, segments)
    if segment and segments[segment - 1] then return { index = index, segment = segments[segment - 1] } end
    if index <= 1 then return nil end
    return { index = index - 1, segment = "whole" }
end

function PageSequence.pan(current_y, rendered_height, viewport_height, forward)
    local current = tonumber(current_y) or 0
    local viewport = tonumber(viewport_height) or 0
    local maximum = math.max(0, (tonumber(rendered_height) or 0) - viewport)
    local target = forward and math.min(current + math.floor(viewport * 0.85), maximum)
        or math.max(current - math.floor(viewport * 0.85), 0)
    if target == current then return nil end
    return target
end

return PageSequence
