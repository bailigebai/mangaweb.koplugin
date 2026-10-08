local Adapter = require("mangaweb.ui.koreader")

local function widget_class()
    local class = {}
    class.__index = class
    function class:new(options)
        local object = setmetatable(options or {}, self)
        if object._init then object:_init() end
        if object.init then object:init() end
        return object
    end
    function class:extend(options)
        local child = options or {}
        child.__index = child
        return setmetatable(child, { __index = self })
    end
    function class:getSize()
        return self.dimen or { w = self.width or 600, h = self.height or 40 }
    end
    function class:free()
        self.freed = true
        for _, child in ipairs(self) do if child.free then child:free() end end
    end
    return class
end

local function fixture()
    local Base = widget_class()
    local Input = Base:extend{}
    function Input:_init()
        self.key_events = self.key_events or {}
        self.ges_events = self.ges_events or {}
    end
    -- KOReader InputContainer:onGesture iterates ges_events with pairs,
    -- including gestures not consumed by a child. It requires a table.
    function Input:onGesture(gesture)
        for name, ranges in pairs(self.ges_events) do
            for _, range in ipairs(ranges) do
                if range:match(gesture) then
                    local handler = self["on" .. name]
                    if handler and handler(self, nil, gesture) then return true end
                end
            end
        end
        return self.stop_events_propagation or false
    end
    function Input:paintTo() end
    local Scroll = Base:extend{}
    function Scroll:getScrollbarWidth() return 0 end
    local manager = { stack = {} }
    function manager:show(widget)
        -- Non-modal windows go below existing modal windows in KOReader.
        local index = #self.stack + 1
        if not widget.modal then
            for position, current in ipairs(self.stack) do
                if current.modal then index = position; break end
            end
        end
        table.insert(self.stack, index, widget)
        return true
    end
    function manager:close(widget)
        for index, current in ipairs(self.stack) do
            if current == widget then table.remove(self.stack, index); break end
        end
        return true
    end
    function manager:setDirty() return true end
    local Menu = Base:extend{}
    -- Native Menu executes the choice, then its close_callback. Some choices
    -- replace the current menu with a new window during that first callback.
    function Menu:onMenuSelect(item)
        if item.select_enabled == false then return true end
        if item.callback then item.callback() end
        if self.close_callback then self.close_callback() end
        return true
    end
    local adapter = Adapter:new{
        ui_manager = manager, input_container = Input, menu = Menu, button = Base,
        frame_container = Base, center_container = Base, overlap_group = Base,
        horizontal_group = Base, vertical_group = Base, title_bar = Base,
        image_widget = Base, text_widget = Base, text_box_widget = Base,
        rect_span = Base, scrollable_container = Scroll, single_input_dialog = Base,
        font = { getFace = function() return {} end },
        geom = { new = function(_, value) return value end },
        device = { input = { group = {} } },
        screen = { getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getSize = function() return { w = 600, h = 800 } end },
        blitbuffer = { COLOR_WHITE = "white" },
        gesture_range = { new = function(_, value)
            function value:match(gesture) return gesture.ges == self.ges end
            return value
        end },
    }
    local values = { direction = "ltr", preload_pages = 3, fit_mode = "page" }
    local reader = { position = 11, closed = false, turns = 0 }
    function reader:settings_snapshot() return values end
    function reader:current_page() return self.position end
    function reader:update_settings(changes)
        for key, value in pairs(changes) do values[key] = value end
        return true
    end
    function reader:next() self.turns = self.turns + 1; return true end
    function reader:close() self.closed = true; return adapter:close_reader() end
    adapter.reader = reader
    assert(adapter:show_page_loading(11, 178))
    return adapter, reader, manager
end

return fixture
