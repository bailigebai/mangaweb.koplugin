local NativeRoot = {}
NativeRoot.__index = NativeRoot

local function retire(widget)
    if not widget or widget.retired then return end
    widget.retired = true
    widget.on_layout_changed = nil
    if type(widget.onCloseWidget) == "function" then pcall(widget.onCloseWidget, widget) end
end

local function cascade_show_parent(widget, parent, seen)
    if type(widget) ~= "table" then return end
    seen = seen or {}
    if seen[widget] then return end
    seen[widget] = true
    widget.show_parent = parent
    for _, child in ipairs(widget) do
        cascade_show_parent(child, parent, seen)
    end
end

function NativeRoot:new(deps)
    deps = deps or {}
    local self = setmetatable({ deps = deps, root_widget = nil, content = nil, closed = false }, NativeRoot)
    local Input = deps.input_container
    local screen = deps.screen
    local screen_w = screen and type(screen.getWidth) == "function" and screen:getWidth() or nil
    local screen_h = screen and type(screen.getHeight) == "function" and screen:getHeight() or nil
    local function bind_content(root, content)
        root.cropping_widget = content and content.cropping_widget or nil
        cascade_show_parent(content, root)
        if root.cropping_widget then root.cropping_widget.show_parent = root end
        if content then
            content.on_layout_changed = function(updated)
                if root.content ~= updated then return false end
                bind_content(root, updated)
                if deps.ui_manager and deps.ui_manager.setDirty then
                    pcall(deps.ui_manager.setDirty, deps.ui_manager, root, "ui")
                end
                return true
            end
        end
        return true
    end
    if Input and Input.extend then
        local RootWidget = Input:extend{ modal = true, fullscreen = true, covers_fullscreen = true }
        function RootWidget:set_content(content, on_back)
            local previous = self.content
            self.content, self.on_back = content, on_back
            -- Every child that asks KOReader to repaint must point at the
            -- window-level widget passed to UIManager:show(). The child may
            -- rebuild its ScrollableContainer in place after an async model
            -- update, so keep that binding live instead of retaining the
            -- first (now stale) cropping widget.
            bind_content(self, content)
            self[1] = deps.frame_container and deps.frame_container:new{
                width = screen_w or self.width, height = screen_h or self.height, margin = 0, padding = 0,
                bordersize = 0, background = deps.blitbuffer and deps.blitbuffer.COLOR_WHITE,
                content,
            } or content
            if previous and previous ~= content then retire(previous) end
            if deps.ui_manager and deps.ui_manager.setDirty then
                pcall(deps.ui_manager.setDirty, deps.ui_manager, self, "ui")
            end
            return true
        end
        function RootWidget:onBack()
            return type(self.on_back) == "function" and self.on_back() or true
        end
        self.root_widget = RootWidget:new{}
    else
        self.root_widget = { fullscreen = true, covers_fullscreen = true,
            background = deps.blitbuffer and deps.blitbuffer.COLOR_WHITE,
            width = screen_w, height = screen_h }
    function self.root_widget:set_content(content, on_back)
            local previous = self.content
            self.content, self.on_back = content, on_back
            bind_content(self, content)
            if previous and previous ~= content then retire(previous) end
            return true
        end
        function self.root_widget:onBack()
            return type(self.on_back) == "function" and self.on_back() or true
        end
    end
    local gesture_range = deps.gesture_range
    local screen_range = screen and type(screen.getSize) == "function" and screen:getSize() or nil
    if gesture_range and type(gesture_range.new) == "function" and screen_range then
        self.root_widget.ges_events = self.root_widget.ges_events or {}
        self.root_widget.ges_events.RootTap = {
            gesture_range:new{ ges = "tap", range = screen_range },
        }
        function self.root_widget:onRootTap(_, gesture)
            local current = self.content
            if current and type(current.onDetailTap) == "function" then
                return current:onDetailTap(nil, gesture)
            end
            return false
        end
    end
    return self
end

function NativeRoot:show(content, on_back)
    self.closed = false
    self:replace(content, on_back)
    local manager = self.deps.ui_manager
    if not self.shown and manager and manager.show then
        manager:show(self.root_widget)
        self.shown = true
    end
    return true
end

function NativeRoot:replace(content, on_back)
    if self.closed then return false end
    self.content, self.on_back = content, on_back
    return self.root_widget:set_content(content, on_back)
end

function NativeRoot:close()
    if self.closed then return true end
    self.closed = true
    retire(self.content)
    self.root_widget.cropping_widget = nil
    local manager = self.deps.ui_manager
    if self.shown and manager and manager.close then
        self.root_widget.skip_close_callback = true
        manager:close(self.root_widget)
    end
    self.shown = false
    return true
end

function NativeRoot:widget()
    return self.content
end

return NativeRoot
