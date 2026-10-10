local Library = require("mangaweb.ui.library")
local Detail = require("mangaweb.ui.detail")
local CategoryShelf = require("mangaweb.ui.category_shelf")
local Shell = require("mangaweb.ui.shell")

local categories = {
    { id = 7, site_id = "zero", name = "待读" },
    { id = 8, site_id = "zero", name = "已读" },
}
local favorites = {
    { site_id = "zero", comic_id = "a", title = "A" },
    { site_id = "zero", comic_id = "b", title = "B" },
}
local assigned = {}
local store = {}
function store:list_categories() return categories end
function store:list_favorites() return favorites end
function store:list_category_items(_, category_id)
    local items = {}
    for _, item in ipairs(favorites) do
        if assigned[item.comic_id] == category_id then items[#items + 1] = item end
    end
    return items
end
function store:assign_category(_, ids, category_id)
    for _, id in ipairs(ids) do assigned[id] = category_id end
    return true
end
function store:is_favorite(_, comic_id)
    for _, item in ipairs(favorites) do if item.comic_id == comic_id then return true end end
    return false
end
function store:add_favorite(card)
    favorites[#favorites + 1] = card
    return true
end
function store:remove_favorite(_, comic_id)
    for index, item in ipairs(favorites) do
        if item.comic_id == comic_id then table.remove(favorites, index); break end
    end
    assigned[comic_id] = nil
    return true
end
function store:category_for(_, comic_id) return assigned[comic_id] end
function store:create_category(_, name)
    local category = { id = 9, site_id = "zero", name = name }
    categories[#categories + 1] = category
    return category
end
function store:rename_category(_, id, name)
    for _, category in ipairs(categories) do
        if category.id == id then category.name = name; return true end
    end
    return false
end
function store:remove_category(_, id)
    for index, category in ipairs(categories) do
        if category.id == id then table.remove(categories, index); break end
    end
    for comic, value in pairs(assigned) do if value == id then assigned[comic] = nil end end
    return true
end

local shell = {}
local model
function shell:set_model(value) model = value; return true end
function shell:model() return model end
function shell:show(page, options) self.last_page, self.last_options = page, options; return true end
function shell:show_detail(card, options)
    self.opened, self.detail_options = card, options
    return true
end
local registry = { current_id = function() return "zero" end }
local library = Library:new{ source_registry = registry, store = store, shell = shell }
assert(library:show())
assert(model.page == "library" and model.tabs[1].name == "默认"
    and model.tabs[2].name == "待读" and #model.items == 2,
    "favorites must expose Default and category tabs")
model.items[1].on_tap()
assert(shell.opened.comic_id == "a" and shell.detail_options.return_page == "library",
    "a favorite must open details and preserve its collection route")
assert(model.actions.select_category(7))
assert(model.category_id == 7 and #model.items == 0,
    "a category tab must filter favorites")
assert(model.actions.select_category(nil))
assert(model.category_id == nil and #model.items == 2,
    "Default must always show every favorite")
assert(model.actions.begin_selection())
model.items[1].on_tap()
model.items[2].on_tap()
assert(model.selection_count == 2 and shell.opened.comic_id == "a",
    "multi-select taps must select comics instead of opening details")
assert(model.actions.assign_selected(categories[1]))
assert(assigned.a == 7 and assigned.b == 7
    and model.category_id == 7 and model.selection_count == 0,
    "one batch action must move all selected comics and show the destination")
model.actions.manage_categories()
assert(shell.last_page == "categories", "category management must be reachable from favorites")

local detail_shell = {}
local detail_model
function detail_shell:set_model(value) detail_model = value; return true end
function detail_shell:model() return detail_model end
local detail = Detail:new{ store = store, shell = detail_shell }
assert(detail:show{ site_id = "zero", comic_id = "c", title = "C" })
assert(detail_model.selected_category_id == nil)
assert(detail_model.actions.select_category(categories[2]))
assert(store:is_favorite("zero", "c") and assigned.c == 8
    and detail_model.selected_category_id == 8,
    "choosing a category in details must also collect the comic")
assert(detail_model.actions.select_category(nil))
assert(assigned.c == nil and store:is_favorite("zero", "c"),
    "choosing Default keeps a comic collected without a custom category")
assert(detail_model.actions.create_category("新分类"))
assert(assigned.c == 9 and detail_model.selected_category_id == 9,
    "creating a category in details must assign it to the current comic")
assert(detail_model.actions.toggle_favorite())
assert(not store:is_favorite("zero", "c") and assigned.c == nil,
    "removing the favorite must clear its category")

local shelf = CategoryShelf:new{ store = store, shell = shell, site_id = "zero" }
assert(shelf:show())
assert(model.actions.rename(categories[1], "稍后看"))
assert(categories[1].name == "稍后看", "category names must be editable")
assert(model.actions.remove(categories[1]))
assert(#categories == 2 and #favorites == 2,
    "removing a category must leave its comics in the collection")

local routed = Shell:new{ source_registry = registry, store = store,
    ui = { update_model = function() return true end } }
assert(routed:show("library", { category_id = 8 }))
assert(routed:model().category_id == 8,
    "returning from details must restore the selected category tab")
assert(routed:show("categories", { return_category_id = 8 }))
assert(routed:model().page == "categories")
routed:model().actions.back()
assert(routed:model().page == "library" and routed:model().category_id == 8,
    "category management must return to the previous collection tab")

print("collection_model_spec: passed")
