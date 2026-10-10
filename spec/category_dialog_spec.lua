local Adapter = require("mangaweb.ui.koreader")

local function widget_class()
    local class = {}
    class.__index = class
    function class:new(options)
        local object = setmetatable(options or {}, self)
        if object.init then object:init() end
        return object
    end
    function class:extend(definition)
        local child = definition or {}
        child.__index = child
        return setmetatable(child, { __index = self })
    end
    function class:getSize() return self.dimen or { w = self.width or 600, h = self.height or 50 } end
    function class:free() end
    return class
end

local manager = { shown = {}, closed = {} }
function manager:show(widget) self.shown[#self.shown + 1] = widget; return true end
function manager:close(widget) self.closed[#self.closed + 1] = widget; return true end
function manager:setDirty() return true end
local Base = widget_class()
local Scroll = widget_class()
function Scroll:getScrollbarWidth() return 0 end
local adapter = Adapter:new{
    ui_manager = manager, menu = Base, device = { input = { group = {} } },
    input_container = Base, button = Base, frame_container = Base,
    center_container = Base, overlap_group = Base, image_widget = Base,
    horizontal_group = Base, vertical_group = Base, title_bar = Base,
    scrollable_container = Scroll, text_box_widget = Base, font = {
        getFace = function() return { size = 18 } end,
    },
    rect_span = Base, geom = { new = function(_, value) return value end },
    gesture_range = { new = function(_, value) return value end },
    screen = { getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        getSize = function() return { w = 600, h = 800 } end },
    blitbuffer = { COLOR_WHITE = "white" },
}
local selected, removed = "unset", 0
local category = { id = 7, name = "待读" }
local detail_model = {
    page = "detail", detail = { card = { favorite = true } },
    selected_category_id = 7,
    actions = {
        categories = function() return { category } end,
        select_category = function(value) selected = value and value.id or nil; return true end,
        toggle_favorite = function() removed = removed + 1; return true end,
        create_category = function() return true end,
    },
}
assert(adapter:_show_favorite_picker(detail_model))
local picker = manager.shown[#manager.shown]
assert(picker.model.modal and picker.model.rows[1].text == "默认"
    and picker.model.rows[2].text == "[待读]",
    "the detail favorite picker must show Default and the selected category")
picker.model.rows[1].callback()
assert(selected == nil and manager.closed[#manager.closed] == picker,
    "choosing Default must save an unclassified favorite and close the picker")
assert(adapter:_show_favorite_picker(detail_model))
picker = manager.shown[#manager.shown]
local cancel_favorite
for _, item in ipairs(picker.model.actions or {}) do
    if item.text == "取消收藏" then cancel_favorite = item end
end
assert(cancel_favorite, "a collected comic needs a remove action in the picker")
cancel_favorite.callback()
assert(removed == 1, "canceling a favorite must use the detail model action")

local batch_choice = "unset"
assert(adapter:_show_batch_category_picker{
    tabs = { { id = nil, name = "默认" }, category },
    actions = {
        assign_selected = function(value)
            batch_choice = value and value.id or nil
            return true
        end,
    },
})
picker = manager.shown[#manager.shown]
picker.model.rows[2].callback()
assert(batch_choice == 7,
    "batch selection must be able to move every selected comic to a category")

local renamed, deleted = 0, 0
local panel = assert(adapter:_build_panel{
    page = "categories", items = { category }, actions = {
        create = function() return true end,
        rename = function() renamed = renamed + 1; return true end,
        remove = function() deleted = deleted + 1; return true end,
        back = function() return true end,
    },
})
local row = panel.model.rows[1]
assert(row.kind == "actions" and #row.items == 3,
    "category management must expose open, rename and delete controls")
row.items[3].callback()
local confirmation = manager.shown[#manager.shown]
assert(confirmation.model.status:find("待读", 1, true)
    and deleted == 0, "deleting a category must first show its name in confirmation")
confirmation.model.actions[1].callback()
assert(deleted == 0, "canceling the confirmation must preserve the category")
row.items[3].callback()
confirmation = manager.shown[#manager.shown]
confirmation.model.actions[2].callback()
assert(deleted == 1, "confirming removal must delete exactly once")

adapter.shell = { registry = {
    current = function() return { meta = function() return { name = "Zero" } end } end,
} }
local detail = assert(adapter:_build_detail(detail_model))
local shown_before = #manager.shown
detail.footer[1].callback()
assert(#manager.shown == shown_before + 1
    and manager.shown[#manager.shown].model.page == "category_picker",
    "the actual detail favorite button must open the category picker")
local fallback_detail = adapter:_items_for(detail_model)
local fallback_favorite
for _, item in ipairs(fallback_detail) do
    if item.text == "收藏" or item.text == "已收藏" then fallback_favorite = item end
end
assert(fallback_favorite, "fallback detail must offer the category picker")
shown_before = #manager.shown
fallback_favorite.callback()
assert(#manager.shown == shown_before + 1
    and manager.shown[#manager.shown].model.page == "category_picker",
    "fallback detail must open the same category picker")

local collection_model = {
    page = "library", items = {
        { site_id = "zero", comic_id = "a", title = "A", cover_url = "https://img/a.jpg",
            selected = true },
    }, tabs = { { name = "默认" }, category },
    actions = { assign_selected = function() return true end },
}
local collection = assert(adapter:_build_collection_grid(collection_model))
assert(collection.channel_row and type(collection_model.actions.choose_batch_category) == "function",
    "the actual collection toolbar must connect batch assignment to its picker")
assert(collection_model.grid.cells[1].selected == true,
    "the adapter must pass selected comics to the visible grid")
local fallback_collection = adapter:_items_for(collection_model)
local has_default, has_category, has_multi = false, false, false
for _, item in ipairs(fallback_collection) do
    if item.text == "默认" then has_default = true end
    if item.text == "待读" then has_category = true end
    if item.text == "多选" then has_multi = true end
end
assert(has_default and has_category and has_multi,
    "fallback collection must keep category tabs and batch selection available")
local cover_requests = 0
adapter.loader = {
    begin_session = function() return 1 end,
    request = function()
        cover_requests = cover_requests + 1
        return { cancel = function() end }
    end,
    cancel_generation = function() return true end,
}
assert(collection:set_cover(1, { free = function() end }))
assert(adapter:_load_covers(collection_model, collection))
assert(cover_requests == 0,
    "updating selection must not download an already visible cover again")

local custom_grid = assert(adapter:_build_native_grid{
    page = "browse", site = { name = "个人站点" },
    channels = { { id = "home", name = "首页", active = true } },
    grid = { cells = {} }, state = "empty", actions = {},
})
assert(custom_grid.title_controls.search.enabled == false,
    "unsupported search must be disabled on the visible browse title")
assert(#custom_grid.channel_row == 1 and custom_grid.channel_row[1].width == 600,
    "a site without filters should give the home channel the full row")

adapter.multi_input_dialog = Base
local changed, removed_site = 0, 0
local site_model = {
    page = "site_center", sites = {
        { id = "zero", name = "Zero", origin = "https://zero.example.com",
            on_open = function() end, on_config = function() end },
        { id = "custom-1", name = "我的站", origin = "https://example.com",
            custom = true, definition = {
                id = "custom-1", name = "我的站", origin = "https://example.com", rules = {},
            }, on_open = function() end, on_config = function() end },
    }, actions = {
        add_site = function() return true end,
        update_site = function() changed = changed + 1; return true end,
        remove_site = function() removed_site = removed_site + 1; return true end,
    },
}
local sites_panel = assert(adapter:_build_panel(site_model))
local edit_button = sites_panel.model.rows[5].items[1]
local delete_button = sites_panel.model.rows[5].items[2]
assert(edit_button.text == "编辑规则" and delete_button.text == "删除站点",
    "a custom site needs visible edit and remove controls")
edit_button.callback()
assert(adapter.input_dialog and adapter.input_dialog.fields
    and adapter.input_dialog.title:find("1/4", 1, true),
    "editing a site must open the grouped rule form")
delete_button.callback()
local site_confirmation = manager.shown[#manager.shown]
assert(site_confirmation.model.status:find("我的站", 1, true)
    and removed_site == 0, "site removal needs named confirmation")
site_confirmation.model.actions[2].callback()
assert(removed_site == 1)
local settings_panel = assert(adapter:_build_panel{
    page = "settings", site_id = "zero", origin = "https://zero.example.com",
    actions = { set_origin = function() return true end, back = function() end },
})
local domain_button
for _, row in ipairs(settings_panel.model.rows) do
    if row.text == "修改域名" then domain_button = row end
end
assert(domain_button, "Zero settings must show a domain edit button")
domain_button.callback()
assert(adapter.input_dialog and adapter.input_dialog.fields[1].text == "https://zero.example.com")

print("category_dialog_spec: passed")
