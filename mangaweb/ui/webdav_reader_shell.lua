-- Image-path-only reader shell derived from WebDAV Manga v0.4.03's fullscreen
-- interaction model. WebDAV, documents, archives and offline code are excluded.
local NativeReader = {}
NativeReader.__index = NativeReader
local ButtonStyle = require("mangaweb.ui.button_style")
local NativePanel = require("mangaweb.ui.native_panel")

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    return math.max(minimum, math.min(maximum, value))
end

local function bytes_label(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    if value >= 1048576 then
        return (value % 1048576 == 0 and "%d MiB" or "%.1f MiB")
            :format(value / 1048576)
    end
    if value >= 1024 then
        return (value % 1024 == 0 and "%d KiB" or "%.1f KiB")
            :format(value / 1024)
    end
    return tostring(value) .. " B"
end

local function call(callback, ...)
    if type(callback) ~= "function" then return true end
    -- KOReader forwards unconsumed events to windows below this modal reader.
    -- A pending page or failed action still handled the user's input here.
    pcall(callback, ...)
    return true
end

local function new_widget(class, options)
    return class and type(class.new) == "function" and class:new(options) or nil
end

function NativeReader:new(dependencies)
    return setmetatable({ deps = dependencies or {}, page = nil }, self)
end

function NativeReader:show(model)
    model = model or {}
    local ImageWidget = self.deps.image_widget
    local loading_model = model.loading == true
    if not loading_model and (not ImageWidget or type(ImageWidget.new) ~= "function") then
        return nil
    end
    local screen = self.deps.screen or {}
    local width = type(screen.getWidth) == "function" and screen:getWidth() or 600
    local height = type(screen.getHeight) == "function" and screen:getHeight() or 800
    local dependencies, owner = self.deps, self
    local Button = ButtonStyle.extend(dependencies.button, screen, dependencies.blitbuffer)
    local InputContainer = dependencies.input_container
    local Page = InputContainer and type(InputContainer.extend) == "function"
        and InputContainer:extend{
            -- MangaWeb keeps its opaque application root on KOReader's stack
            -- as a modal fullscreen window.  A normal reader window would be
            -- inserted below that root and remain invisible even though
            -- UIManager:show() succeeded.
            modal = true, fullscreen = true, covers_fullscreen = true,
            disable_double_tap = false,
        } or { disable_double_tap = false }
    Page.__index = Page
    if type(Page.new) ~= "function" then
        function Page:new(options) return setmetatable(options or {}, self) end
    end

    function Page:_action(name, ...)
        return call(self.actions and self.actions[name], ...)
    end

    function Page:_turn(edge)
        local forward = edge == "right"
        if self.direction == "rtl" then forward = not forward end
        return self:_action(forward and "next" or "previous")
    end

    function Page:_dirty()
        local manager = dependencies.ui_manager
        if manager and type(manager.setDirty) == "function" then
            pcall(manager.setDirty, manager, self, "ui")
        end
    end

    function Page:paintTo(bb, x, y)
        if self.released or not self[1] then return end
        local paint = dependencies.input_container and dependencies.input_container.paintTo
        if type(paint) ~= "function" then return end
        local ok, err = pcall(paint, self, bb, x, y)
        if ok or self.paint_failed then return end
        self.paint_failed = true
        local function recover()
            if not self.released and owner.page == self then
                self:_action("render_error", err)
            end
        end
        local manager = dependencies.ui_manager
        if manager and type(manager.nextTick) == "function" then
            local scheduled, result = pcall(manager.nextTick, manager, recover)
            if scheduled and result ~= false then return end
        end
        if manager and type(manager.scheduleIn) == "function" then
            pcall(manager.scheduleIn, manager, 0, recover)
        end
    end

    function Page:_release_controls()
        local controls = self.control_widgets or {}
        self.control_widgets = nil
        for _, widget in ipairs(controls) do
            if widget and type(widget.free) == "function" then pcall(widget.free, widget) end
        end
        self.title_bar, self.top_controls, self.progress = nil, nil, nil
        self.processing_notice = nil
        self.back_button, self.page_button, self.settings_button = nil, nil, nil
        self.previous_button, self.next_button = nil, nil
        self.retry_button, self.exit_button, self.error_text, self.error_overlay = nil, nil, nil, nil
        self.loading_text, self.loading_overlay, self.loading_button = nil, nil, nil
        self.emergency_exit_button = nil
    end

    function Page:_controls()
        self:_release_controls()
        local button_width = dependencies.screen and type(dependencies.screen.scaleBySize) == "function"
            and math.max(44, dependencies.screen:scaleBySize(46)) or 46
        local controls = {}
        if self.emergency_exit_visible then
            self.emergency_exit_button = new_widget(Button, {
                text = "X 返回漫画", width = math.min(self.width, button_width * 4),
                height = button_width, overlap_align = "right", valign = "top",
                callback = function() return self:_action("exit") end,
            })
            if self.emergency_exit_button then controls[#controls + 1] = self.emergency_exit_button end
        end
        if not self.loading and not self.error then
            self.progress = new_widget(dependencies.progress_widget, {
                width = self.width, height = 2,
                percentage = self.total > 1 and (self.index - 1) / (self.total - 1) or 0,
                margin_h = 0, margin_v = 0, radius = 0, allow_mirroring = false,
            })
            if self.progress then controls[#controls + 1] = self.progress end
            if self.processing_error and dependencies.text_widget and dependencies.font then
                local label = new_widget(dependencies.text_widget, {
                    text = "增强处理失败，已显示原图", face = dependencies.font:getFace("cfont",18),
                })
                self.processing_notice = label and new_widget(dependencies.frame_container, {
                    margin=0,padding=2,bordersize=0,
                    background=dependencies.blitbuffer and dependencies.blitbuffer.COLOR_WHITE,label,
                })
                if self.processing_notice then controls[#controls+1] = self.processing_notice end
            end
            self.control_widgets = controls
            return controls
        end
        if self.loading and dependencies.text_widget and dependencies.font
            and type(dependencies.font.getFace) == "function" then
            local loaded, face = pcall(dependencies.font.getFace, dependencies.font, "cfont", 18)
            local loading_label = ("正在加载第 %d / %d 张…"):format(self.index, self.total)
            if self.download_bytes and self.download_bytes > 0 then
                loading_label = loading_label .. "  " .. bytes_label(self.download_bytes)
                if self.download_total and self.download_total >= self.download_bytes then
                    loading_label = loading_label .. " / " .. bytes_label(self.download_total)
                end
            end
            self.loading_text = loaded and new_widget(dependencies.text_widget, {
                text = loading_label,
                face = face, align = "center",
            }) or nil
            self.loading_button = new_widget(Button, {
                text = "取消加载", callback = function() return self:_action("back") end,
            })
            local group = new_widget(dependencies.vertical_group,
                { self.loading_text, self.loading_button })
            self.loading_overlay = group and new_widget(dependencies.center_container, {
                dimen = dependencies.geom and dependencies.geom:new{ w = self.width, h = self.height }
                    or { w = self.width, h = self.height }, group,
            }) or group
            if self.loading_overlay then controls[#controls + 1] = self.loading_overlay end
        elseif self.error then
            local face
            if dependencies.font and type(dependencies.font.getFace) == "function" then
                local font_size = dependencies.screen
                    and type(dependencies.screen.scaleBySize) == "function"
                    and dependencies.screen:scaleBySize(18) or 18
                local ok, loaded = pcall(dependencies.font.getFace, dependencies.font,
                    "cfont", font_size)
                if ok then face = loaded end
            end
            if face and dependencies.text_widget then
                self.error_text = new_widget(dependencies.text_widget, {
                    text = tostring(self.error.user_message or self.error.code or "image_error"),
                    face = face,
                })
            end
            self.retry_button = new_widget(Button, {
                text = "重试", callback = function() return self:_action("retry") end,
            })
            self.exit_button = new_widget(Button, {
                text = "退出阅读", callback = function() return self:_action("exit") end,
            })
            local error_actions = new_widget(dependencies.horizontal_group,
                { self.retry_button, self.exit_button })
            local error_group = new_widget(dependencies.vertical_group,
                { self.error_text, error_actions }) or error_actions or self.error_text
            self.error_overlay = error_group and new_widget(dependencies.center_container, {
                dimen = dependencies.geom and dependencies.geom:new{
                    w = self.width, h = self.height,
                } or { w = self.width, h = self.height },
                error_group,
            }) or error_group
            if self.error_overlay then controls[#controls + 1] = self.error_overlay end
        end
        self.control_widgets = controls
        return controls
    end

    function Page:_rebuild_surface()
        if self.embedded_controls then
            self[1] = self.embedded_controls
            return
        end
        local controls = self:_controls()
        local children = { self.image_surface }
        for _, control in ipairs(controls) do children[#children + 1] = control end
        if dependencies.overlap_group then
            children.dimen = dependencies.geom and dependencies.geom:new{
                w = self.width, h = self.height,
            } or { w = self.width, h = self.height }
            children.allow_mirroring = false
            self[1] = new_widget(dependencies.overlap_group, children)
        else
            self[1] = self.image_surface or self.image
        end
    end

    function Page:show_controls(model)
        if self.released then return false end
        local ok, panel = pcall(function() return NativePanel:new{
            device = dependencies.device, input_container = dependencies.input_container,
            button = dependencies.button, frame_container = dependencies.frame_container,
            horizontal_group = dependencies.horizontal_group,
            vertical_group = dependencies.vertical_group, title_bar = dependencies.title_bar,
            scrollable_container = dependencies.scrollable_container,
            text_box_widget = dependencies.text_box_widget, font = dependencies.font,
            rect_span = dependencies.rect_span, geom = dependencies.geom,
            screen = dependencies.screen, blitbuffer = dependencies.blitbuffer,
            ui_manager = dependencies.ui_manager,
        }:show(model) end)
        if not ok or not panel then return false end
        self:_dispose_embedded_controls()
        self:_release_controls()
        self.embedded_controls = panel
        -- InputContainer still receives unhandled gestures while the panel is
        -- open and iterates this table. Disable page gestures without breaking
        -- the native input contract; close_controls restores page_gestures.
        self.ges_events = {}
        self[1] = panel
        self:_dirty()
        return true
    end

    function Page:show_page_picker(model)
        return self:show_controls(model)
    end

    function Page:_dispose_embedded_controls()
        local panel = self.embedded_controls
        self.embedded_controls = nil
        if panel then
            if type(panel.onCloseWidget) == "function" then pcall(panel.onCloseWidget, panel) end
            if type(panel.free) == "function" then pcall(panel.free, panel) end
        end
    end

    function Page:close_controls()
        if not self.embedded_controls then return true end
        self:_dispose_embedded_controls()
        self.ges_events = self.page_gestures
        self:_rebuild_surface()
        self:_dirty()
        return true
    end

    function Page:_new_image(path)
        local ImageWidget = dependencies.image_widget
        if not ImageWidget or type(ImageWidget.new) ~= "function" then return nil end
        local created, image = pcall(ImageWidget.new, ImageWidget, {
            file = path,
            image_disposable = true,
            file_do_cache = false,
            width = self.width,
            height = self.height,
            scale_factor = 0,
        })
        if not created or not image then return nil end
        if type(image.getSize) == "function" then
            local decoded, size = pcall(image.getSize, image)
            if not decoded or not size or image._is_straight_alpha == false then
                if type(image.free) == "function" then pcall(image.free, image) end
                return nil
            end
        end
        return image
    end

    function Page:_new_image_surface(image)
        return new_widget(dependencies.frame_container, {
            width = self.width, height = self.height, margin = 0, padding = 0, bordersize = 0,
            background = dependencies.blitbuffer and dependencies.blitbuffer.COLOR_WHITE,
            new_widget(dependencies.center_container, {
                dimen = dependencies.geom and dependencies.geom:new{ w = self.width, h = self.height }
                    or { w = self.width, h = self.height },
                image,
            }) or image,
        }) or image
    end

    function Page:_new_loading_surface()
        local white = dependencies.blitbuffer and dependencies.blitbuffer.COLOR_WHITE
        local placeholder = new_widget(dependencies.rect_span, {
            width = self.width, height = self.height, background = white,
        })
        -- RectSpan only reserves space in KOReader; it never paints its
        -- background. Keep it as the sized child of a real opaque container.
        return placeholder and new_widget(dependencies.frame_container, {
            width = self.width, height = self.height, margin = 0, padding = 0,
            bordersize = 0, background = white, placeholder,
        }) or placeholder or { width = self.width, height = self.height, background = white }
    end

    function Page:update_page(path, index, total, options)
        if self.released then return false end
        options = options or {}
        local next_total = math.max(1, math.floor(tonumber(total) or 1))
        local next_image = self:_new_image(path)
        if not next_image then return false end
        local previous = self.image
        self.file = path
        self.total = next_total
        self.index = math.floor(clamp(index, 1, next_total))
        self.image = next_image
        self.image_surface = self:_new_image_surface(next_image)
        self.error = nil
        self.loading = false
        self.download_bytes, self.download_total = nil, nil
        self.segment, self.pan_y, self.fit_mode = options.segment, options.pan_y, options.fit_mode
        self.processing_error = options.processing_error
        self.split_cut_percent = options.split_cut_percent
        self:_rebuild_surface()
        self:_dirty()
        if previous and type(previous.free) == "function" then pcall(previous.free, previous) end
        return true
    end

    function Page:set_loading(loading, index, total)
        if self.released then return false end
        if tonumber(total) then
            self.total = math.max(1, math.floor(tonumber(total)))
        end
        if tonumber(index) then
            self.index = math.floor(clamp(index, 1, self.total))
        end
        self.loading = loading == true
        self.download_bytes, self.download_total = nil, nil
        self:_rebuild_surface()
        self:_dirty()
        return true
    end

    function Page:set_download_progress(bytes, total)
        if self.released or not self.loading then return false end
        bytes = tonumber(bytes)
        if not bytes or bytes < 0 then return false end
        self.download_bytes = math.min(64 * 1048576, math.floor(bytes))
        total = tonumber(total)
        self.download_total = total and total > 0 and total <= 64 * 1048576
            and math.floor(total) or nil
        self:_rebuild_surface()
        self:_dirty()
        return true
    end

    function Page:on_tap(region, x)
        if self.embedded_controls then return true end
        if region ~= "left" and region ~= "right" and region ~= "center" then
            x = tonumber(x) or self.width / 2
            region = x < self.width / 3 and "left"
                or x > self.width * 2 / 3 and "right" or "center"
        end
        if region == "center" then
            if self.loading or self.error then return true end
            return self:_action("settings")
        end
        return self:_turn(region)
    end

    function Page:onTap(_, gesture)
        local position = gesture and gesture.pos or {}
        return self:on_tap(nil, position.x)
    end

    function Page:onSwipe(_, gesture)
        if self.embedded_controls then return true end
        local direction = gesture and gesture.direction
        if direction == "west" then return self:_turn("right") end
        if direction == "east" then return self:_turn("left") end
        return true
    end

    function Page:onDoubleTap()
        if self.embedded_controls then return true end
        self.emergency_exit_visible = true
        self:_rebuild_surface()
        self:_dirty()
        return true
    end

    function Page:onMangaNext()
        return self.embedded_controls and true or self:_action("next")
    end
    function Page:onMangaPrevious()
        return self.embedded_controls and true or self:_action("previous")
    end
    function Page:onMangaBack()
        if self.embedded_controls then
            return call(self.embedded_controls.model and self.embedded_controls.model.on_back)
        end
        return self:_action("back")
    end
    function Page:onBack() return self:onMangaBack() end
    function Page:onGotoViewRel(diff)
        return tonumber(diff) and tonumber(diff) < 0 and self:onMangaPrevious()
            or self:onMangaNext()
    end
    function Page:onGotoPageRel(diff) return self:onGotoViewRel(diff) end

    function Page:onTapProgress(_, gesture)
        if not self.progress or type(self.progress.getPercentageFromPosition) ~= "function" then
            return true
        end
        local percentage = self.progress:getPercentageFromPosition(gesture and gesture.pos)
        if percentage == nil then return true end
        percentage = clamp(percentage, 0, 1)
        return self:_action("go_to", math.floor(percentage * (self.total - 1)) + 1)
    end

    function Page:set_direction(direction)
        self.direction = direction == "rtl" and "rtl" or "ltr"
        self:_dirty()
        return true
    end

    function Page:set_error(error)
        self.error = error or { code = "image_error" }
        self.loading = false
        self.download_bytes, self.download_total = nil, nil
        self.image_surface = self:_new_loading_surface()
        self:_rebuild_surface()
        self:_dirty()
        return true
    end

    function Page:release()
        if self.released then return true end
        self.released = true
        self:_dispose_embedded_controls()
        self:_release_controls()
        if self.image and type(self.image.free) == "function" then pcall(self.image.free, self.image) end
        return true
    end
    function Page:onCloseWidget() return self:release() end

    local page = Page:new{
        file = model.path,
        total = math.max(1, math.floor(tonumber(model.total) or 1)),
        controls_visible = model.controls_visible == true,
        direction = model.direction == "rtl" and "rtl" or "ltr",
        segment = model.segment, pan_y = model.pan_y, fit_mode = model.fit_mode,
        split_cut_percent = model.split_cut_percent,
        processing_error = model.processing_error,
        actions = model.actions or {},
        width = width,
        height = height,
        loading = loading_model,
    }
    page.index = math.floor(clamp(model.index, 1, page.total))
    if loading_model then
        page.image = nil
        page.image_surface = page:_new_loading_surface()
    else
        page.image = page:_new_image(page.file)
        if not page.image then return nil end
        page.image_surface = page:_new_image_surface(page.image)
    end
    if dependencies.gesture_range and dependencies.geom then
        local range = dependencies.geom:new{ x = 0, y = 0, w = width, h = height }
        page.ges_events = {
            Tap = { dependencies.gesture_range:new{ ges = "tap", range = range } },
            DoubleTap = { dependencies.gesture_range:new{ ges = "double_tap",
                range = dependencies.geom:new{
                    x = math.floor(width * 0.6), y = 0,
                    w = math.max(1, math.ceil(width * 0.4)),
                    h = math.max(1, math.ceil(height * 0.2)),
                } } },
            Swipe = { dependencies.gesture_range:new{ ges = "swipe", range = range } },
        }
        page.page_gestures = page.ges_events
    end
    local groups = dependencies.device and dependencies.device.input
        and dependencies.device.input.group or {}
    if next(groups) then
        page.key_events = {
            MangaNext = { { groups.PgFwd or { "RPgFwd", "LPgFwd" } } },
            MangaPrevious = { { groups.PgBack or { "RPgBack", "LPgBack" } } },
            MangaBack = { { groups.Back or { "Back" } } },
        }
    end
    page:_rebuild_surface()
    self.page = page
    return page
end

function NativeReader:close()
    local page = self.page
    self.page = nil
    if not page then return true end
    page:release()
    local manager = self.deps.ui_manager
    if manager and type(manager.close) == "function" then pcall(manager.close, manager, page) end
    return true
end

function NativeReader:show_controls(model)
    return self.page and self.page:show_controls(model) or false
end

function NativeReader:show_page_picker(model)
    return self.page and self.page:show_page_picker(model) or false
end

return NativeReader
