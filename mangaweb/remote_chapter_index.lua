local Index = {}
Index.__index = Index

local function page_name(page, position)
    local supplied = tostring(page.name or "")
    if supplied ~= "" then return supplied end
    local clean = tostring(page.url or ""):gsub("[?#].*$", "")
    local name = clean:match("([^/]+)$")
    if name and name:match("%.[%w]+$") then return name end
    return ("%04d.jpg"):format(position)
end

function Index:new(options)
    options = options or {}
    local prefix = tostring(options.path_prefix or "mangaweb://remote")
        :gsub("/+$", "")
    local object = setmetatable({ pages = {}, by_path = {}, path_prefix = prefix }, self)
    for position, page in ipairs(options.pages or {}) do
        if type(page) == "table" and tostring(page.url or "") ~= "" then
            local name = page_name(page, position)
            local path = prefix .. "/" .. name
            if object.by_path[path] then
                local stem, extension = name:match("^(.*)(%.[^.]*)$")
                name = (stem or name) .. "-" .. position .. (extension or "")
                path = prefix .. "/" .. name
            end
            local headers = {}
            for key, value in pairs(page.headers or {}) do headers[key] = value end
            local record = {
                index = tonumber(page.index) or position,
                name = name,
                path = path,
                url = tostring(page.url),
                headers = headers,
                is_file = true,
            }
            object.pages[#object.pages + 1] = record
            object.by_path[path] = #object.pages
        end
    end
    return object
end

function Index:count() return #self.pages end

function Index:get(index)
    index = tonumber(index)
    if not index or index < 1 or index > #self.pages or index ~= math.floor(index) then
        return nil
    end
    return self.pages[index]
end

function Index:find(path, hint_index)
    local hint = tonumber(hint_index)
    if hint and self:get(hint) and self:get(hint).path == path then return hint end
    return self.by_path[path]
end

function Index:window(center, radius)
    local count = #self.pages
    center = math.max(1, math.min(count, math.floor(tonumber(center) or 1)))
    radius = math.max(0, math.floor(tonumber(radius) or 0))
    local result = {}
    for index = math.max(1, center - radius), math.min(count, center + radius) do
        result[#result + 1] = self.pages[index]
    end
    return result
end

return Index
