-- Read JPEG dimensions without decoding the full image on the UI thread.
local ImageDimensions = {}

local function byte(value, index)
    return value and value:byte(index) or nil
end

function ImageDimensions.from_file(path)
    if type(path) ~= "string" then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local width, height
    if file:read(2) == "\255\216" then
        local scanned = 2
        for _ = 1, 128 do
            local marker = file:read(2)
            if not marker or byte(marker, 1) ~= 255 then break end
            local code = byte(marker, 2)
            while code == 255 do
                local more = file:read(1)
                code = byte(more, 1)
                scanned = scanned + 1
            end
            if not code or code == 0 or code == 217 or code == 218 then break end
            scanned = scanned + 2
            if code ~= 1 and (code < 208 or code > 215) then
                local length_bytes = file:read(2)
                if not length_bytes or #length_bytes ~= 2 then break end
                local length = byte(length_bytes, 1) * 256 + byte(length_bytes, 2)
                if length < 2 or scanned + length > 1048576 then break end
                local is_frame = (code >= 192 and code <= 195)
                    or (code >= 197 and code <= 199)
                    or (code >= 201 and code <= 203)
                    or (code >= 205 and code <= 207)
                if is_frame and length >= 7 then
                    local size = file:read(5)
                    if size and #size == 5 then
                        height = byte(size, 2) * 256 + byte(size, 3)
                        width = byte(size, 4) * 256 + byte(size, 5)
                        if width < 1 or height < 1 or width > 20000 or height > 20000 then
                            width, height = nil, nil
                        end
                    end
                    break
                end
                if not file:seek("cur", length - 2) then break end
                scanned = scanned + length
            end
        end
    end
    file:close()
    return width, height
end

return ImageDimensions
