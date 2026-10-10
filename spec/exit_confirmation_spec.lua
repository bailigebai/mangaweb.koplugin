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
    center_container = Base, horizontal_group = Base, vertical_group = Base,
    image_widget = Base, rect_span = Base, title_bar = Base,
    scrollable_container = Scroll, text_box_widget = Base,
    font = { getFace = function() return { size = 18 } end },
    geom = { new = function(_, value) return value end },
    screen = { getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        getSize = function() return { w = 600, h = 800 } end },
    blitbuffer = { COLOR_WHITE = "white" },
}
local close_count = 0
adapter.shell = { close = function() close_count = close_count + 1; return true end }

local detail = assert(adapter:_build_detail{
    page = "detail", state = "ready", detail = { card = { title = "A" } },
})
assert(detail.title_bar.right_icon_tap_callback())
local prompt = manager.shown[#manager.shown]
assert(prompt.model.status == "确定退出插件？" and close_count == 0,
    "the detail close icon must show confirmation before closing")
prompt.model.actions[1].callback()
assert(close_count == 0 and manager.closed[#manager.closed] == prompt,
    "Cancel must keep the plugin open")

assert(detail.title_bar.right_icon_tap_callback())
prompt = manager.shown[#manager.shown]
assert(prompt.model.actions[2].text == "确定退出插件")
prompt.model.actions[2].callback()
assert(close_count == 1, "Confirm must close the plugin exactly once")

local panel = assert(adapter:_build_panel{
    page = "categories", items = {}, actions = { back = function() return true end },
})
local before = #manager.shown
assert(panel.model.on_close())
assert(#manager.shown == before + 1
    and manager.shown[#manager.shown].model.status == "确定退出插件？",
    "other page close icons must share the same confirmation")

print("exit_confirmation_spec: passed")
