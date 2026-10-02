local CategoryShelf = {}
CategoryShelf.__index = CategoryShelf

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

function CategoryShelf:new(options)
    options = options or {}
    return setmetatable({
        store = assert(options.store, "store is required"),
        shell = assert(options.shell, "shell is required"),
        site_id = assert(options.site_id, "site_id is required"),
        view_token = options.view_token,
        return_category_id = options.return_category_id,
    }, self)
end

function CategoryShelf:show(category)
    if category then
        local items = {}
        for _, record in ipairs(self.store:list_category_items(self.site_id, category.id) or {}) do
            local item = copy(record)
            item.on_tap = function()
                return self.shell:show_detail(record, {
                    return_page = "categories", return_options = { category = category },
                })
            end
            items[#items + 1] = item
        end
        return self.shell:set_model({
            page = "category_items", category = category, items = items,
            state = #items == 0 and "empty" or "ready",
            actions = { back = function() return self:show() end },
        }, self.view_token)
    end

    local items = {}
    for _, category_item in ipairs(self.store:list_categories(self.site_id) or {}) do
        local item = copy(category_item)
        item.on_tap = function() return self:show(category_item) end
        items[#items + 1] = item
    end
    return self.shell:set_model({
        page = "categories", items = items, state = #items == 0 and "empty" or "ready",
        actions = {
            create = function(name)
                local created, error_code = self.store:create_category(self.site_id, name)
                if not created then return nil, error_code end
                return self:show()
            end,
            rename = function(category, name)
                if not category or not category.id then return false end
                local renamed = self.store:rename_category(self.site_id, category.id, name)
                if renamed == false then return false end
                return self:show()
            end,
            remove = function(category)
                if not category or not category.id then return false end
                local removed = self.store:remove_category(self.site_id, category.id)
                if removed == false then return false end
                if tonumber(self.return_category_id) == tonumber(category.id) then
                    self.return_category_id = nil
                end
                return self:show()
            end,
            back = function()
                return self.shell:show("library", { category_id = self.return_category_id })
            end,
        },
    }, self.view_token)
end

return CategoryShelf
