local NativeGrid = require("mangaweb.ui.native_grid")
local NativeDetail = require("mangaweb.ui.native_detail")

local function widget_class(created)
    local class = {}
    class.__index = class
    function class:new(options)
        local object = setmetatable(options or {}, self)
        if created then created[#created + 1] = object end
        if object.init then object:init() end
        return object
    end
    function class:extend(definition)
        local child = definition or {}
        child.__index = child
        return setmetatable(child, { __index = self })
    end
    function class:getSize() return self.dimen or { w = self.width or 600, h = self.height or 50 } end
    function class:free() self.freed = true end
    return class
end

local buttons = {}
local Input = widget_class()
function Input:paintTo() end
local Button = widget_class(buttons)
local Box = widget_class()
local TextBox = widget_class()
function TextBox:getFontSizeToFitHeight() return 18 end
local Scroll = widget_class()
function Scroll:getScrollbarWidth() return 0 end
local screen = {
    getWidth = function() return 600 end,
    getHeight = function() return 800 end,
    getSize = function() return { w = 600, h = 800 } end,
    scaleBySize = function(_, value) return value end,
}
local deps = {
    input_container = Input, button = Button, frame_container = Box,
    center_container = Box, horizontal_group = Box, vertical_group = Box,
    overlap_group = Box, image_widget = Box, rect_span = Box,
    title_bar = Box, text_box_widget = TextBox,
    scrollable_container = Scroll,
    geom = { new = function(_, value) return value end },
    gesture_range = { new = function(_, value) return value end },
    screen = screen, font = { getFace = function() return { size = 18 } end },
    blitbuffer = { COLOR_WHITE = "white" },
    ui_manager = { setDirty = function() end },
}

local chosen, multi, managed = nil, 0, 0
local grid_model = {
    page = "library", show_filters = false, show_pagination = false,
    grid = { cells = { { comic_id = "a", title = "A" } } },
    tabs = {
        { name = "默认", id = nil, active = true },
        { name = "待读", id = 7 },
    },
    actions = {
        select_category = function(id) chosen = id end,
        begin_selection = function() multi = multi + 1 end,
        manage_categories = function() managed = managed + 1 end,
    },
}
local grid = assert(NativeGrid:new(deps):show(grid_model))
assert(grid.channel_row and grid.channel_row[1].text == "[默认]"
    and grid.channel_row[2].text == "待读",
    "the favorites toolbar must show Default and category names")
grid.channel_row[2].callback()
assert(chosen == 7, "category tabs must switch the collection filter")
local multi_button, manage_button
for _, button in ipairs(grid.channel_row) do
    if button.text == "多选" then multi_button = button end
    if button.text == "管理分类" then manage_button = button end
end
assert(multi_button and manage_button)
multi_button.callback()
manage_button.callback()
assert(multi == 1 and managed == 1)

grid_model.selecting = true
grid_model.selection_count = 1
grid_model.grid.cells[1].selected = true
grid_model.actions.cancel_selection = function() multi = multi - 1 end
grid_model.actions.choose_batch_category = function() chosen = "batch" end
local cover = { freed = 0, free = function(self) self.freed = self.freed + 1 end }
assert(grid:set_cover(1, cover))
assert(grid:update_model(grid_model))
assert(cover.freed == 0 and grid.cells[1].buffer == cover,
    "selecting a comic must retain its downloaded cover")
assert(grid.cells[1].selected_badge, "selected comics need a visible marker")
assert(not grid.cells[1].favorite_badge, "collection covers must have no star box")
local adjust
for _, button in ipairs(grid.channel_row or {}) do
    if button.text == "调整分类" then adjust = button end
end
assert(adjust, "selection mode must expose a batch category action")
adjust.callback()
assert(chosen == "batch")

buttons = {}
local favorite, reading = 0, 0
local detail_deps = {}
for key, value in pairs(deps) do detail_deps[key] = value end
detail_deps.on_favorite = function() favorite = favorite + 1 end
local detail = assert(NativeDetail:new(detail_deps):show{
    page = "detail", detail = { card = { title = "漫画" } },
    state = "ready", can_read = true,
    actions = { start_reading = function() reading = reading + 1 end },
})
local favorite_button, reading_button
for _, button in ipairs(detail.footer) do
    if button.text == "收藏" then favorite_button = button end
    if button.text == "开始阅读" then reading_button = button end
    assert(button.text ~= "分类架", "details must not show a separate shelf button")
end
assert(favorite_button and reading_button and #detail.footer == 2)
favorite_button.callback()
reading_button.callback()
assert(favorite == 1 and reading == 1,
    "the two detail actions must retain favorite and reading behavior")

local chapters, chosen_chapter = {}, nil
for index = 1, 13 do
    chapters[index] = { id = tostring(index), title = "第" .. tostring(index) .. "话" }
end
local chapter_detail = assert(NativeDetail:new(detail_deps):show{
    page = "detail", detail = { card = { title = "章节网格" } },
    chapters = chapters, selected_chapter_id = "3", state = "ready",
    actions = { select_chapter = function(value) chosen_chapter = value.id end },
})
assert(chapter_detail.chapter_grid and #chapter_detail.chapter_grid == 3,
    "13 chapters must wrap into three rows")
assert(#chapter_detail.chapter_grid[1] == 6
    and #chapter_detail.chapter_grid[2] == 6
    and #chapter_detail.chapter_grid[3] == 1,
    "chapter rows must contain 6, 6 and 1 buttons")
assert(chapter_detail.chapter_grid[1][3].text:find("●", 1, true)
    and chapter_detail.chapter_grid[1][3].bordersize > chapter_detail.chapter_grid[1][2].bordersize,
    "the selected chapter needs a readable marker and stronger border")
chapter_detail.chapter_grid[2][1].callback()
assert(chosen_chapter == "7", "grid chapter buttons must retain selection behavior")

grid_model.selecting, grid_model.official, grid_model.busy = false, true, false
grid_model.actions.refresh = function() chosen = 'refresh' end
grid_model.actions.choose_official_removal = function() chosen = 'remove' end
assert(grid:update_model(grid_model))
local refresh, remove, local_tools = nil, nil, false
for _, b in ipairs(grid.channel_row) do
    if b.text == '刷新' then refresh = b end
    if b.text == '取消收藏' then remove = b end
    if b.text == '多选' or b.text == '管理分类' then local_tools = true end
end
assert(refresh and remove and not local_tools, 'official tab needs its own remote actions')
refresh.callback(); assert(chosen == 'refresh')
remove.callback(); assert(chosen == 'remove')
grid_model.busy = true
assert(grid:update_model(grid_model))
for _, b in ipairs(grid.channel_row) do
    if b.text == '刷新' or b.text == '取消收藏' then assert(b.enabled == false) end
end
print("native_collection_ui_spec: passed")
