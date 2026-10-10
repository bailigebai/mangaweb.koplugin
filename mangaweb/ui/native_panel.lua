local NativePanel = {}
NativePanel.__index = NativePanel
local ButtonStyle = require("mangaweb.ui.button_style")

local function action(callback, on_error, ...)
    if type(callback) ~= "function" then return true end
    local ok, result = pcall(callback, ...)
    if not ok then
        if type(on_error) == "function" then pcall(on_error, result) end
        return true
    end
    if result == nil or result == false then return true end
    return result
end

function NativePanel:new(deps)
    return setmetatable({ deps = deps or {} }, self)
end

function NativePanel:ready()
    local d = self.deps
    return d.input_container and d.button and d.frame_container and d.horizontal_group
        and d.vertical_group and d.title_bar and d.rect_span and d.geom and d.screen
        and d.scrollable_container and d.text_box_widget and d.font and d.blitbuffer
end

function NativePanel:show(model)
    if not self:ready() then return nil end
    model = model or {}
    local d, owner = self.deps, self
    local body_ok, body_face = pcall(d.font.getFace, d.font, "cfont", 18)
    if not body_ok or not body_face then return nil end
    local section_ok, section_face = pcall(d.font.getFace, d.font, "cfont", 22)
    if not section_ok or not section_face then section_face = body_face end
    local PanelWidget = d.input_container:extend{
        modal = model.modal == true, fullscreen = true, covers_fullscreen = true,
    }
    local Button = ButtonStyle.extend(d.button, d.screen, d.blitbuffer)

    function PanelWidget:_navigation()
        local navigation = model.navigation or {}
        self.navigation_count = #navigation
        local group = d.horizontal_group:new{}
        if #navigation == 0 then return group end
        local width = math.floor(self.screen_w / #navigation)
        for index, item in ipairs(navigation) do
            group[#group + 1] = Button:new{
                text = item.active and "[" .. tostring(item.text) .. "]" or tostring(item.text),
                width = index == #navigation and self.screen_w - width * (#navigation - 1) or width,
                height = self.compact_h,
                callback = function() return action(item.callback, model.on_action_error) end,
            }
        end
        return group
    end

    function PanelWidget:_content(width)
        local content = d.vertical_group:new{}
        local compact_h = self.compact_h
        local function label(text, face)
            return d.text_box_widget:new{
                text = tostring(text or ""), face = face, width = width,
                show_parent = self,
            }
        end
        local function command(item, command_width)
            return Button:new{
                text = tostring(item.text or ""), width = command_width, height = compact_h,
                enabled = item.enabled ~= false, show_parent = self,
                callback = function() return action(item.callback, model.on_action_error) end,
                hold_callback = item.hold_callback and function()
                    return action(item.hold_callback,model.on_action_error)
                end or nil,
            }
        end
        local function command_row(items)
            items = items or {}
            local group = d.horizontal_group:new{}
            local count = math.max(1, #items)
            local item_width = math.floor(width / count)
            for index, item in ipairs(items) do
                group[#group + 1] = command(item,
                    index == count and width - item_width * (count - 1) or item_width)
            end
            return group
        end
        if model.status and model.status ~= "" then
            content[#content + 1] = label(model.status, body_face)
        end
        for _, row in ipairs(model.rows or {}) do
            if row.kind == "section" then
                content[#content + 1] = label(row.text, section_face)
            elseif row.kind == "info" then
                content[#content + 1] = label(row.text, body_face)
            elseif row.kind == "action" then
                content[#content + 1] = command(row, width)
            elseif row.kind == "actions" then
                content[#content + 1] = command_row(row.items)
            end
        end
        local actions = model.actions or {}
        if #actions == 1 then
            content[#content + 1] = command(actions[1], width)
        elseif #actions > 1 then
            content[#content + 1] = command_row(actions)
        end
        return content
    end

    function PanelWidget:init()
        local groups = d.device and d.device.input and d.device.input.group or {}
        if next(groups) then self.key_events = { Back = { { groups.Back or { "Back" } } } } end
        self.screen_w = math.max(1, d.screen:getWidth())
        self.screen_h = math.max(1, d.screen:getHeight())
        self.dimen = d.screen.getSize and d.screen:getSize()
            or d.geom:new{ w = self.screen_w, h = self.screen_h }
        self.model = model
        self.page_id = model.page
        self.compact_h = math.max(30,
            d.screen.scaleBySize and d.screen:scaleBySize(34) or 34)
        self:_rebuild()
    end

    function PanelWidget:_rebuild()
        local title = d.title_bar:new{
            title = model.title or "漫画网站", width = self.screen_w,
            with_bottom_line = true, left_icon = model.left_icon or "chevron.left",
            title_top_padding = 0, bottom_v_padding = 0, button_padding = 4,
            left_icon_allow_flash = false,
            left_icon_tap_callback = function() return action(model.on_back, model.on_action_error) end,
            right_icon = model.on_close and "close" or nil,
            right_icon_allow_flash = false,
            right_icon_tap_callback = function() return action(model.on_close, model.on_action_error) end,
        }
        local navigation = self:_navigation()
        local title_h, navigation_h = title:getSize().h, navigation:getSize().h
        self.body_height = math.max(1, self.screen_h - title_h - navigation_h)
        local scrollbar_width = d.scrollable_container.getScrollbarWidth
            and d.scrollable_container:getScrollbarWidth() or 0
        local content = self:_content(math.max(1, self.screen_w - scrollbar_width))
        self.cropping_widget = d.scrollable_container:new{
            dimen = d.geom:new{ w = self.screen_w, h = self.body_height },
            show_parent = self,
            content,
        }
        self.page_group = d.frame_container:new{
            width = self.screen_w, height = self.screen_h,
            margin = 0, padding = 0, bordersize = 0,
            background = d.blitbuffer.COLOR_WHITE,
            d.vertical_group:new{ title, self.cropping_widget, navigation },
        }
        self[1] = self.page_group
    end

    function PanelWidget:update_model(next_model)
        next_model = next_model or {}
        local next_page = next_model.page or self.page_id
        if self.closed or self.retired
            or self.page_id and next_page and self.page_id ~= next_page then return false end
        local offset
        if self.cropping_widget
            and type(self.cropping_widget.getScrolledOffset) == "function" then
            local ok, value = pcall(self.cropping_widget.getScrolledOffset, self.cropping_widget)
            if ok then offset = value end
        end
        if self.cropping_widget and type(self.cropping_widget.reset) == "function" then
            pcall(self.cropping_widget.reset, self.cropping_widget)
        end
        if self.page_group and self.page_group.free then pcall(self.page_group.free, self.page_group) end
        model = next_model
        self.model = model
        self.page_id = next_page
        self.paint_failed = false
        self:_rebuild()
        local scroll = self.cropping_widget
        if offset and scroll and type(scroll.reset) == "function"
            and type(scroll.initState) == "function"
            and type(scroll.setScrolledOffset) == "function" then
            scroll:reset()
            scroll:initState()
            scroll:setScrolledOffset{
                x = math.max(0, math.min(tonumber(offset.x) or 0,
                    tonumber(scroll._max_scroll_offset_x) or 0)),
                y = math.max(0, math.min(tonumber(offset.y) or 0,
                    tonumber(scroll._max_scroll_offset_y) or 0)),
            }
        end
        if d.ui_manager and d.ui_manager.setDirty then
            pcall(d.ui_manager.setDirty, d.ui_manager, self, "ui")
        end
        return true
    end

    function PanelWidget:paintTo(bb, x, y)
        if self.closed or self.retired or not self[1] then return end
        local ok, err = pcall(d.input_container.paintTo, self, bb, x, y)
        if ok or self.paint_failed then return end
        self.paint_failed = true
        local function recover()
            if not self.closed and not self.retired and owner.widget == self
                and model.on_render_error then
                pcall(model.on_render_error, err)
            end
        end
        if d.ui_manager and type(d.ui_manager.nextTick) == "function" then
            local scheduled, result = pcall(d.ui_manager.nextTick, d.ui_manager, recover)
            if scheduled and result ~= false then return end
        end
        if d.ui_manager and type(d.ui_manager.scheduleIn) == "function" then
            pcall(d.ui_manager.scheduleIn, d.ui_manager, 0, recover)
        end
    end

    function PanelWidget:onBack()
        return action(model.on_back, model.on_action_error)
    end

    function PanelWidget:onClose()
        if self.skip_close_callback then return true end
        return action(model.on_back, model.on_action_error)
    end

    function PanelWidget:onCloseWidget()
        self.closed = true
        return true
    end

    local widget = PanelWidget:new{}
    owner.widget = widget
    return widget
end

return NativePanel
