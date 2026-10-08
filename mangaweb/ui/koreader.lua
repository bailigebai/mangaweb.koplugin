local NativeGrid = require("mangaweb.ui.native_grid")
local NativeDetail = require("mangaweb.ui.native_detail")
local NativePanel = require("mangaweb.ui.native_panel")
local ReaderShell = require("mangaweb.ui.webdav_reader_shell")
local NativeRoot = require("mangaweb.ui.native_root")
local Models = require("mangaweb.models")
local SiteRuleEditor = require("mangaweb.ui.site_rule_editor")
local ReaderFilters = require("mangaweb.ui.reader_filters")
local CoverPrefetch = require("mangaweb.cover_prefetch")
local GrayDitherBridge = require("mangaweb.graydither_bridge")

local Adapter = {}
Adapter.__index = Adapter

local LICENSE_ERROR_TEXT = {
    invalid_key_format = "密钥格式错误",
    invalid_key = "密钥无效",
    key_bound_to_other_device = "密钥已绑定其他设备",
    device_unavailable = "设备身份不可读",
    entropy_unavailable = "设备身份无法建立",
    invalid_local_license = "本地授权无效",
    storage_unavailable = "授权存储不可用",
    save_failed = "本地保存失败",
    public_key_unavailable = "授权公钥不可用",
    invalid_signature = "授权签名无效",
    http_unavailable = "安全网络组件不可用",
    proxy_not_supported = "不支持网络代理",
    tls_unavailable = "HTTPS 组件不可用",
    dns_error = "域名解析失败",
    server_unreachable = "授权服务无法连接",
    tls_error = "HTTPS 失败，请检查时间和网络",
    timeout = "请求超时",
    response_too_large = "服务响应异常",
    redirect_refused = "服务地址异常",
    server_error = "授权服务繁忙",
    service_unavailable = "授权服务繁忙",
    rate_limited = "尝试过于频繁，请稍后再试",
    invalid_response = "授权响应无效",
    network_error = "网络连接失败",
    activation_busy = "正在处理激活请求",
    activation_rejected = "激活被拒绝",
}

local function optional(value, module_name)
    if value then return value end
    local ok, loaded = pcall(require, module_name)
    return ok and loaded or nil
end

local function call_action(callback, ...)
    if type(callback) ~= "function" then return true end
    local ok, result = pcall(callback, ...)
    if not ok or result == nil or result == false then return true end
    return result
end

local function card_text(card, prefix)
    card = card or {}
    local text = tostring(prefix or "") .. tostring(card.title or "漫画")
    if card.favorite then text = "★ " .. text end
    if card.progress then text = text .. "  " .. tostring(card.progress) end
    return text
end

local function detail_image_identity(model)
    local card = (((model or {}).detail or {}).card) or {}
    local stable_id = card.comic_id or card.id or card.url or card.detail_url or card.title or ""
    return tostring(card.site_id or (model or {}).site_id or "") .. "\0" .. tostring(stable_id)
end

function Adapter:_log_image_error(site_id, stage, url, error_value, response)
    if not self.logger or type(self.logger.warn) ~= "function" then return end
    local status = response and (response.status or response.status_code) or nil
    local code = type(error_value) == "table"
        and (error_value.code or error_value.error or error_value.user_message)
        or error_value
    pcall(self.logger.warn, "MangaWeb image", tostring(site_id or "?"),
        tostring(stage or "?"), "status", tostring(status or "?"),
        "error", tostring(code or "image_error"))
end

function Adapter:_new_text(options, size)
    options.face = self.font:getFace("cfont", size or 18)
    return self.text_widget:new(options)
end

function Adapter:new(options)
    options = options or {}
    local self = setmetatable({
        widget = nil,
        root_widget = nil,
        root_renderer = nil,
        error_widget = nil,
        reader_widget = nil,
        reader_controls = nil,
        reader_renderer = nil,
        license_manager_widget = nil,
        license_manager_renderer = nil,
        input_dialog = nil,
        filter_picker = nil,
        exit_confirmation_widget = nil,
        shell = nil,
        reader = nil,
        loader = options.loader,
        cover_loader = options.cover_loader,
        reading_rtl = false,
        progress_clock = options.progress_clock or os.time,
        device = optional(options.device, "device"),
        ui_manager = optional(options.ui_manager, "ui/uimanager"),
        menu = optional(options.menu, "ui/widget/menu"),
        image_widget = optional(options.image_widget, "ui/widget/imagewidget"),
        input_container = optional(options.input_container, "ui/widget/container/inputcontainer"),
        button = optional(options.button, "ui/widget/button"),
        frame_container = optional(options.frame_container, "ui/widget/container/framecontainer"),
        center_container = optional(options.center_container, "ui/widget/container/centercontainer"),
        horizontal_group = optional(options.horizontal_group, "ui/widget/horizontalgroup"),
        vertical_group = optional(options.vertical_group, "ui/widget/verticalgroup"),
        overlap_group = optional(options.overlap_group, "ui/widget/overlapgroup"),
        text_widget = optional(options.text_widget, "ui/widget/textwidget"),
        text_box_widget = optional(options.text_box_widget, "ui/widget/textboxwidget"),
        title_bar = optional(options.title_bar, "ui/widget/titlebar"),
        progress_widget = optional(options.progress_widget, "ui/widget/progresswidget"),
        scrollable_container = optional(options.scrollable_container,
            "ui/widget/container/scrollablecontainer"),
        font = optional(options.font, "ui/font"),
        blitbuffer = optional(options.blitbuffer, "ffi/blitbuffer"),
        rect_span = optional(options.rect_span, "ui/widget/rectspan"),
        geom = optional(options.geom, "ui/geometry"),
        gesture_range = optional(options.gesture_range, "ui/gesturerange"),
        screen = options.screen or (function()
            local ok, device = pcall(require, "device")
            return ok and device and device.screen or nil
        end)(),
        render_image = optional(options.render_image, "ui/renderimage"),
        http = options.http,
        temp_files = options.temp_files,
        single_input_dialog = optional(options.single_input_dialog, "ui/widget/inputdialog"),
        multi_input_dialog = optional(options.multi_input_dialog, "ui/widget/multiinputdialog"),
        dialog_keyboard = optional(options.dialog_keyboard, "mangaweb.dialog_keyboard"),
        logger = optional(options.logger, "logger"),
    }, self)
    self.root_renderer = NativeRoot:new{
        ui_manager = self.ui_manager,
        input_container = self.input_container,
        frame_container = self.frame_container,
        gesture_range = self.gesture_range,
        blitbuffer = self.blitbuffer,
        screen = self.screen,
    }
    self.root_widget = self.root_renderer.root_widget
    return self
end

function Adapter:_input_dialog_options(options, dialog_provider)
    options = options or {}
    local overlay_close_callback = options.mangaweb_close_callback
    options.mangaweb_close_callback = nil
    options.modal = true
    if options.fullscreen == nil then options.fullscreen = true end
    options.condensed = true
    options.enter_callback = options.enter_callback or function()
        if self.dialog_keyboard and type(self.dialog_keyboard.hide) == "function" then
            return self.dialog_keyboard.hide(dialog_provider())
        end
        local dialog = dialog_provider()
        if dialog and type(dialog.onCloseKeyboard) == "function" then
            return pcall(dialog.onCloseKeyboard, dialog)
        end
        return true
    end
    if self.dialog_keyboard and type(self.dialog_keyboard.with_top_button) == "function" then
        local called, wrapped = pcall(self.dialog_keyboard.with_top_button, options,
            dialog_provider, overlay_close_callback
                or function(dialog) return self:_close_input_dialog(dialog) end)
        if called and type(wrapped) == "table" then return wrapped end
    end
    return options
end

function Adapter:show_license_activation(model)
    model = model or {}
    local Dialog, manager = self.single_input_dialog or self.multi_input_dialog, self.ui_manager
    if not Dialog or not manager then return false end
    self:close_license_overlay()
    local dialog
    local submit_button = {
        text = "激活并阅读", enabled = true, vsync = true, no_invert = true,
    }
    local hide_button = {
        text = "收起键盘", vsync = true, no_invert = true,
    }
    local cancel_button = {
        text = "取消", id = "close", vsync = true, no_invert = true,
    }
    local function cancel_overlay()
        call_action(model.on_cancel)
        if self.input_dialog == dialog then self:_close_input_dialog(dialog) end
        return true
    end
    cancel_button.callback = cancel_overlay
    hide_button.callback = function()
        if self.dialog_keyboard and type(self.dialog_keyboard.hide) == "function" then
            return self.dialog_keyboard.hide(dialog)
        end
        if dialog and type(dialog.onCloseKeyboard) == "function" then
            return call_action(function() return dialog:onCloseKeyboard() end)
        end
        return true
    end
    submit_button.callback = function()
        if not dialog or dialog.activation_busy then return true end
        dialog.activation_busy = true
        submit_button.enabled = false
        local value = ""
        if type(dialog.getInputText) == "function" then
            value = dialog:getInputText() or ""
        elseif type(dialog.getFields) == "function" then
            local fields = dialog:getFields() or {}
            value = fields[1] or ""
        end
        local result = call_action(model.on_submit, value)
        return result
    end
    local options = self:_input_dialog_options({
        title = tostring(model.title or "阅读授权"),
        description = tostring(model.message or ""),
        input = "",
        input_hint = "输入12位短密钥",
        fullscreen = false,
        buttons = {{ cancel_button, hide_button, submit_button }},
        mangaweb_close_callback = function() return cancel_overlay() end,
    }, function() return dialog end)
    dialog = Dialog:new(options)
    dialog.mangaweb_license_overlay = true
    dialog.license_submit_button = submit_button
    self.license_activation_model = model
    return self:_show_input_dialog(dialog)
end

function Adapter:update_license_activation(model)
    self.license_activation_model = model or self.license_activation_model
    local dialog = self.input_dialog
    if not dialog or not dialog.mangaweb_license_overlay then return false end
    dialog.activation_busy = false
    dialog.activation_error = model and model.error
    dialog.activation_error_text = LICENSE_ERROR_TEXT[dialog.activation_error] or "激活失败"
    if dialog.title_bar and type(dialog.title_bar.setTitle) == "function" then
        pcall(dialog.title_bar.setTitle, dialog.title_bar,
            "阅读授权 · " .. dialog.activation_error_text)
    end
    if dialog.license_submit_button then dialog.license_submit_button.enabled = true end
    self:_dirty_root()
    return true
end

function Adapter:_license_manager_status(status)
    if status == "authorized" then return "阅读授权 · 已激活" end
    if status == "not_activated" then return "阅读授权 · 未激活" end
    return "阅读授权 · 本地授权无效"
end

function Adapter:show_license_manager(model)
    model = model or {}
    self:close_license_overlay()
    local adapter = self
    local function render(confirming, error_text)
        if self.license_manager_widget and self.ui_manager and self.ui_manager.close then
            pcall(self.ui_manager.close, self.ui_manager, self.license_manager_widget)
        end
        local state = {
            status = model.status,
            status_text = self:_license_manager_status(model.status),
            confirming_remove = confirming == true,
            error = error_text,
            actions = {},
        }
        self.license_manager_model = state
        local function close_manager()
            call_action(model.on_close)
            if adapter.license_manager_widget then adapter:close_license_overlay() end
            return true
        end
        state.actions.activate = function() return call_action(model.on_activate) end
        state.actions.remove = function() return render(true) end
        state.actions.confirm_remove = function()
            if adapter.license_manager_model ~= state then return true end
            local called, removed = pcall(model.on_remove)
            if not called or removed ~= true then
                return render(true, "移除本机授权失败，请重试。")
            end
            return true
        end
        state.actions.cancel_remove = function() return render(false) end

        local panel_model = {
            page = "license_manager",
            modal = true,
            title = "授权密钥管理",
            status = error_text or (confirming
                and "确认移除本机授权？此操作不会解绑服务器上的密钥。" or state.status_text),
            rows = {{ kind = "info", text = tostring(model.message or "") }},
            actions = confirming and {
                { text = "取消", callback = state.actions.cancel_remove },
                { text = "确认移除", callback = state.actions.confirm_remove },
            } or {
                { text = model.status == "authorized" and "输入/更换密钥" or "输入短密钥",
                    callback = state.actions.activate },
                { text = "移除本机授权", callback = state.actions.remove },
                { text = "返回", callback = close_manager },
            },
            on_back = close_manager,
            on_close = close_manager,
        }
        local renderer = NativePanel:new{
            device = self.device,
            input_container = self.input_container, button = self.button,
            frame_container = self.frame_container, horizontal_group = self.horizontal_group,
            vertical_group = self.vertical_group, title_bar = self.title_bar,
            scrollable_container = self.scrollable_container,
            text_box_widget = self.text_box_widget, font = self.font,
            rect_span = self.rect_span, geom = self.geom, screen = self.screen,
            blitbuffer = self.blitbuffer, ui_manager = self.ui_manager,
        }
        local widget = renderer:show(panel_model)
        if not widget and self.menu then
            local items = {{ text = panel_model.status, enabled = false, select_enabled = false }}
            if model.message and model.message ~= "" then
                items[#items + 1] = { text = model.message, enabled = false, select_enabled = false }
            end
            for _, item in ipairs(panel_model.actions) do items[#items + 1] = item end
            widget = self.menu:new{
                title = panel_model.title, item_table = items,
                modal = true,
                covers_fullscreen = true, close_callback = close_manager,
                -- These actions manage their own windows. Native Menu would
                -- otherwise close a newly opened input/confirmation window
                -- through the previous menu's close_callback after selection.
                onMenuSelect = function(_, selected)
                    if selected.select_enabled ~= false then call_action(selected.callback) end
                    return true
                end,
            }
            renderer = nil
        end
        if not widget or not self.ui_manager or type(self.ui_manager.show) ~= "function" then
            return false
        end
        self.license_manager_renderer = renderer
        self.license_manager_widget = widget
        self.ui_manager:show(widget)
        return true
    end
    return render(false)
end

function Adapter:close_license_overlay()
    local manager = self.ui_manager
    if self.input_dialog and self.input_dialog.mangaweb_license_overlay then
        self:_close_input_dialog(self.input_dialog)
    end
    if self.license_manager_widget then
        if self.license_manager_renderer and type(self.license_manager_renderer.close) == "function" then
            pcall(self.license_manager_renderer.close, self.license_manager_renderer)
        elseif manager and type(manager.close) == "function" then
            pcall(manager.close, manager, self.license_manager_widget)
        end
    end
    self.license_manager_widget = nil
    self.license_manager_renderer = nil
    self.license_manager_model = nil
    self.license_activation_model = nil
    return true
end

function Adapter:_close_input_dialog(dialog)
    dialog = dialog or self.input_dialog
    if not dialog then return true end
    local hidden = false
    if self.dialog_keyboard and type(self.dialog_keyboard.hide) == "function" then
        local called, result = pcall(self.dialog_keyboard.hide, dialog)
        hidden = called and result ~= false
    end
    if not hidden and dialog.onCloseKeyboard then pcall(dialog.onCloseKeyboard, dialog) end
    if self.ui_manager and self.ui_manager.close then
        pcall(self.ui_manager.close, self.ui_manager, dialog)
    end
    if self.input_dialog == dialog then self.input_dialog = nil end
    return true
end

function Adapter:_show_input_dialog(dialog)
    if not dialog or not self.ui_manager then return false end
    if self.input_dialog and self.input_dialog ~= dialog then self:_close_input_dialog() end
    self.input_dialog = dialog
    self.ui_manager:show(dialog)
    if self.dialog_keyboard and type(self.dialog_keyboard.show) == "function" then
        local called, result = pcall(self.dialog_keyboard.show, dialog)
        if not called or result == false then
            if dialog.onShowKeyboard then pcall(dialog.onShowKeyboard, dialog) end
        end
    elseif dialog.onShowKeyboard then
        pcall(dialog.onShowKeyboard, dialog)
    end
    return true
end

function Adapter:_dirty_root()
    local manager = self.ui_manager
    local renderer = self.root_renderer
    local root = renderer and renderer.root_widget or self.root_widget
    if manager and root and type(manager.setDirty) == "function" then
        pcall(manager.setDirty, manager, root, "ui")
    end
    return true
end

function Adapter:defer(callback)
    if type(callback) ~= "function" then return false end
    local manager = self.ui_manager
    if manager and type(manager.nextTick) == "function" then
        local ok, result = pcall(manager.nextTick, manager, callback)
        if ok and result ~= false then return true end
    end
    if manager and type(manager.scheduleIn) == "function" then
        local ok, result = pcall(manager.scheduleIn, manager, 0, callback)
        return ok and result ~= false
    end
    return false
end

function Adapter:_cancel_covers()
    local loader = self.cover_loader or self.loader
    if loader and self.cover_loader_generation
        and type(loader.cancel_generation) == "function" then
        pcall(loader.cancel_generation, loader, self.cover_loader_generation)
    end
    self.cover_loader_generation = nil
    self.cover_prefetch = nil
    for _, handle in ipairs(self.cover_handles or {}) do
        if handle and handle.cancel then pcall(handle.cancel, handle) end
    end
    self.cover_handles = {}
    self.cover_generation = (self.cover_generation or 0) + 1
    if self.cover_session and self.temp_files and self.temp_files.remove_session then
        pcall(self.temp_files.remove_session, self.temp_files, self.cover_session)
    end
    self.cover_session = nil
    self.detail_image_identity = nil
    self.detail_image_requests = nil
    self.detail_image_targets = nil
    self.detail_image_jobs = nil
    self.detail_image_order = nil
    self.cover_grid = nil
    self.cover_grid_identity = nil
    self.cover_grid_requests = nil
end

function Adapter:_build_grid(model, existing)
    local registry = self.shell and self.shell.registry
    local source = registry and type(registry.current) == "function" and registry:current() or nil
    local meta = source and source.meta and source:meta() or {}
    local site_name = meta.name
    if type(site_name) == "string" and not site_name:match("%S") then site_name = nil end
    model.title = tostring(site_name or model.title or model.site_id or "漫画")
    model.subtitle = nil
    model.navigation = self:_navigation("discover")
    model.on_close = function() return self:_confirm_exit() end
    if existing then return existing:update_model(model) and existing or nil end
    return self:_build_native_grid(model)
end

function Adapter:_navigation(active)
    local shell = self.shell
    return {
        { text = "发现", active = active == "discover",
            callback = function() return shell and shell:show("browse") end },
        { text = "收藏", active = active == "library",
            callback = function() return shell and shell:show("library") end },
        { text = "历史", active = active == "history",
            callback = function() return shell and shell:show("history") end },
        { text = "我的", active = active == "sites",
            callback = function() return shell and shell:show("site_center") end },
    }
end

function Adapter:_show_browse_filters(model)
    local actions = (model or {}).actions or {}
    local choices = {}
    if type(actions.categories) == "function" then
        choices[#choices + 1] = { id = "category", name = "分类" }
    end
    if type(actions.tags) == "function" then
        choices[#choices + 1] = { id = "tag", name = "标签" }
    end
    if #choices == 0 then return false end
    return self:_show_filter_picker("筛选", function(callback)
        return callback(choices)
    end, function(choice)
        if choice.id == "category" then
            return self:_show_filter_picker("选择分类", actions.categories, actions.select_category)
        end
        return self:_show_search(function(query)
            return self:_show_filter_picker("选择标签", function(callback)
                return actions.tags(query, callback)
            end, actions.select_tag)
        end, "搜索标签")
    end)
end

function Adapter:_build_native_grid(model)
    local adapter = self
    local grid
    self.grid_renderer = NativeGrid:new{
        device = self.device,
        input_container = self.input_container, button = self.button,
        frame_container = self.frame_container, center_container = self.center_container,
        horizontal_group = self.horizontal_group, vertical_group = self.vertical_group,
        overlap_group = self.overlap_group, image_widget = self.image_widget,
        rect_span = self.rect_span, geom = self.geom,
        gesture_range = self.gesture_range, screen = self.screen, title_bar = self.title_bar,
        text_box_widget = self.text_box_widget, font = self.font, ui_manager = self.ui_manager,
        blitbuffer = self.blitbuffer,
        on_sources = function() return adapter:show_source_picker() end,
        on_filters = function(current) return adapter:_show_browse_filters(current) end,
        on_search = function(current) return adapter:_show_search((current.actions or {}).search) end,
        on_collection_categories = function(current)
            local categories = {}
            for index = 2, #((current or {}).tabs or {}) do
                categories[#categories + 1] = current.tabs[index]
            end
            return adapter:_show_local_category_picker{
                title = "选择收藏分类", categories = categories,
                selected_id = current.category_id,
                on_select = function(category)
                    return ((current or {}).actions or {}).select_category(
                        category and category.id or nil)
                end,
            }
        end,
    }
    grid = self.grid_renderer:show(model)
    if grid then
        grid.on_render_error = function(err)
            if adapter.widget ~= grid then return true end
            local current = grid.model or model
            if adapter.logger and adapter.logger.warn then
                pcall(adapter.logger.warn, "MangaWeb: native grid paint failed",
                    Models.error({ code = "render_error" },
                        current.site_id or (current.site or {}).id, "paint"))
            end
            return adapter:_render(current, true)
        end
        model.on_render_error = grid.on_render_error
        grid.on_page_changed = function() return adapter:_load_covers(grid.model, grid) end
    end
    return grid
end

function Adapter:_build_collection_grid(model, existing)
    local labels = {
        library = { title = "收藏", active = "library" },
        history = { title = "阅读历史", active = "history" },
        category_items = { title = ((model.category or {}).name or "分类架"), active = "library" },
    }
    local label = labels[model.page] or labels.library
    local cells = {}
    for index, record in ipairs(model.items or {}) do
        local item = record
        local progress
        if model.page == "history" and item.page_index then
            progress = tostring(item.page_index) .. "/" .. tostring(item.total_pages or 1)
        end
        cells[#cells + 1] = {
            index = index, site_id = item.site_id, comic_id = item.comic_id,
            title = item.title, cover_url = item.cover_url,
            cover_headers = item.cover_headers, tags = item.tags or {},
            progress = progress,
            selected = item.selected,
            on_tap = item.on_tap or function()
                return self.shell and self.shell:show_detail(item)
            end,
        }
    end
    model.grid = { columns = 4, cells = cells }
    model.title = label.title
    if not model.official then model.subtitle = #cells == 0 and "暂无内容" or ("共 " .. tostring(#cells) .. " 本") end
    model.show_filters = false
    model.show_pagination = model.official == true
    model.navigation = self:_navigation(label.active)
    model.actions = model.actions or {}
    if model.page == "library" then
        if model.official then
            model.actions.choose_official_removal = function() return self:_show_official_removal_picker(model) end
        else
            model.actions.choose_batch_category = function() return self:_show_batch_category_picker(model) end
        end
    elseif model.page == "category_items" and model.actions.back then
        model.actions.categories_shelf = model.actions.back
    end
    model.actions.site_center = model.actions.site_center
        or function() return self.shell and self.shell:show("site_center") end
    model.on_close = function() return self:_confirm_exit() end
    if existing then return existing:update_model(model) and existing or nil end
    return self:_build_native_grid(model)
end

function Adapter:_image_headers(site_id, url, provided)
    if type(provided) == "table" and next(provided) ~= nil then return provided end
    local registry = self.shell and self.shell.registry
    local source = registry and registry.sources and registry.sources[site_id]
    if not source and registry and type(registry.current) == "function" then
        source = registry:current()
    end
    if source and type(source.image_headers) == "function" then
        local ok, headers = pcall(source.image_headers, source, url)
        if ok and type(headers) == "table" then return headers end
    end
    return {}
end

function Adapter:_load_covers(model, grid)
    local loader = self.cover_loader or self.loader
    if loader and type(loader.begin_session) == "function"
        and type(loader.request) == "function" then
        local indexes = {}
        for index in pairs(grid.cells or {}) do indexes[#indexes + 1] = index end
        table.sort(indexes, function(left, right) return tonumber(left) < tonumber(right) end)
        local parts = { tostring(grid.cover_w), tostring(grid.cover_h) }
        for _, index in ipairs(indexes) do
            local cell = ((model.grid or {}).cells or {})[index] or {}
            for _, value in ipairs{ tostring(index), tostring(cell.site_id or ""),
                tostring(cell.comic_id or ""), tostring(cell.cover_url or "") } do
                parts[#parts + 1] = #value .. ":" .. value
            end
        end
        local identity = table.concat(parts, "\0")
        if not self.cover_loader_generation or self.cover_grid ~= grid or self.cover_grid_identity ~= identity then
            self:_cancel_covers()
            self.cover_loader_generation = loader:begin_session("cover")
            self.cover_grid, self.cover_grid_identity = grid, identity
            self.cover_grid_requests = {}
        end
        local generation = self.cover_loader_generation
        local requested = self.cover_grid_requests
        local function spec_for(cell, key)
            if not cell or type(cell.cover_url) ~= "string" or cell.cover_url == "" then return nil end
            return { key = key, url = cell.cover_url, site_id = cell.site_id, comic_id = cell.comic_id,
                stage = "cover", headers = self:_image_headers(cell.site_id, cell.cover_url, cell.cover_headers),
                width = grid.cover_w, height = grid.cover_h }
        end
        local function background_key(cell)
            local parts = { "prefetch" }
            for _, value in ipairs{ tostring(cell.site_id or ""), tostring(cell.comic_id or ""),
                tostring(cell.cover_url or "") } do parts[#parts + 1] = #value .. ":" .. value end
            return table.concat(parts, "\0")
        end
        local background, visible = {}, {}
        for _, index in ipairs(indexes) do
            local cell = ((model.grid or {}).cells or {})[index]
            if cell then visible[background_key(cell)] = true end
        end
        for _, cell in ipairs(((model.grid or {}).cells or {})) do
            local key = background_key(cell)
            local spec = not visible[key] and spec_for(cell, key)
            if spec then background[#background + 1] = spec end
        end
        -- Protect the complete collection before any cache write or unpin can trim it.
        for _, group in ipairs(model.cover_groups or {}) do
            local specs, complete = {}, group.complete == true
            for _, cell in ipairs(group.items or {}) do
                local key = background_key(cell)
                local spec = spec_for(cell, key)
                if spec then
                    specs[#specs + 1] = spec
                    if not visible[key] then background[#background + 1] = spec end
                else complete = false end
            end
            if type(loader.sync_protected) == "function" then
                pcall(loader.sync_protected, loader, group.owner, specs, complete)
            end
        end
        for _, index in ipairs(indexes) do
            local cell = ((model.grid or {}).cells or {})[index]
            if cell and cell.cover_url and cell.cover_url ~= ""
                and not (type(grid.has_cover) == "function"
                    and grid:has_cover(index, cell.cover_url)) then
                local key = "cover:" .. tostring(index) .. ":" .. tostring(cell.cover_url)
                if not requested[key] then
                    requested[key] = true
                    loader:request(generation, {
                        key = key, url = cell.cover_url, site_id = cell.site_id,
                        comic_id = cell.comic_id,
                        stage = "cover", priority = 3,
                        headers = self:_image_headers(cell.site_id, cell.cover_url, cell.cover_headers),
                        width = grid.cover_w, height = grid.cover_h,
                    }, {
                        on_ready = function(result)
                            if generation == self.cover_loader_generation then requested[key] = nil end
                            if generation ~= self.cover_loader_generation
                                or self.widget ~= grid or grid.closed or grid.retired then
                                return false
                            end
                            local buffer = result and result.buffer
                            if not buffer then return false end
                            local accepted = grid:set_cover(index, buffer)
                            if accepted ~= false then self:_dirty_root() end
                            return accepted ~= false
                        end,
                        on_error = function(error)
                            if generation == self.cover_loader_generation then requested[key] = nil end
                            self:_log_image_error(cell.site_id, "cover", cell.cover_url, error)
                            return true
                        end,
                    })
                end
            end
        end
        if type(loader.release) == "function" then
            if not self.cover_prefetch then
                self.cover_prefetch = CoverPrefetch:new{ loader = loader, generation = generation,
                    alive = function()
                        return self.cover_loader_generation == generation and self.widget == grid
                            and not grid.closed and not grid.retired
                    end,
                    defer = function(callback) return self:defer(callback) end,
                    on_error = function(spec, err) self:_log_image_error(spec.site_id, "cover", spec.url, err) end }
            end
            self.cover_prefetch:add(background)
        end
        return true
    end
    if not self.http or not self.temp_files or not self.render_image
        or type(self.http.get) ~= "function" then return end
    self:_cancel_covers()
    self.cover_session = self.temp_files:new_session()
    local generation = self.cover_generation
    for index in pairs(grid.cells or {}) do
        local cell = ((model.grid or {}).cells or {})[index]
        if cell and cell.cover_url then
            self.cover_handles[#self.cover_handles + 1] = self.http:get(cell.cover_url,
                { site_id = cell.site_id, stage = "cover",
                    headers = self:_image_headers(cell.site_id, cell.cover_url, cell.cover_headers),
                    inline_response = true, binary = true }, {
                    on_success = function(body, response)
                        if generation ~= self.cover_generation then return end
                        if response and tonumber(response.status) and tonumber(response.status) >= 400 then return end
                        local path = self.temp_files:write(self.cover_session, index, body, "jpg")
                        if not path then return end
                        local ok, buffer = pcall(self.render_image.renderImageFile, self.render_image,
                            path, false, grid.cover_w, grid.cover_h)
                        if ok and buffer and grid:set_cover(index, buffer) == false and buffer.free then
                            pcall(buffer.free, buffer)
                        end
                        if ok and buffer then self:_dirty_root() end
                    end,
                    on_error = function(error, response)
                        self:_log_image_error(cell.site_id, "cover", cell.cover_url, error, response)
                        return true
                    end,
                })
        end
    end
end

function Adapter:_build_detail(model, existing)
    local adapter = self
    local widget = existing
    local registry = self.shell and self.shell.registry
    local source = registry and type(registry.current) == "function" and registry:current() or nil
    local meta = source and source.meta and source:meta() or {}
    model.title = tostring(meta.name or model.site_id or "漫画") .. " · 漫画详情"
    model.on_close = function() return self:_confirm_exit() end
    model.on_render_error = function()
        if adapter.widget ~= widget then return true end
        if adapter.logger and adapter.logger.warn then
            pcall(adapter.logger.warn, "MangaWeb: native detail paint failed",
                Models.error({ code = "render_error" }, model.site_id, "paint"))
        end
        return adapter:_render(model, true)
    end
    if existing then return existing:update_model(model) and existing or nil end
    self.detail_renderer = NativeDetail:new{
        device = self.device,
        input_container = self.input_container, button = self.button,
        frame_container = self.frame_container, center_container = self.center_container,
        horizontal_group = self.horizontal_group, vertical_group = self.vertical_group,
        image_widget = self.image_widget, rect_span = self.rect_span, geom = self.geom,
        gesture_range = self.gesture_range, screen = self.screen, title_bar = self.title_bar,
        text_box_widget = self.text_box_widget, font = self.font, ui_manager = self.ui_manager,
        scrollable_container = self.scrollable_container,
        blitbuffer = self.blitbuffer,
        on_favorite = function(current) return adapter:_show_favorite_picker(current) end,
    }
    widget = self.detail_renderer:show(model)
    return widget
end

function Adapter:_build_panel(model, existing)
    local adapter, actions = self, model.actions or {}
    local widget = existing
    local panel = {
        page = model.page,
        title = "漫画网站",
        navigation = self:_navigation("sites"),
        on_close = function() return self:_confirm_exit() end,
    }
    if model.page == "site_center" then
        panel.title = "我的 · 站点管理"
        panel.on_back = panel.on_close
        panel.rows = {}
        for _, site in ipairs(model.sites or {}) do
            local current = site
            local status = site.status_code == "connected" and "已验证"
                or site.status_code == "session_unverified" and "待验证" or "未配置"
            panel.rows[#panel.rows + 1] = { kind = "section",
                text = tostring(site.name or site.id) .. " · " .. status }
            panel.rows[#panel.rows + 1] = { kind = "actions", items = {
                { text = "进入", callback = site.on_open },
                { text = site.custom and "Cookie / 连接" or "设置 / 域名",
                    callback = site.on_config },
            } }
            if site.custom then
                panel.rows[#panel.rows + 1] = { kind = "actions", items = {
                    { text = "编辑规则", callback = function()
                        return self:_show_site_editor(current.definition, function(draft)
                            return actions.update_site(current.id, draft)
                        end)
                    end },
                    { text = "删除站点", callback = function()
                        return self:_confirm_site_removal(current, actions.remove_site)
                    end },
                } }
            end
        end
        local license_text = model.license_status == "authorized" and "阅读授权 · 已激活"
            or model.license_status == "not_activated" and "阅读授权 · 未激活"
            or "阅读授权 · 本地授权无效"
        panel.rows[#panel.rows + 1] = { kind = "section", text = license_text }
        if actions.manage_license then
            panel.rows[#panel.rows + 1] = {
                kind = "action", text = "管理阅读授权", callback = actions.manage_license,
            }
        end
        panel.actions = {}
        if actions.add_site then
            panel.actions[#panel.actions + 1] = {
                text = "新增自定义站点", callback = function()
                    return self:_show_site_editor(nil, actions.add_site)
                end,
            }
        end
        panel.actions[#panel.actions + 1] = {
            text = "本地分类架", callback = function()
                return self.shell and self.shell:show("categories")
            end }
        panel.actions[#panel.actions + 1] = { text = "退出插件", callback = panel.on_close }
    elseif model.page == "categories" then
        panel.title = "本地分类架"
        panel.status = #((model or {}).items or {}) == 0 and "暂无分类" or "选择分类查看漫画"
        panel.navigation = self:_navigation("library")
        panel.on_back = actions.back
        panel.rows = {}
        for _, category in ipairs(model.items or {}) do
            local current = category
            panel.rows[#panel.rows + 1] = {
                kind = "actions", items = {
                    { text = tostring(current.name or "未命名分类"), callback = current.on_tap },
                    { text = "重命名", callback = function()
                        return self:_show_category_input(function(name)
                            return actions.rename(current, name)
                        end, "重命名分类", current.name)
                    end },
                    { text = "删除", callback = function()
                        return self:_confirm_category_removal(current, actions.remove)
                    end },
                },
            }
        end
        panel.actions = {
            { text = "新建分类", callback = function()
                return self:_show_category_input(actions.create)
            end },
            { text = "返回收藏", callback = actions.back },
        }
    elseif model.page == "settings" then
        panel.title = tostring(model.site_name or model.site_id or "站点") .. " · 站点配置"
        local status = tostring(model.user_message or model.state or "尚未验证")
        local origin = tostring(model.origin or "")
        panel.on_back = actions.back
        panel.status = "状态：" .. status
        panel.rows = { { kind = "info", text = "当前域名：" .. origin } }
        if actions.set_origin then
            panel.rows[#panel.rows + 1] = { kind = "action", text = "修改域名",
                callback = function() return self:_show_zero_origin_input(model) end }
        end
        panel.actions = {}
        if actions.login then
            panel.rows[#panel.rows + 1] = { kind = "section", text = "账号登录" }
            panel.rows[#panel.rows + 1] = { kind = "action", text = "登录并验证",
                callback = function() return self:_show_login_input(model) end }
        end
        panel.rows[#panel.rows + 1] = { kind = "section", text = "Cookie" }
        if model.cookie_only then
            panel.rows[#panel.rows + 1] = { kind = "info", text = "该站点使用浏览器 Cookie 登录" }
        end
        panel.rows[#panel.rows + 1] = { kind = "info",
            text = (model.cookie or "") ~= "" and "已导入" or "未导入" }
        local cookie_actions = {}
        if actions.save_cookie then
            cookie_actions[#cookie_actions + 1] = { text = "导入 Cookie",
                callback = function() return self:_show_cookie_input(model) end }
        end
        if actions.clear_cookie then
            cookie_actions[#cookie_actions + 1] = { text = "清除 Cookie",
                callback = actions.clear_cookie }
        end
        if #cookie_actions > 0 then
            panel.rows[#panel.rows + 1] = { kind = "actions", items = cookie_actions }
        end
        panel.rows[#panel.rows + 1] = { kind = "section", text = "连接验证" }
        if actions.test_connection then
            panel.rows[#panel.rows + 1] = { kind = "action", text = "测试连接",
                callback = actions.test_connection }
        end
        panel.actions[#panel.actions + 1] = { text = "返回站点中心", callback = actions.back }
        if actions.close then panel.actions[#panel.actions + 1] = {
            text = "退出插件", callback = function() return self:_confirm_exit() end,
        } end
    else
        return nil
    end
    panel.on_render_error = function()
        if adapter.widget ~= widget then return true end
        if adapter.logger and adapter.logger.warn then
            pcall(adapter.logger.warn, "MangaWeb: native panel paint failed",
                Models.error({ code = "render_error" }, model.site_id, "paint"))
        end
        return adapter:_render(model, true)
    end
    panel.on_action_error = function()
        panel.status = "操作失败，请重试或返回"
        if adapter.logger and adapter.logger.warn then
            pcall(adapter.logger.warn, "MangaWeb: native panel action failed",
                Models.error({ code = "action_error" }, model.site_id, "action"))
        end
        if adapter.widget == widget and widget then return widget:update_model(panel) end
        return true
    end
    if existing then return existing:update_model(panel) and existing or nil end
    self.panel_renderer = NativePanel:new{
        device = self.device,
        input_container = self.input_container, button = self.button,
        frame_container = self.frame_container, horizontal_group = self.horizontal_group,
        vertical_group = self.vertical_group, title_bar = self.title_bar,
        scrollable_container = self.scrollable_container,
        text_box_widget = self.text_box_widget, font = self.font,
        rect_span = self.rect_span, geom = self.geom, screen = self.screen,
        blitbuffer = self.blitbuffer, ui_manager = self.ui_manager,
    }
    widget = self.panel_renderer:show(panel)
    return widget
end

function Adapter:_load_detail_cover(model, widget)
    local card = ((model or {}).detail or {}).card or {}
    local previews = (model or {}).preview_pages or {}
    local has_images = card.cover_url and card.cover_url ~= "" or #previews > 0
    local loader = self.cover_loader or self.loader
    if loader and type(loader.begin_session) == "function"
        and type(loader.request) == "function" then
        local identity = detail_image_identity(model)
        if not self.cover_loader_generation or self.detail_image_identity ~= identity then
            if not has_images then return end
            self:_cancel_covers()
            self.cover_loader_generation = loader:begin_session("detail")
            self.detail_image_identity = identity
            self.detail_image_requests = {}
            self.detail_image_targets = {}
            self.detail_image_jobs = {}
            self.detail_image_order = 0
        end
        local generation = self.cover_loader_generation
        local requested = self.detail_image_requests
        local targets = self.detail_image_targets
        local jobs = self.detail_image_jobs
        local chapter_id = model.selected_chapter_id or card.chapter_id or card.default_chapter_id
        local preview_offset = (math.max(1, tonumber(model.preview_page) or 1) - 1) * 4
        local wanted = { ["detail:cover"] = card.cover_url and card.cover_url ~= "" and card.cover_url
            or previews[1] and previews[1].url }
        for index = 1, math.min(4, #previews) do
            wanted["detail:preview:" .. tostring(index)] = previews[index].url
        end
        local function retire(role)
            local job = jobs[role]
            if not job then return end
            jobs[role], requested[job.id] = nil, nil
            if job.handle and type(job.handle.cancel) == "function" then job.handle:cancel() end
            if type(loader.release) == "function" then loader:release(generation, job.key) end
        end
        local stale = {}
        for role, job in pairs(jobs) do if wanted[role] ~= job.url then stale[#stale + 1] = role end end
        for _, role in ipairs(stale) do retire(role) end
        targets["detail:cover"] = nil
        for index = 1, 4 do targets["detail:preview:" .. tostring(index)] = nil end
        if not has_images then return true end
        local function queue(url, role, width, height, stage, headers, has_image, install, index)
            if not url or url == "" then return end
            targets[role] = url
            local request_id = role .. "\0" .. tostring(url)
                .. (stage == "preview" and ("\0" .. tostring(chapter_id) .. "\0" .. tostring(index)) or "")
            if requested[request_id] then return end
            if jobs[role] and jobs[role].id ~= request_id then retire(role) end
            if type(has_image) == "function" and has_image(url) then return end
            retire(role)
            requested[request_id] = true
            self.detail_image_order = (self.detail_image_order or 0) + 1
            local loader_key = request_id .. "\0" .. tostring(self.detail_image_order)
            local job = { id = request_id, key = loader_key, url = url }
            jobs[role] = job
            job.handle = loader:request(generation, {
                key = loader_key, url = url, site_id = card.site_id, stage = stage,
                comic_id = card.comic_id, chapter_id = chapter_id, index = index,
                priority = 2, headers = self:_image_headers(card.site_id, url, headers),
                width = width, height = height,
            }, {
                on_ready = function(result)
                    if generation == self.cover_loader_generation then
                        requested[request_id] = nil
                    end
                    if generation ~= self.cover_loader_generation
                        or self.widget ~= widget or widget.closed or widget.retired
                        or targets[role] ~= url then
                        return false
                    end
                    local buffer = result and result.buffer
                    if not buffer then return false end
                    local accepted = install(buffer, url)
                    if accepted ~= false then self:_dirty_root() end
                    return accepted ~= false
                end,
                on_error = function(error)
                    if generation == self.cover_loader_generation then
                        requested[request_id] = nil
                    end
                    if stage == "preview" and generation == self.cover_loader_generation
                        and self.widget == widget and not widget.closed and not widget.retired
                        and targets[role] == url then
                        -- Rebuild only the existing native view. Publishing here
                        -- would immediately submit the same failed jobs again.
                        model.preview_state = "error"
                        model.preview_error = Models.error(error, card.site_id, "preview", "image_error")
                        if type(widget.update_model) == "function" then
                            pcall(widget.update_model, widget, model)
                        end
                        self:_dirty_root()
                    end
                    self:_log_image_error(card.site_id, stage, url, error)
                    return true
                end,
            })
        end
        if card.cover_url and card.cover_url ~= "" then
            queue(card.cover_url, "detail:cover", widget.cover_w, widget.cover_h, "cover",
                card.cover_headers,
                function(url) return widget:has_cover(url) end,
                function(buffer, url) return widget:set_cover(buffer, url) end)
        elseif previews[1] and previews[1].url and previews[1].url ~= "" then
            queue(previews[1].url, "detail:cover", widget.cover_w, widget.cover_h, "preview",
                previews[1].headers,
                function(url) return widget:has_cover(url) end,
                function(buffer, url) return widget:set_cover(buffer, url) end,
                preview_offset + 1)
        end
        for index = 1, math.min(4, #previews) do
            local page = previews[index]
            if page and page.url and page.url ~= "" then
                local preview_index = index
                queue(page.url, "detail:preview:" .. tostring(preview_index), widget.preview_w,
                    widget.preview_h, "preview", page.headers,
                    function(url) return widget:has_preview(preview_index, url) end,
                    function(buffer, url) return widget:set_preview(preview_index, buffer, url) end,
                    preview_offset + preview_index)
            end
        end
        return true
    end
    if not has_images then return end
    if not self.http or not self.temp_files
        or not self.render_image or type(self.http.get) ~= "function" then return end
    self:_cancel_covers()
    self.cover_session = self.temp_files:new_session()
    local generation = self.cover_generation
    local function load(url, index, width, height, options, install)
        self.cover_handles[#self.cover_handles + 1] = self.http:get(url, options, {
            on_success = function(body, response)
                if generation ~= self.cover_generation then return end
                if response and tonumber(response.status) and tonumber(response.status) >= 400 then return end
                local path = self.temp_files:write(self.cover_session, index, body, "jpg")
                if not path then return end
                local ok, buffer = pcall(self.render_image.renderImageFile, self.render_image,
                    path, false, width, height)
                if ok and buffer and install(buffer) == false and buffer.free then
                    pcall(buffer.free, buffer)
                end
                if ok and buffer then self:_dirty_root() end
            end,
            on_error = function(error, response)
                self:_log_image_error(card.site_id, options and options.stage, url, error, response)
                return true
            end,
        })
    end
    if card.cover_url and card.cover_url ~= "" then
        load(card.cover_url, 0, widget.cover_w, widget.cover_h,
            { site_id = card.site_id, stage = "cover",
                headers = self:_image_headers(card.site_id, card.cover_url, card.cover_headers),
                inline_response = true, binary = true },
            function(buffer) return widget:set_cover(buffer, card.cover_url) end)
    elseif previews[1] and previews[1].url and previews[1].url ~= "" then
        load(previews[1].url, 0, widget.cover_w, widget.cover_h,
            { site_id = card.site_id, stage = "cover",
                headers = previews[1].headers or {}, inline_response = true, binary = true },
            function(buffer) return widget:set_cover(buffer, previews[1].url) end)
    end
    for index = 1, math.min(4, #previews) do
        local page = previews[index]
        if page and page.url and page.url ~= "" then
            load(page.url, index, widget.preview_w, widget.preview_h,
                { site_id = card.site_id, stage = "preview", headers = page.headers,
                    inline_response = true, binary = true },
                function(buffer) return widget:set_preview(index, buffer, page.url) end)
        end
    end
end

function Adapter:set_reader(reader)
    self.reader = reader
    return true
end

function Adapter:_source_items(before_switch)
    local items = {}
    if not self.shell or type(self.shell.source_ids) ~= "function" then return items end
    local registry = self.shell.registry
    for _, site_id in ipairs(self.shell:source_ids()) do
        local id = site_id
        local source = registry and registry.sources and registry.sources[id]
        local meta = source and source.meta and source:meta() or {}
        items[#items + 1] = {
            text = tostring(meta.name or id),
            checked_func = function()
                return registry and type(registry.current_id) == "function"
                    and registry:current_id() == id or false
            end,
            callback = function()
                if before_switch then before_switch() end
                if registry and registry.switch then registry:switch(id) end
                return self.shell:show("browse")
            end,
        }
    end
    return items
end

function Adapter:show_source_picker()
    local manager, Menu = self.ui_manager, self.menu
    if not manager or not Menu then return false end
    local function close_picker()
        if self.source_picker and manager.close then manager:close(self.source_picker) end
        self.source_picker = nil
    end
    self.source_picker = Menu:new{
        title = "快速切换站点", item_table = self:_source_items(close_picker), covers_fullscreen = false,
    }
    manager:show(self.source_picker)
    return true
end

function Adapter:_items_for(model)
    model = model or {}
    local items = {
        { text = "退出插件", callback = function() return self:_confirm_exit() end },
        { text = "收藏", callback = function() return self.shell and self.shell:show("library") end },
        { text = "阅读历史", callback = function() return self.shell and self.shell:show("history") end },
        { text = "站点中心", callback = function() return self.shell and self.shell:show("site_center") end },
    }
    if model.page == "site_center" then
        local site_items = items
        local actions = model.actions or {}
        for _, site in ipairs(model.sites or {}) do
            local current = site
            site_items[#site_items + 1] = {
                text = tostring(site.name) .. " · " .. tostring(site.status or (site.connected and "已验证" or "未配置")),
                callback = site.on_open,
            }
            site_items[#site_items + 1] = {
                text = "配置 " .. tostring(site.name),
                callback = site.on_config,
            }
            if site.custom then
                site_items[#site_items + 1] = { text = "编辑规则 " .. tostring(site.name),
                    callback = function()
                        return self:_show_site_editor(current.definition, function(draft)
                            return actions.update_site(current.id, draft)
                        end)
                    end }
                site_items[#site_items + 1] = { text = "删除站点 " .. tostring(site.name),
                    callback = function()
                        return self:_confirm_site_removal(current, actions.remove_site)
                    end }
            end
        end
        site_items[#site_items + 1] = {
            text = model.license_status == "authorized" and "阅读授权 · 已激活"
                or model.license_status == "not_activated" and "阅读授权 · 未激活"
                or "阅读授权 · 本地授权无效",
            enabled = false,
        }
        if (model.actions or {}).manage_license then
            site_items[#site_items + 1] = {
                text = "管理阅读授权", callback = model.actions.manage_license,
            }
        end
        if actions.add_site then
            site_items[#site_items + 1] = { text = "新增自定义站点", callback = function()
                return self:_show_site_editor(nil, actions.add_site)
            end }
        end
        site_items[#site_items + 1] = { text = "本地分类架", callback = function() return self.shell:show("categories") end }
        return site_items
    end

    if model.page == "browse" then
        local actions = model.actions or {}
        for _, item in ipairs(self:_source_items()) do items[#items + 1] = item end
        if actions.categories then
            items[#items + 1] = { text = "分类", callback = function()
                return self:_show_filter_picker("选择分类", actions.categories, actions.select_category)
            end }
        end
        if actions.tags then
            items[#items + 1] = { text = "标签", callback = function()
                return self:_show_filter_picker("选择标签", actions.tags, actions.select_tag)
            end }
        end
        if actions.search then
            items[#items + 1] = { text = "搜索", callback = function() return self:_show_search(actions.search) end }
        end
        if actions.previous_page then items[#items + 1] = { text = "上一页", callback = actions.previous_page } end
        if actions.next_page then items[#items + 1] = { text = "下一页", callback = actions.next_page } end
        if actions.refresh then items[#items + 1] = { text = "刷新", callback = actions.refresh } end
        for _, cell in ipairs((model.grid or {}).cells or {}) do
            local tags = table.concat(cell.tags or {}, ", ")
            local text = card_text(cell, "[封面] ")
            if tags ~= "" then text = text .. "  #" .. tags end
            items[#items + 1] = {
                text = text,
                cover_url = cell.cover_url,
                cover_width = cell.cover_width,
                cover_height = cell.cover_height,
                callback = cell.on_tap,
            }
        end
    elseif model.page == "detail" then
        local detail = model.detail or {}
        local card = detail.card or {}
        items[#items + 1] = { text = card_text(card), cover_url = card.cover_url }
        if card.author then items[#items + 1] = { text = "作者: " .. tostring(card.author) } end
        if card.page_count then items[#items + 1] = { text = "图片: " .. tostring(card.page_count) } end
        if card.tags and #card.tags > 0 then items[#items + 1] = { text = "标签: " .. table.concat(card.tags, ", ") } end
        if detail.description then items[#items + 1] = { text = tostring(detail.description) } end
        local actions = model.actions or {}
        items[#items + 1] = { text = "开始阅读", callback = actions.start_reading }
        items[#items + 1] = {
            text = card.favorite and "已收藏" or "收藏",
            callback = function() return self:_show_favorite_picker(model) end,
        }
        items[#items + 1] = { text = "返回浏览", callback = actions.back }
    elseif model.page == "library" or model.page == "history" then
        local actions = model.actions or {}
        if model.page == "library" then
            if model.selecting then
                items[#items + 1] = { text = "取消多选", callback = actions.cancel_selection }
                items[#items + 1] = { text = "已选 " .. tostring(model.selection_count or 0) .. " 本",
                    enabled = false }
                items[#items + 1] = { text = "调整分类",
                    enabled = (model.selection_count or 0) > 0,
                    callback = function() return self:_show_batch_category_picker(model) end }
            else
                for _, tab in ipairs(model.tabs or {}) do
                    local current = tab
                    items[#items + 1] = {
                        text = current.active and "[" .. tostring(current.name) .. "]"
                            or tostring(current.name),
                        callback = function() return call_action(actions.select_category, current.id) end,
                    }
                end
                if model.official then
                    items[#items + 1] = { text = "刷新官方收藏", enabled = not model.busy, callback = actions.refresh }
                    items[#items + 1] = { text = "取消官方收藏", enabled = not model.busy and model.state == "ready",
                        callback = function() return self:_show_official_removal_picker(model) end }
                    if model.error or model.state == "loading" or model.state == "empty" then
                        items[#items + 1] = { text = (model.error or {}).user_message or model.loading_message
                            or model.empty_message, enabled = false }
                    end
                    if model.error and model.error.code == "login_required" then
                        items[#items + 1] = { text = "重新登录 Zero", callback = actions.relogin }
                    end
                    if (model.total_pages or 1) > 1 then
                        items[#items + 1] = { text = "上一页", callback = actions.previous_page }
                        items[#items + 1] = { text = tostring(model.page_number) .. "/" .. tostring(model.total_pages), enabled = false }
                        items[#items + 1] = { text = "下一页", callback = actions.next_page }
                    end
                else
                    items[#items + 1] = { text = "管理分类", callback = actions.manage_categories }
                    items[#items + 1] = { text = "多选", callback = actions.begin_selection }
                end
            end
        end
        for _, record in ipairs(model.items or {}) do
            items[#items + 1] = {
                text = card_text(record, model.page == "history" and "历史: " or "收藏: "),
                cover_url = record.cover_url,
                callback = record.on_tap or function()
                    return self.shell and self.shell:show_detail(record)
                end,
            }
        end
        items[#items + 1] = { text = "返回站点中心", callback = function()
            return self.shell and self.shell:show("site_center")
        end }
    elseif model.page == "categories" then
        local actions = model.actions or {}
        items[#items + 1] = { text = "新建分类", callback = function()
            return self:_show_category_input(actions.create)
        end }
        for _, category in ipairs(model.items or {}) do
            local current = category
            local name = tostring(current.name or "未命名分类")
            items[#items + 1] = { text = "打开 " .. name, callback = current.on_tap }
            items[#items + 1] = { text = "重命名 " .. name, callback = function()
                return self:_show_category_input(function(value)
                    return call_action(actions.rename, current, value)
                end, "重命名分类", name)
            end }
            items[#items + 1] = { text = "删除 " .. name, callback = function()
                return self:_confirm_category_removal(current, actions.remove)
            end }
        end
        items[#items + 1] = { text = "返回站点中心", callback = actions.back }
    elseif model.page == "category_items" then
        for _, record in ipairs(model.items or {}) do
            items[#items + 1] = { text = card_text(record, "分类: "), cover_url = record.cover_url,
                callback = record.on_tap }
        end
        items[#items + 1] = { text = "返回分类架", callback = (model.actions or {}).back }
    elseif model.page == "settings" then
        local actions = model.actions or {}
        items[#items + 1] = { text = "站点: " .. tostring(model.site_id or "") }
        items[#items + 1] = { text = "状态: " .. tostring(model.user_message or model.state or "ready") }
        if actions.set_origin then items[#items + 1] = {
            text = "修改域名: " .. tostring(model.origin or ""),
            callback = function() return self:_show_zero_origin_input(model) end,
        } end
        if actions.login then
            items[#items + 1] = { text = "账号密码登录并验证", callback = function() return self:_show_login_input(model) end }
        elseif model.cookie_only then
            items[#items + 1] = { text = "该站点需要浏览器 Cookie", enabled = false }
        end
        if actions.save_cookie then
            items[#items + 1] = {
                text = "Cookie: " .. ((model.cookie or "") ~= "" and "已导入" or "未导入"),
                callback = function() return self:_show_cookie_input(model) end,
            }
        end
        if actions.clear_cookie then items[#items + 1] = { text = "清除 Cookie", callback = actions.clear_cookie } end
        if actions.test_connection then items[#items + 1] = { text = "测试连接", callback = actions.test_connection } end
        items[#items + 1] = { text = "返回站点中心", callback = actions.back }
        if actions.close then items[#items + 1] = {
            text = "退出插件", callback = function() return self:_confirm_exit() end,
        } end
    end
    return items
end

function Adapter:_category_panel()
    return NativePanel:new{
        device = self.device, input_container = self.input_container,
        button = self.button, frame_container = self.frame_container,
        horizontal_group = self.horizontal_group, vertical_group = self.vertical_group,
        title_bar = self.title_bar, scrollable_container = self.scrollable_container,
        text_box_widget = self.text_box_widget, font = self.font,
        rect_span = self.rect_span, geom = self.geom, screen = self.screen,
        blitbuffer = self.blitbuffer, ui_manager = self.ui_manager,
    }
end

function Adapter:_confirm_exit()
    if self.exit_confirmation_widget then return true end
    local manager = self.ui_manager
    if not manager or type(manager.show) ~= "function" then return false end
    local confirmation
    local function cancel()
        if confirmation and manager.close then manager:close(confirmation) end
        if self.exit_confirmation_widget == confirmation then
            self.exit_confirmation_widget = nil
        end
        return true
    end
    local function confirm()
        cancel()
        return self.shell and self.shell:close() or false
    end
    confirmation = self:_category_panel():show{
        page = "exit_confirmation", title = "退出插件", modal = true,
        status = "确定退出插件？",
        actions = {
            { text = "取消", callback = cancel },
            { text = "确定退出插件", callback = confirm },
        },
        on_back = cancel, on_close = cancel,
    }
    if not confirmation and self.menu then
        confirmation = self.menu:new{
            title = "确定退出插件？", modal = true, covers_fullscreen = false,
            item_table = {
                { text = "取消", callback = cancel },
                { text = "确定退出插件", callback = confirm },
            },
        }
    end
    if not confirmation then return false end
    self.exit_confirmation_widget = confirmation
    manager:show(confirmation)
    return true
end

function Adapter:_show_local_category_picker(options)
    options = options or {}
    local manager = self.ui_manager
    if not manager or type(manager.show) ~= "function"
        or type(options.on_select) ~= "function" then return false end
    if self.filter_picker and manager.close then manager:close(self.filter_picker) end
    local picker
    local function close_picker()
        if picker and manager.close then manager:close(picker) end
        if self.filter_picker == picker then self.filter_picker = nil end
        return true
    end
    local function choose(category)
        local ok, result = pcall(options.on_select, category)
        if not ok or result == false then return false end
        if self.filter_picker == picker then close_picker() end
        return true
    end
    local rows = { { kind = "action",
        text = options.selected_id == nil and "[默认]" or "默认",
        callback = function() return choose(nil) end } }
    for _, category in ipairs(options.categories or {}) do
        local current = category
        rows[#rows + 1] = { kind = "action",
            text = tostring(options.selected_id) == tostring(current.id)
                and "[" .. tostring(current.name) .. "]" or tostring(current.name),
            callback = function() return choose(current) end }
    end
    local actions = {}
    if type(options.on_create) == "function" then
        actions[#actions + 1] = { text = "新建分类", callback = function()
            close_picker()
            return options.on_create()
        end }
    end
    if type(options.on_remove) == "function" then
        actions[#actions + 1] = { text = "取消收藏", callback = function()
            local ok, result = pcall(options.on_remove)
            if ok and result ~= false then close_picker() end
            return ok and result ~= false
        end }
    end
    actions[#actions + 1] = { text = "返回", callback = close_picker }
    picker = self:_category_panel():show{
        page = "category_picker", title = options.title or "选择分类",
        modal = true, rows = rows, actions = actions,
        on_back = close_picker, on_close = close_picker,
    }
    if not picker then return false end
    self.filter_picker = picker
    manager:show(picker)
    return true
end

function Adapter:_show_favorite_picker(model)
    local actions = (model or {}).actions or {}
    if type(actions.categories) ~= "function" then return false end
    local ok, categories = pcall(actions.categories)
    if not ok then return false end
    local card = (((model or {}).detail or {}).card) or {}
    return self:_show_local_category_picker{
        title = "收藏到分类",
        categories = categories,
        selected_id = model.selected_category_id,
        on_select = actions.select_category,
        on_create = actions.create_category and function()
            return self:_show_category_input(actions.create_category, "新建并收藏")
        end or nil,
        on_remove = card.favorite and actions.toggle_favorite or nil,
    }
end

function Adapter:_show_batch_category_picker(model)
    local categories = {}
    for index = 2, #((model or {}).tabs or {}) do
        if model.tabs[index].kind ~= "official" then categories[#categories + 1] = model.tabs[index] end
    end
    return self:_show_local_category_picker{
        title = "批量调整分类", categories = categories,
        on_select = ((model or {}).actions or {}).assign_selected,
    }
end

function Adapter:_show_category_input(create, title, initial)
    local Dialog, manager = self.multi_input_dialog, self.ui_manager
    if not Dialog or not manager or type(create) ~= "function" then return false end
    local dialog
    dialog = Dialog:new(self:_input_dialog_options({
        title = title or "新建分类",
        fields = {{ description = "分类名称", text = initial or "" }},
        buttons = {{
            { text = "取消", id = "close", callback = function() return self:_close_input_dialog(dialog) end },
            { text = initial and "保存" or "创建", callback = function()
                local fields = dialog:getFields() or {}
                local ok, result = pcall(create, fields[1] or "")
                if ok and result then self:_close_input_dialog(dialog) end
                return true
            end },
        }},
    }, function() return dialog end))
    return self:_show_input_dialog(dialog)
end

function Adapter:_show_site_editor(definition, save)
    return SiteRuleEditor:new{ adapter = self }:show(definition, save)
end

function Adapter:_show_site_rule_help()
    local manager = self.ui_manager
    if not manager or type(manager.show) ~= "function" then return false end
    local panel
    local function close()
        if panel and manager.close then manager:close(panel) end
        if self.filter_picker == panel then self.filter_picker = nil end
        return true
    end
    panel = self:_category_panel():show{
        page = "site_rule_help", title = "自定义站点规则", modal = true,
        rows = {
            { kind = "info", text = "规则使用 Lua 模式；(.-) 表示捕获最短内容。" },
            { kind = "info", text = "列表块可写：(<article.-</article>)" },
            { kind = "info", text = "链接和图片可写：href=\"(.-)\"、src=\"(.-)\"。" },
            { kind = "info", text = "路径以 / 开头；{page} 是页码，{query} 是搜索词。" },
            { kind = "info", text = "无需章节列表时，三个章节规则全部留空。" },
            { kind = "info", text = "阅读页地址不同于详情页时，可用漫画 ID 捕获与 /read/{id}.html。" },
            { kind = "info", text = "图片在脚本数组时，先填数组范围，再填数组内的图片地址捕获。" },
        },
        actions = { { text = "返回编辑", callback = close } },
        on_back = close, on_close = close,
    }
    if not panel then return false end
    self.filter_picker = panel
    manager:show(panel)
    return true
end

function Adapter:_show_zero_origin_input(model)
    local Dialog = self.multi_input_dialog
    local save = (model.actions or {}).set_origin
    if not Dialog or type(save) ~= "function" then return false end
    local open
    open = function(message, value)
        local dialog
        dialog = Dialog:new(self:_input_dialog_options({
            title = message and ("修改 Zero 域名 · " .. message) or "修改 Zero 域名",
            fields = { { description = "HTTPS 根域名", text = value or model.origin or "" } },
            buttons = {{
                { text = "取消", id = "close", callback = function()
                    return self:_close_input_dialog(dialog)
                end },
                { text = "保存域名", callback = function()
                    local fields = dialog:getFields() or {}
                    local origin = fields[1] or ""
                    local called, result, reason = pcall(save, origin)
                    self:_close_input_dialog(dialog)
                    if called and result then return true end
                    return open(SiteRuleEditor.error_text(
                        called and reason or "settings_save_failed"), origin)
                end },
            }},
        }, function() return dialog end))
        return self:_show_input_dialog(dialog)
    end
    return open()
end

function Adapter:_confirm_site_removal(site, remove)
    local manager = self.ui_manager
    if not manager or type(manager.show) ~= "function"
        or type(remove) ~= "function" or not site or not site.custom then return false end
    local confirmation
    local function close()
        if confirmation and manager.close then manager:close(confirmation) end
        if self.filter_picker == confirmation then self.filter_picker = nil end
        return true
    end
    confirmation = self:_category_panel():show{
        page = "site_remove_confirm", title = "删除自定义站点", modal = true,
        status = "删除“" .. tostring(site.name or site.id)
            .. "”的站点配置？本地收藏和阅读历史仍保留。",
        actions = {
            { text = "取消", callback = close },
            { text = "确定删除", callback = function()
                local called, result = pcall(remove, site.id)
                if called and result then close() end
                return called and result or false
            end },
        },
        on_back = close, on_close = close,
    }
    if not confirmation then return false end
    self.filter_picker = confirmation
    manager:show(confirmation)
    return true
end

function Adapter:_confirm_category_removal(category, remove)
    local manager = self.ui_manager
    if not manager or type(manager.show) ~= "function"
        or type(remove) ~= "function" then return false end
    local confirmation
    local function cancel()
        if confirmation and manager.close then manager:close(confirmation) end
        if self.filter_picker == confirmation then self.filter_picker = nil end
        return true
    end
    confirmation = self:_category_panel():show{
        page = "category_remove_confirm", title = "删除分类", modal = true,
        status = "删除“" .. tostring((category or {}).name or "") .. "”？漫画仍保留在收藏中。",
        actions = {
            { text = "取消", callback = cancel },
            { text = "确定删除", callback = function()
                local ok, result = pcall(remove, category)
                if ok and result ~= false then cancel() end
                return ok and result ~= false
            end },
        },
        on_back = cancel, on_close = cancel,
    }
    if not confirmation then return false end
    self.filter_picker = confirmation
    manager:show(confirmation)
    return true
end

function Adapter:_show_filter_picker(title, loader, choose)
    local manager, Menu = self.ui_manager, self.menu
    if not manager or not Menu then return false end
    return call_action(loader, function(values, error)
        local picker
        local function close_picker()
            if picker and manager.close then manager:close(picker) end
            if self.filter_picker == picker then self.filter_picker = nil end
            return true
        end
        local rows = {}
        for _, value in ipairs(values or {}) do
            local current = value
            rows[#rows + 1] = {
                kind = "action",
                text = type(current) == "table"
                    and tostring(current.name or current.title or current.id or "") or tostring(current),
                callback = function()
                    close_picker()
                    return call_action(choose, current)
                end,
            }
        end
        local renderer = NativePanel:new{
            device = self.device,
            input_container = self.input_container, button = self.button,
            frame_container = self.frame_container, horizontal_group = self.horizontal_group,
            vertical_group = self.vertical_group, title_bar = self.title_bar,
            scrollable_container = self.scrollable_container,
            text_box_widget = self.text_box_widget, font = self.font,
            rect_span = self.rect_span, geom = self.geom, screen = self.screen,
            blitbuffer = self.blitbuffer, ui_manager = self.ui_manager,
        }
        picker = renderer:show{
            title = title, rows = rows, modal = true,
            status = #rows == 0
                and tostring(error and (error.user_message or error.code) or "没有可用选项") or nil,
            actions = { { text = "返回", callback = close_picker } },
            on_back = close_picker,
            on_close = close_picker,
            on_render_error = close_picker,
        }
        if picker then
            self.filter_picker = picker
            manager:show(picker)
            return true
        end
        local items = {}
        for _, value in ipairs(values or {}) do
            local current = value
            items[#items + 1] = {
                text = type(current) == "table"
                    and tostring(current.name or current.title or current.id or "") or tostring(current),
                callback = function()
                    if self.filter_picker and manager.close then manager:close(self.filter_picker) end
                    self.filter_picker = nil
                    return call_action(choose, current)
                end,
            }
        end
        if #items == 0 then
            items[1] = { text = tostring(error and (error.user_message or error.code) or "没有可用选项"), enabled = false }
        end
        self.filter_picker = Menu:new{
            title = title, item_table = items, modal = true, covers_fullscreen = false,
        }
        manager:show(self.filter_picker)
        return true
    end)
end

function Adapter:_show_login_input(model)
    local Dialog, manager = self.multi_input_dialog, self.ui_manager
    local login = model.actions and model.actions.login
    if not Dialog or not manager then return false end
    local fields = {
        { description = "账号", text = tostring(model.username or "") },
        { description = "密码", text = tostring(model.password or ""), text_type = "password" },
    }
    if model.site_id == "zero" then
        fields[#fields + 1] = { description = "安全问题编号（0=未设置，1-7）", text = "0" }
        fields[#fields + 1] = { description = "安全问题答案（可空）", text = "" }
    end
    local dialog
    dialog = Dialog:new(self:_input_dialog_options({
        title = "登录 " .. tostring(model.site_id or ""),
        fields = fields,
        buttons = {{
            { text = "取消", id = "close", callback = function() return self:_close_input_dialog(dialog) end },
            { text = "登录并验证", callback = function()
                local values = dialog:getFields() or {}
                self:_close_input_dialog(dialog)
                return call_action(login, { username = values[1] or "", password = values[2] or "",
                    question_id = values[3], answer = values[4] })
            end },
        }},
    }, function() return dialog end))
    return self:_show_input_dialog(dialog)
end

function Adapter:_show_search(search, title)
    local Dialog, manager = self.multi_input_dialog, self.ui_manager
    if not Dialog or not manager then return call_action(search, "") end
    local dialog
    dialog = Dialog:new(self:_input_dialog_options({
        title = title or "搜索漫画",
        fields = {{ description = "关键词", text = "" }},
        buttons = {{ { text = "取消", id = "close", callback = function() return self:_close_input_dialog(dialog) end },
            { text = "搜索", callback = function()
                local fields = dialog:getFields() or {}
                self:_close_input_dialog(dialog)
                return call_action(search, fields[1] or "")
            end } }},
    }, function() return dialog end))
    return self:_show_input_dialog(dialog)
end

function Adapter:_show_cookie_input(model)
    local Dialog, manager = self.multi_input_dialog, self.ui_manager
    local save = model.actions and model.actions.save_cookie
    if not Dialog or not manager then return call_action(save, model.cookie or "") end
    local dialog
    dialog = Dialog:new(self:_input_dialog_options({
        title = "导入 " .. tostring(model.site_id or "") .. " Cookie",
        fields = {{ description = "Cookie", text = model.cookie or "" }},
        buttons = {{ { text = "取消", id = "close", callback = function() return self:_close_input_dialog(dialog) end },
            { text = "保存", callback = function()
                local fields = dialog:getFields() or {}
                local ok, result = pcall(save, fields[1] or "")
                local state = self.shell and self.shell:model() and self.shell:model().state
                if ok and result and (not state or state == "ready") then self:_close_input_dialog(dialog) end
                return true
            end } }},
    }, function() return dialog end))
    return self:_show_input_dialog(dialog)
end

function Adapter:_render(model, force_menu)
    local manager, Menu = self.ui_manager, self.menu
    if not manager or not Menu then return false end
    local previous = self.widget
    local keep_detail_images = not force_menu and previous and model
        and previous.page_id == "detail" and model.page == "detail"
        and self.detail_image_identity == detail_image_identity(model)
    local keep_grid_images = not force_menu and previous and model
        and (model.page == "browse" or model.page == "library"
            or model.page == "history" or model.page == "category_items")
        and previous.page_id == model.page and previous == self.cover_grid
        and type(previous.update_model) == "function"
    if not keep_detail_images and not keep_grid_images then self:_cancel_covers() end
    if self.error_widget and manager.close then manager:close(self.error_widget) end
    self.error_widget = nil
    local widget, after_show
    local reusable = not force_menu and previous and model
        and previous.page_id == model.page and type(previous.update_model) == "function"
        and previous or nil
    local built, build_error = pcall(function()
        if not force_menu and model
            and (model.page == "site_center" or model.page == "settings"
                or model.page == "categories") then
            widget = self:_build_panel(model, reusable)
        elseif not force_menu and model and model.page == "browse" then
            widget = self:_build_grid(model, reusable)
            if widget then after_show = function() self:_load_covers(model, widget) end end
        elseif not force_menu and model
            and (model.page == "library" or model.page == "history" or model.page == "category_items") then
            widget = self:_build_collection_grid(model, reusable)
            if widget then after_show = function() self:_load_covers(model, widget) end end
        elseif not force_menu and model and model.page == "detail" then
            widget = self:_build_detail(model, reusable)
            if widget then after_show = function() self:_load_detail_cover(model, widget) end end
        end
    end)
    if not built then
        if self.logger and self.logger.warn then
            pcall(self.logger.warn, "MangaWeb: page render failed",
                Models.error({ code = "render_error" }, model.site_id or (model.site or {}).id, "render"))
        end
        widget, after_show = nil, nil
    end
    if reusable and widget == reusable then
        self.widget = widget
        if after_show then pcall(after_show) end
        self:_dirty_root()
        return true
    end
    if self.source_picker and manager.close then manager:close(self.source_picker) end
    self.source_picker = nil
    if self.filter_picker and manager.close then manager:close(self.filter_picker) end
    self.filter_picker = nil
    if not widget then
        if keep_detail_images or keep_grid_images then self:_cancel_covers() end
        local fallback_built, fallback_error = pcall(function()
            local menu
            local function route_back()
                if menu and menu.skip_close_callback then return true end
                if self.widget == menu then self.widget = nil end
                local actions = (model or {}).actions or {}
                if model and model.page == "site_center" then
                    return self:_confirm_exit()
                end
                if actions.back then return call_action(actions.back) end
                if actions.site_center then return call_action(actions.site_center) end
                return self.shell and self.shell:show("site_center")
            end
            menu = Menu:new{
                title = "漫画网站 · " .. tostring((model or {}).page or "浏览"),
                item_table = self:_items_for(model),
                covers_fullscreen = true,
                is_popout = false,
                single_line = false,
                close_callback = route_back,
                onMenuSelect = function(_, item) return call_action(item and item.callback) end,
            }
            menu.page_id = model and model.page
            widget = menu
        end)
        if not fallback_built or not widget then
            if self.logger and self.logger.warn then
                pcall(self.logger.warn, "MangaWeb: fallback render failed",
                    Models.error({ code = "render_error" }, model.site_id or (model.site or {}).id, "fallback"))
            end
            return false
        end
    end
    self.widget = widget
    local on_back = function()
        if widget and type(widget.onBack) == "function" then return widget:onBack() end
        return true
    end
    local shown, show_error = pcall(function()
        if self.root_renderer.shown then return self.root_renderer:replace(widget, on_back) end
        return self.root_renderer:show(widget, on_back)
    end)
    if not shown or show_error == false then return false end
    self.root_widget = self.root_renderer.root_widget
    if after_show then pcall(after_show) end
    return true
end

function Adapter:show_fullscreen(shell)
    self.shell = shell
    return self:_render(shell and shell:model() or {})
end

function Adapter:update_model(model)
    if self.shell then return self:_render(model or self.shell:model()) end
    return false
end

local function tap_region(region, x, width)
    if region == "left" or region == "right" or region == "center" then return region end
    if not x then return "center" end
    width = math.max(1, tonumber(width) or 1)
    if x < width / 3 then return "left" end
    if x > width * 2 / 3 then return "right" end
    return "center"
end

function Adapter:_close_reader_controls()
    local manager = self.ui_manager
    local current = self.reader_controls
    self.reader_controls = nil
    if current and self.reader_widget
        and current == self.reader_widget.embedded_controls then
        self.reader_widget:close_controls()
    elseif current and manager and manager.close then
        pcall(manager.close, manager, current)
    end
    local page = self.reader_widget
    if page then
        page.external_controls = nil
        if page.graydither_bridge and page:_graydither_ready() then page.graydither_bridge:resume() end
    end
    return true
end

function Adapter:_official_model_current(model)
    return self.shell and type(self.shell.model) == "function" and self.shell:model() == model
        and model.page == "library" and model.official and not model.busy and not model.error
end

function Adapter:_build_official_dialog(options)
    local ok, panel = pcall(function() return self:_category_panel():show(options) end)
    if ok and panel then return panel end
    if not self.menu then return nil end
    local items = {}
    if options.status then items[#items + 1] = { text = options.status, enabled = false } end
    for _, row in ipairs(options.rows or {}) do
        items[#items + 1] = { text = row.text, callback = row.callback, enabled = row.kind == "action" }
    end
    for _, button in ipairs(options.actions or {}) do items[#items + 1] = button end
    return self.menu:new{
        title = options.title, item_table = items, modal = true,
        covers_fullscreen = false, is_popout = true, single_line = false,
        close_callback = options.on_back,
        onMenuSelect = function(_, item) return call_action(item and item.callback) end,
    }
end

function Adapter:_show_official_removal_picker(model)
    if not self:_official_model_current(model) or model.state ~= "ready" then return false end
    local manager = self.ui_manager
    if not manager or type(manager.show) ~= "function" then return false end
    if self.filter_picker and manager.close then manager:close(self.filter_picker) end
    local picker, closed
    local function close()
        if closed then return true end
        closed = true
        if picker and manager.close then manager:close(picker) end
        if self.filter_picker == picker then self.filter_picker = nil end
        return true
    end
    local rows = {}
    for _, record in ipairs(model.items or {}) do
        local item = record
        rows[#rows + 1] = { kind = "action", text = tostring(item.title or "漫画"), callback = function()
            if closed or self.filter_picker ~= picker or not self:_official_model_current(model) then return false end
            close()
            return self:_confirm_official_removal(model, item)
        end }
    end
    picker = self:_build_official_dialog{
        page = "official_remove_picker", title = "选择要取消的官方收藏", modal = true,
        status = "取消后也会从 Zero 网页端收藏夹移除。",
        rows = rows, actions = { { text = "返回", callback = close } }, on_back = close, on_close = close,
    }
    if not picker then return false end
    self.filter_picker = picker
    manager:show(picker)
    return true
end

function Adapter:_confirm_official_removal(model, record)
    if not self:_official_model_current(model) then return false end
    local actions, manager = model.actions or {}, self.ui_manager
    if type(actions.remove_official) ~= "function" or type(actions.can_remove_official) ~= "function"
        or not actions.can_remove_official(record) or not manager or not manager.show then return false end
    local confirmation, finished
    local function close()
        if finished then return true end
        finished = true
        if confirmation and manager.close then manager:close(confirmation) end
        if self.filter_picker == confirmation then self.filter_picker = nil end
        return true
    end
    confirmation = self:_build_official_dialog{
        page = "official_remove_confirm", title = "取消官方收藏", modal = true,
        status = "确定取消“" .. tostring(record.title or "漫画") .. "”的官方收藏？\n同时取消 Zero 网页端收藏，本地收藏保持不变。",
        actions = {
            { text = "返回", callback = close },
            { text = "确定取消收藏", callback = function()
                if finished or self.filter_picker ~= confirmation or not self:_official_model_current(model)
                    or not actions.can_remove_official(record) then return false end
                close()
                local ok, result = pcall(actions.remove_official, record)
                return ok and result ~= false
            end },
        }, on_back = close, on_close = close,
    }
    if not confirmation then return false end
    self.filter_picker = confirmation
    manager:show(confirmation)
    return true
end

function Adapter:_show_reader_panel(model)
    local manager = self.ui_manager
    if not manager then return false end
    if self.reader_renderer and type(self.reader_renderer.show_controls) == "function"
        and self.reader_renderer:show_controls(model) then
        self.reader_controls = self.reader_widget.embedded_controls
        return true
    end
    local renderer = NativePanel:new{
        device = self.device, input_container = self.input_container,
        button = self.button, frame_container = self.frame_container,
        horizontal_group = self.horizontal_group, vertical_group = self.vertical_group,
        title_bar = self.title_bar, scrollable_container = self.scrollable_container,
        text_box_widget = self.text_box_widget, font = self.font,
        rect_span = self.rect_span, geom = self.geom, screen = self.screen,
        blitbuffer = self.blitbuffer, ui_manager = manager,
    }
    local controls = renderer:show(model)
    if not controls and self.menu then
        local fallback_items = {}
        if model.status then fallback_items[#fallback_items+1] = {text=model.status,select_enabled=false} end
        for _, row in ipairs(model.rows or {}) do
            if row.kind == "info" then
                fallback_items[#fallback_items+1] = {text=row.text,select_enabled=false}
            end
            for _, value in ipairs(row.items or {}) do
                fallback_items[#fallback_items + 1] = value
            end
        end
        for _, value in ipairs(model.actions or {}) do fallback_items[#fallback_items + 1] = value end
        for _, value in ipairs(model.navigation or {}) do fallback_items[#fallback_items + 1] = value end
        controls = self.menu:new{
            title = model.title, item_table = fallback_items, modal = true,
            covers_fullscreen = false, close_callback = model.on_back or model.on_close,
            onMenuSelect = function(_, selected)
                if selected.select_enabled ~= false then call_action(selected.callback) end
                return true
            end,
        }
    end
    if not controls then return false end
    self:_close_reader_controls()
    self.reader_controls = controls
    if self.reader_widget then
        self.reader_widget.external_controls = true
        if self.reader_widget.graydither_bridge then self.reader_widget.graydither_bridge:pause() end
    end
    manager:show(controls)
    return true
end

function Adapter:_show_reader_controls(section)
    local manager, reader = self.ui_manager, self.reader
    if not manager or not reader then return false end
    section = section or "root"
    if section == "gray" or section == "tone" then
        if not self.reader_filters or self.reader_filters.reader ~= reader then
            self.reader_filters = ReaderFilters:new{adapter=self,reader=reader}
        end
        return self.reader_filters:show(section)
    end
    local snapshot = type(reader.settings_snapshot) == "function"
        and reader:settings_snapshot() or {}
    local function setting(name, fallback)
        local value = snapshot[name]
        return value == nil and fallback or value
    end
    local function close_controls() return self:_close_reader_controls() end
    local function show_section(name)
        if not (self.reader_widget and self.reader_widget.embedded_controls) then
            close_controls()
        end
        return self:_show_reader_controls(name)
    end
    local function show_picker()
        if not (self.reader_widget and self.reader_widget.embedded_controls) then
            close_controls()
        end
        return self:_show_page_picker()
    end
    local function update(changes)
        if type(reader.update_settings) ~= "function" then return false end
        local ok, saved = pcall(reader.update_settings, reader, changes)
        if not ok or saved == false then return false end
        if changes.direction then
            self.reading_rtl = changes.direction == "rtl"
            if self.reader_widget and type(self.reader_widget.set_direction) == "function" then
                self.reader_widget:set_direction(changes.direction)
            end
        end
        return show_section(section)
    end
    local function item(text, callback) return { text = text, callback = callback } end
    local function rows_from(items)
        local rows = {}
        for index = 1, #items, 2 do
            rows[#rows + 1] = { kind = "actions", items = {
                items[index], items[index + 1],
            } }
        end
        return rows
    end
    local function exit_reader()
        close_controls()
        return reader:close("back")
    end
    local function return_shelf()
        exit_reader()
        if self.shell and type(self.shell.show) == "function" then
            return self.shell:show("browse")
        end
        return true
    end
    local license_dialog = self.shell and self.shell.license_dialog
    local function manage_license()
        if self.reader ~= reader or reader.closed then return false end
        if not license_dialog or type(license_dialog.show_manager) ~= "function" then
            return false
        end
        return license_dialog:show_manager(function()
            if self.reader ~= reader or reader.closed then return end
            local license = license_dialog.license
            local checked, authorized = false, false
            if license and type(license.is_authorized) == "function" then
                checked, authorized = pcall(license.is_authorized, license)
            end
            if not checked or authorized ~= true then
                close_controls()
                reader:close("back")
            end
        end)
    end
    local title, items
    if section == "graydither" then
        title, items = "灰度与全刷", {}
    elseif section == "reading" then
        title = "阅读翻页"
        local direction = setting("direction", "ltr")
        items = {
            item(direction == "rtl" and "方向：日漫反向" or "方向：普通", function()
                return update{ direction = direction == "rtl" and "ltr" or "rtl" }
            end),
        }
    elseif section == "preload" then
        title, items = "阅读预加载", {}
        local selected = math.max(0, math.min(10,
            math.floor(tonumber(setting("preload_pages", 3)) or 3)))
        for count = 0, 10 do
            local pages = count
            local text = pages == 0 and "关闭预加载" or ("后续" .. tostring(pages) .. "页")
            items[#items + 1] = item((pages == selected and "✓ " or "") .. text, function()
                return update{ preload_pages = pages }
            end)
        end
    elseif section == "display" then
        title = "图片显示"
        local fit = setting("fit_mode", "page")
        items = {
            item(fit == "width" and "显示：适宽" or "显示：整页", function()
                return update{ fit_mode = fit == "width" and "page" or "width" }
            end),
            item("跳转图片", show_picker),
        }
    elseif section == "split" then
        title = "宽图拆分"
        local enabled = setting("split_enabled", false)
        local cut = math.max(10, math.min(90,
            math.floor(tonumber(setting("split_cut_percent", 50)) or 50)))
        items = {
            item("自动拆分：" .. (enabled and "开" or "关"), function()
                return update{ split_enabled = not enabled }
            end),
            item("左右切分：" .. tostring(cut) .. "%", function()
                return update{ split_cut_percent = cut >= 90 and 10 or cut + 10 }
            end),
        }
    elseif section == "cache" then
        title = "图片缓存"
        local upper = tonumber(setting("cache_upper_mb", 256)) or 256
        local lower = tonumber(setting("cache_lower_mb", 192)) or 192
        local upper_values = { 64, 128, 256, 512, 1024, 2048 }
        local lower_values = { 0, upper / 4, upper / 2, upper * 3 / 4 }
        items = {
            item("缓存上限：" .. tostring(upper) .. " MB", function()
                local next_upper = cycle(upper, upper_values)
                return update{ cache_upper_mb = next_upper,
                    cache_lower_mb = math.min(lower, next_upper * 3 / 4) }
            end),
            item("清理下限：" .. tostring(lower) .. " MB", function()
                return update{ cache_lower_mb = cycle(lower, lower_values) }
            end),
        }
    else
        section, title = "root", "阅读设置"
        items = {
            item("阅读翻页", function() return show_section("reading") end),
            item("阅读预加载", function() return show_section("preload") end),
            item("图片显示", function() return show_section("display") end),
            item("宽图拆分", function() return show_section("split") end),
            item("漫画去灰增强", function() return show_section("gray") end),
            item("亮度与对比度", function() return show_section("tone") end),
            item("灰度与全刷", function() return self:_show_graydither_controls() end),
            item("跳转图片", show_picker),
            item("重试当前页", function()
                close_controls()
                return reader:retry()
            end),
            item("返回 MangaWeb 书架首页", return_shelf),
            item("图片缓存", function() return show_section("cache") end),
            item("继续阅读", close_controls),
        }
        if license_dialog and type(license_dialog.show_manager) == "function" then
            table.insert(items, #items, item("授权密钥管理", manage_license))
        end
    end
    local navigation = {
        item(section == "root" and "跳转图片" or "← 返回设置", function()
            if section == "root" then
                return show_picker()
            end
            return show_section("root")
        end),
        item("返回阅读", close_controls),
        item("退出阅读", exit_reader),
    }
    local model = {
        modal = true, title = title, rows = rows_from(items), navigation = navigation,
        status = section == "preload" and "提前下载后续图片，完成后翻页直接读取缓存。默认3页。"
            or section == "graydither" and "需要安装并启用兼容版本的灰度插件；共享服务当前不可用。" or nil,
        on_back = section == "root" and close_controls
            or function() return show_section("root") end,
        on_close = close_controls,
    }
    return self:_show_reader_panel(model)
end

function Adapter:_show_graydither_controls()
    local page = self.reader_widget
    local bridge = page and page.graydither_bridge
    if bridge and bridge:isAvailable() then
        self:_close_reader_controls()
        if bridge:showMenu(function()
            if self.reader_widget == page and not page.released then
                self:_close_reader_controls()
            end
        end) then return true end
    end
    return self:_show_reader_controls("graydither")
end

function Adapter:_turn_from_edge(edge)
    local reader = self.reader
    if not reader then return true end
    local forward = edge == "right"
    if self.reading_rtl then forward = not forward end
    if forward then return call_action(function() return reader:next() end) end
    return call_action(function() return reader:previous() end)
end

function Adapter:_show_page_picker(selected)
    local manager, reader = self.ui_manager, self.reader
    if not manager or not reader or type(reader.go_to) ~= "function" then return false end
    local total = math.max(1, reader.context and #(reader.context.pages or {}) or 1)
    local value = math.max(1, math.min(total,
        math.floor(tonumber(selected or reader:current_page()) or 1)))
    local function close_picker()
        return self:_close_reader_controls()
    end
    local function step(delta)
        if not (self.reader_widget and self.reader_widget.embedded_controls) then
            close_picker()
        end
        return self:_show_page_picker(math.max(1, math.min(total, value + delta)))
    end
    local function choose()
        close_picker()
        return call_action(function() return reader:go_to(value) end)
    end
    local function item(text, callback) return { text = text, callback = callback } end
    local model = {
        modal = true, title = "跳转图片",
        rows = {
            { kind = "info", text = ("第 %d / %d 张"):format(value, total) },
            { kind = "actions", items = { item("-20", function() return step(-20) end),
                item("-10", function() return step(-10) end) } },
            { kind = "actions", items = { item("-1", function() return step(-1) end),
                item("+1", function() return step(1) end) } },
            { kind = "actions", items = { item("+10", function() return step(10) end),
                item("+20", function() return step(20) end) } },
        },
        navigation = { item("← 返回设置", function()
                if not (self.reader_widget and self.reader_widget.embedded_controls) then
                    close_picker()
                end
                return self:_show_reader_controls()
            end), item("跳转", choose), item("返回阅读", close_picker) },
        on_back = close_picker, on_close = close_picker,
    }
    if self.reader_renderer and type(self.reader_renderer.show_page_picker) == "function"
        and self.reader_renderer:show_page_picker(model) then
        self.reader_controls = self.reader_widget.embedded_controls
        return true
    end
    local renderer = NativePanel:new{
        device = self.device, input_container = self.input_container,
        button = self.button, frame_container = self.frame_container,
        horizontal_group = self.horizontal_group, vertical_group = self.vertical_group,
        title_bar = self.title_bar, scrollable_container = self.scrollable_container,
        text_box_widget = self.text_box_widget, font = self.font,
        rect_span = self.rect_span, geom = self.geom, screen = self.screen,
        blitbuffer = self.blitbuffer, ui_manager = manager,
    }
    local picker = renderer:show(model)
    if not picker and self.menu then
        local items = {}
        for _, row in ipairs(model.rows) do
            for _, action in ipairs(row.items or {}) do items[#items + 1] = action end
        end
        for _, action in ipairs(model.navigation) do items[#items + 1] = action end
        picker = self.menu:new{ title = model.title, item_table = items, modal = true }
    end
    if not picker then return false end
    close_picker()
    self.reader_controls = picker
    if self.reader_widget then
        self.reader_widget.external_controls = true
        if self.reader_widget.graydither_bridge then self.reader_widget.graydither_bridge:pause() end
    end
    manager:show(picker)
    return true
end

function Adapter:_reader_actions()
    local adapter = self
    return {
        previous = function()
            return adapter.reader and call_action(function() return adapter.reader:previous() end)
        end,
        next = function()
            return adapter.reader and call_action(function() return adapter.reader:next() end)
        end,
        back = function()
            return adapter.reader and call_action(function() return adapter.reader:close("back") end)
        end,
        page_picker = function() return adapter:_show_page_picker() end,
        settings = function() return adapter:_show_reader_controls() end,
        go_to = function(page_number)
            return adapter.reader and call_action(function() return adapter.reader:go_to(page_number) end)
        end,
        retry = function()
            return adapter.reader and call_action(function() return adapter.reader:retry() end)
        end,
        exit = function()
            return adapter.reader and call_action(function() return adapter.reader:close("back") end)
        end,
        render_error = function()
            if adapter.logger and adapter.logger.warn then
                pcall(adapter.logger.warn, "MangaWeb: native reader paint failed",
                    Models.error({ code = "render_error" }, nil, "paint"))
            end
            return adapter.reader
                and call_action(function() return adapter.reader:close("back") end)
        end,
    }
end

function Adapter:_new_reader_renderer()
    return ReaderShell:new{
        input_container = self.input_container, image_widget = self.image_widget,
        frame_container = self.frame_container, center_container = self.center_container,
        horizontal_group = self.horizontal_group, vertical_group = self.vertical_group,
        overlap_group = self.overlap_group, button = self.button,
        text_widget = self.text_widget, text_box_widget = self.text_box_widget,
        scrollable_container = self.scrollable_container, title_bar = self.title_bar,
        progress_widget = self.progress_widget, gesture_range = self.gesture_range,
        geom = self.geom, screen = self.screen, ui_manager = self.ui_manager,
        font = self.font, blitbuffer = self.blitbuffer, device = self.device,
        rect_span = self.rect_span,
        create_graydither_bridge = function(page)
            return GrayDitherBridge:new{
                owner = page, settings = self.reader and self.reader.settings,
                is_ready = function() return page:_graydither_ready() end,
                redraw = function() if not page.released then page:_dirty() end end,
            }
        end,
    }
end

function Adapter:show_page_loading(index, total)
    -- A detail page can still have cover/preview requests in flight when the
    -- user taps Start Reading. Cancel them before the reader session starts;
    -- otherwise the reader's first page waits behind up to five image jobs.
    self:_cancel_covers()
    self.reader_loading = { index = index, total = total }
    self.last_progress_paint = nil
    if self.reader_widget and type(self.reader_widget.set_loading) == "function" then
        return self.reader_widget:set_loading(true, index, total)
    end
    local manager = self.ui_manager
    if not manager or type(manager.show) ~= "function" then return false end
    local renderer = self:_new_reader_renderer()
    local page = renderer:show{
        loading = true, index = index, total = total, controls_visible = true,
        direction = self.reading_rtl and "rtl" or "ltr",
        actions = self:_reader_actions(),
    }
    if not page then return false end
    if self.reader_renderer then
        self.reader_renderer:close()
    elseif self.reader_widget and manager.close then
        pcall(manager.close, manager, self.reader_widget)
    end
    self.reader_renderer, self.reader_widget = renderer, page
    local shown = pcall(manager.show, manager, page)
    return shown
end

function Adapter:show_download_progress(bytes, total)
    if not self.reader_loading or not self.reader_widget
        or type(self.reader_widget.set_download_progress) ~= "function" then return false end
    local ok, now = pcall(self.progress_clock)
    now = ok and tonumber(now) or os.time()
    if self.last_progress_paint and now - self.last_progress_paint < 2 then return true end
    local updated = self.reader_widget:set_download_progress(bytes, total)
    if updated then self.last_progress_paint = now end
    return updated
end

function Adapter:reader_viewport()
    if self.reader_widget then return self.reader_widget.width, self.reader_widget.height end
    local screen = self.screen
    return screen:getWidth(), screen:getHeight()
end

function Adapter:show_page(path, index, total, options)
    options = options or {}
    self.reader_loading = nil
    self.last_progress_paint = nil
    local manager, ImageWidget = self.ui_manager, self.image_widget
    if not manager or not ImageWidget then return false end
    if self.error_widget and manager.close then manager:close(self.error_widget) end
    self.error_widget = nil
    if self.reader_renderer and self.reader_widget
        and type(self.reader_widget.update_page) == "function" then
        self.reader_renderer.deps.image_widget = self.image_widget
        return self.reader_widget:update_page(path, index, total, options)
    end
    local next_renderer = self:_new_reader_renderer()
    local page = next_renderer:show{
        path = path, index = index, total = total, controls_visible = false,
        direction = options.direction or (self.reading_rtl and "rtl" or "ltr"),
        segment = options.segment, pan_y = options.pan_y, fit_mode = options.fit_mode,
        split_cut_percent = options.split_cut_percent,
        processing_error = options.processing_error,
        actions = self:_reader_actions(),
    }
    if not page then return false end
    if self.reader_renderer then
        self.reader_renderer:close()
    elseif self.reader_widget and manager.close then
        manager:close(self.reader_widget)
    end
    self.reader_renderer, self.reader_widget = next_renderer, page
    manager:show(page)
    return true
end

function Adapter:close_reader(reason)
    if self.reader_filters then self.reader_filters:close(); self.reader_filters=nil end
    local manager = self.ui_manager
    if manager and manager.close then
        if self.error_widget then manager:close(self.error_widget) end
        if self.reader_controls and (not self.reader_widget
            or self.reader_controls ~= self.reader_widget.embedded_controls) then
            manager:close(self.reader_controls)
        end
    end
    if self.reader_renderer then
        self.reader_renderer:close()
    elseif manager and manager.close and self.reader_widget then
        manager:close(self.reader_widget)
    elseif self.reader_widget and self.reader_widget.release then
        self.reader_widget:release()
    end
    self.error_widget, self.reader_controls, self.reader_widget, self.reader_renderer = nil, nil, nil, nil
    self.reader_loading, self.last_progress_paint = nil, nil
    return true
end

function Adapter:show_error(error)
    error = Models.error(error)
    local manager = self.ui_manager
    if self.reader_widget and type(self.reader_widget.set_error) == "function" then
        if type(self.reader_widget.set_loading) == "function" then
            self.reader_widget:set_loading(false)
        end
        return self.reader_widget:set_error(error)
    end
    if manager and self.menu then
        if self.error_widget and manager.close then manager:close(self.error_widget) end
        local items = {
            { text = tostring(error and (error.user_message or error.code) or "unknown"), enabled = false },
        }
        if self.reader then
            items[#items + 1] = { text = "重试", callback = function()
                return call_action(function() return self.reader:retry() end)
            end }
            items[#items + 1] = { text = "退出阅读", callback = function()
                return call_action(function() return self.reader:close("back") end)
            end }
        end
        self.error_widget = self.menu:new{ title = "漫画请求失败", item_table = items }
        manager:show(self.error_widget)
        return true
    end
    return false
end

function Adapter:close_fullscreen()
    local manager = self.ui_manager
    self:close_license_overlay()
    self:_cancel_covers()
    if manager and manager.close then
        if self.input_dialog then self:_close_input_dialog(self.input_dialog) end
        if self.source_picker then manager:close(self.source_picker) end
        if self.filter_picker then manager:close(self.filter_picker) end
        if self.exit_confirmation_widget then manager:close(self.exit_confirmation_widget) end
        if self.error_widget then manager:close(self.error_widget) end
        if self.reader_controls and (not self.reader_widget
            or self.reader_controls ~= self.reader_widget.embedded_controls) then
            manager:close(self.reader_controls)
        end
        if self.reader_renderer then
            self.reader_renderer:close()
        elseif self.reader_widget then
            manager:close(self.reader_widget)
        end
        if self.root_renderer then self.root_renderer:close() end
    end
    self.input_dialog, self.source_picker, self.filter_picker = nil, nil, nil
    self.exit_confirmation_widget, self.error_widget, self.reader_controls = nil, nil, nil
    self.widget, self.root_widget, self.reader_widget, self.reader_renderer = nil, nil, nil, nil
    return true
end

function Adapter:close()
    return self:close_fullscreen()
end

return Adapter
