local Library = {}
Library.__index = Library

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

function Library:new(options)
    options = options or {}
    return setmetatable({
        source_registry = options.source_registry,
        store = options.store,
        shell = options.shell,
        view_token = options.view_token,
        category_id = options.category_id,
        selecting = false,
        selected = {},
    }, self)
end

function Library:toggle_selected(comic_id)
    if not self.selecting then return false end
    comic_id = tostring(comic_id or "")
    self.selected[comic_id] = not self.selected[comic_id] or nil
    return self:show()
end

function Library:show()
    local site_id = self.source_registry:current_id()
    local categories = self.store and self.store:list_categories(site_id) or {}
    if self.category_id ~= nil then
        local found = false
        for _, category in ipairs(categories) do
            if tonumber(category.id) == tonumber(self.category_id) then found = true; break end
        end
        if not found then self.category_id = nil end
    end
    local tabs = { { name = "默认", id = nil, active = self.category_id == nil } }
    for _, category in ipairs(categories) do
        tabs[#tabs + 1] = { name = category.name, id = category.id,
            active = tonumber(category.id) == tonumber(self.category_id) }
    end
    local records = self.category_id == nil
        and (self.store and self.store:list_favorites(site_id) or {})
        or (self.store and self.store:list_category_items(site_id, self.category_id) or {})
    local items, count = {}, 0
    for _, record in ipairs(records) do
        local item = copy(record)
        local comic_id = tostring(item.comic_id or "")
        item.selected = self.selected[comic_id] == true
        if item.selected then count = count + 1 end
        item.on_tap = function()
            if self.selecting then return self:toggle_selected(comic_id) end
            return self.shell:show_detail(record, {
                return_page = "library", return_options = { category_id = self.category_id },
            })
        end
        items[#items + 1] = item
    end
    local model = {
        page = "library", items = items, state = #items == 0 and "empty" or "ready",
        tabs = tabs, category_id = self.category_id,
        selecting = self.selecting, selection_count = count,
        actions = {
            select_category = function(category_id)
                if self.selecting then return false end
                self.category_id = category_id
                return self:show()
            end,
            begin_selection = function()
                self.selecting, self.selected = true, {}
                return self:show()
            end,
            cancel_selection = function()
                self.selecting, self.selected = false, {}
                return self:show()
            end,
            assign_selected = function(category)
                if not self.selecting then return false end
                local ids = {}
                for _, record in ipairs(records) do
                    if self.selected[tostring(record.comic_id or "")] then
                        ids[#ids + 1] = record.comic_id
                    end
                end
                if #ids == 0 then return false end
                local category_id = category and category.id or nil
                local saved = self.store:assign_category(site_id, ids, category_id)
                if saved == false then return false end
                self.category_id = category_id
                self.selecting, self.selected = false, {}
                return self:show()
            end,
            manage_categories = function()
                return self.shell:show("categories", { return_category_id = self.category_id })
            end,
        },
    }
    return self.shell:set_model(model, self.view_token)
end

return Library
