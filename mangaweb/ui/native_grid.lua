local NativeGrid = {}
NativeGrid.__index = NativeGrid
local ButtonStyle = require("mangaweb.ui.button_style")

local function action(callback, ...)
    if type(callback) ~= "function" then return true end
    local ok, result = pcall(callback, ...)
    return not ok or result == nil or result == false and true or result
end

local function nonblank(value)
    if value == nil or type(value) == "string" and not value:match("%S") then return nil end
    return value
end

function NativeGrid.layout(value)
    value = value or {}
    local screen_w = math.max(1, math.floor(tonumber(value.screen_w) or 600))
    local screen_h = math.max(1, math.floor(tonumber(value.screen_h) or 800))
    local columns = math.max(2, math.floor(tonumber(value.columns) or 4))
    local rows = math.max(1, math.floor(tonumber(value.rows) or 3))
    local title_h = math.max(0, math.floor(tonumber(value.title_h) or 0))
    local toolbar_h = math.max(0, math.floor(tonumber(value.toolbar_h) or 0))
    local footer_h = math.max(0, math.floor(tonumber(value.footer_h) or 0))
    local available = math.max(1, screen_h - title_h - toolbar_h - footer_h)
    local cell_w = math.max(1, math.floor(screen_w / columns))
    local cover_w = math.max(1, cell_w - 12)
    local target_cover_h = math.max(1, math.floor(cover_w * 1.5))
    local min_name_h = math.max(1, math.floor(tonumber(value.min_name_h) or 54))
    local cell_h = math.max(1, math.floor(available / rows))
    local name_h = math.max(1, math.min(math.max(1, cell_h - 1),
        math.max(min_name_h, math.floor(cell_h * 0.12))))
    return {
        screen_w = screen_w, screen_h = screen_h, columns = columns, rows = rows,
        page_size = rows * columns, cell_w = cell_w, cell_h = cell_h,
        cover_w = cover_w, cover_h = math.max(1, math.min(target_cover_h, cell_h - name_h)),
        name_h = name_h, title_h = title_h, toolbar_h = toolbar_h, footer_h = footer_h,
    }
end

function NativeGrid.page_window(total, page, page_size)
    total = math.max(0, math.floor(tonumber(total) or 0))
    page_size = math.max(1, math.floor(tonumber(page_size) or 1))
    local pages = math.max(1, math.ceil(total / page_size))
    page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
    local first = (page - 1) * page_size + 1
    return first, math.min(total, first + page_size - 1)
end

function NativeGrid:new(deps)
    deps = deps or {}
    return setmetatable({ deps = deps }, self)
end

function NativeGrid:ready()
    local d = self.deps
    return d.input_container and d.button and d.frame_container and d.center_container
        and d.horizontal_group and d.vertical_group and d.overlap_group
        and d.image_widget and d.rect_span
        and d.geom and d.gesture_range and d.screen and d.title_bar and d.text_box_widget
        and d.font and d.blitbuffer
end

function NativeGrid:show(model)
    if not self:ready() then return nil end
    model = model or {}
    local d, owner = self.deps, self
    local InputContainer = d.input_container
    local Button = ButtonStyle.extend(d.button, d.screen, d.blitbuffer)
    local GridCell = InputContainer:extend{}

    function GridCell:_cover(buffer)
        local content
        if buffer then
            self.buffer = buffer
            content = d.image_widget:new{ image = buffer, image_disposable = false,
                width = self.cover_w, height = self.cover_h, scale_factor = 0 }
        else
            self.buffer = nil
            content = d.rect_span:new{ width = self.cover_w, height = self.cover_h }
        end
        return d.frame_container:new{ width = self.cover_w, height = self.cover_h,
            margin = 0, padding = 0,
            d.center_container:new{
                dimen = d.geom:new{ w = self.cover_w, h = self.cover_h },
                content,
            },
        }
    end

    function GridCell:_badge(text, width)
        local height = math.max(24, d.screen.scaleBySize and d.screen:scaleBySize(28) or 28)
        local face_size = math.max(14, d.screen.scaleBySize and d.screen:scaleBySize(16) or 16)
        local badge = d.frame_container:new{
            text = text, width = width, height = height,
            margin = 0, padding = 2, bordersize = 1,
            background = d.blitbuffer.COLOR_WHITE,
            d.text_box_widget:new{
                text = text, face = d.font:getFace("cfont", face_size),
                width = width, height = height, alignment = "center",
                height_adjust = true, height_overflow_show_ellipsis = true,
            },
        }
        return badge
    end

    function GridCell:_cover_layers(buffer)
        local layers = d.overlap_group:new{
            width = self.cover_w, height = self.cover_h,
            dimen = d.geom:new{ w = self.cover_w, h = self.cover_h },
            allow_mirroring = false,
            self:_cover(buffer),
        }
        if self.item.selected then
            self.selected_badge = self:_badge("✓",
                math.max(28, d.screen.scaleBySize and d.screen:scaleBySize(32) or 32))
            layers[#layers + 1] = self.selected_badge
        else
            self.selected_badge = nil
        end
        if self.item.favorite then
            self.favorite_badge = self:_badge("★",
                math.max(28, d.screen.scaleBySize and d.screen:scaleBySize(32) or 32))
            local size = self.favorite_badge:getSize()
            self.favorite_badge.overlap_offset = { math.max(0, self.cover_w - size.w), 0 }
            layers[#layers + 1] = self.favorite_badge
        else
            self.favorite_badge = nil
        end
        if nonblank(self.item.progress) then
            local text = tostring(self.item.progress)
            local width = math.min(self.cover_w,
                math.max(56, d.screen.scaleBySize and d.screen:scaleBySize(64) or 64))
            self.progress_badge = self:_badge(text, width)
            self.progress_badge.overlap_offset = {
                0, math.max(0, self.cover_h - self.progress_badge:getSize().h),
            }
            layers[#layers + 1] = self.progress_badge
        else
            self.progress_badge = nil
        end
        return layers
    end

    function GridCell:init()
        self.ges_events = { TapSelect = { d.gesture_range:new{ ges = "tap", range = self.dimen } } }
        self.cover_slot = d.center_container:new{
            dimen = d.geom:new{ w = self.cover_w, h = self.cover_h },
            self:_cover_layers(nil),
        }
        local size = d.text_box_widget.getFontSizeToFitHeight
            and d.text_box_widget:getFontSizeToFitHeight(self.name_h, 2) or 18
        self.title_widget = d.text_box_widget:new{
            text = tostring(self.item.title or "漫画"),
            face = d.font:getFace("cfont", size), width = self.cell_w, height = self.name_h,
            height_adjust = true, height_overflow_show_ellipsis = true, alignment = "center",
        }
        self[1] = d.vertical_group:new{
            self.cover_slot,
            self.title_widget,
        }
    end

    function GridCell:onTapSelect()
        return action(self.item.on_tap)
    end

    function GridCell:set_cover(buffer)
        local old_buffer, old_widget = self.buffer, self.cover_slot[1]
        self.cover_slot[1] = self:_cover_layers(buffer)
        if old_widget and old_widget.free then pcall(old_widget.free, old_widget) end
        if old_buffer and old_buffer ~= buffer and old_buffer.free then pcall(old_buffer.free, old_buffer) end
        if d.ui_manager and d.ui_manager.setDirty then
            pcall(d.ui_manager.setDirty, d.ui_manager, self, "ui")
        end
        return true
    end

    function GridCell:free_cover()
        local buffer = self.buffer
        if not buffer then return end
        local old_widget = self.cover_slot[1]
        self.cover_slot[1] = self:_cover_layers(nil)
        if old_widget and old_widget.free then pcall(old_widget.free, old_widget) end
        if buffer.free then pcall(buffer.free, buffer) end
    end

    local GridWidget = InputContainer:extend{ modal = false, fullscreen = true, covers_fullscreen = true }

    function GridWidget:_title()
        local icon_w = math.max(40, d.screen.scaleBySize and d.screen:scaleBySize(48) or 48)
        local icon_size = math.max(22, d.screen.scaleBySize and d.screen:scaleBySize(24) or 24)
        local title_w = math.max(1, self.screen_w - icon_w * 3)
        self.title_controls = {
            source = Button:new{ icon = "appbar.menu", width = icon_w, height = self.compact_h,
                icon_width = icon_size, icon_height = icon_size,
                callback = function() return action(d.on_sources, model) end },
            search = Button:new{ icon = "appbar.search", width = icon_w, height = self.compact_h,
                icon_width = icon_size, icon_height = icon_size,
                enabled = type((model.actions or {}).search) == "function",
                callback = function() return action(d.on_search, model) end },
            close = Button:new{ icon = "close", width = icon_w, height = self.compact_h,
                icon_width = icon_size, icon_height = icon_size,
                callback = function() return action(model.on_close or (model.actions or {}).close) end },
        }
        local title = nonblank(model.title) or nonblank((model.site or {}).name) or "漫画网站"
        return d.horizontal_group:new{
            self.title_controls.source,
            d.title_bar:new{ title = tostring(title),
                subtitle = model.subtitle, width = title_w, with_bottom_line = true,
                title_top_padding = 0, bottom_v_padding = 0 },
            self.title_controls.search,
            self.title_controls.close,
        }
    end

    function GridWidget:_toolbar()
        if model.show_filters == false then
            if model.tabs then
                local row = d.horizontal_group:new{}
                if model.selecting then
                    local part = math.floor(self.screen_w / 3)
                    row[#row + 1] = Button:new{ text = "取消多选", width = part,
                        height = self.compact_h,
                        callback = function() return action((model.actions or {}).cancel_selection) end }
                    row[#row + 1] = Button:new{
                        text = "已选 " .. tostring(model.selection_count or 0) .. " 本",
                        width = part, height = self.compact_h, enabled = false }
                    row[#row + 1] = Button:new{ text = "调整分类",
                        width = self.screen_w - part * 2, height = self.compact_h,
                        enabled = (model.selection_count or 0) > 0,
                        callback = function()
                            return action((model.actions or {}).choose_batch_category)
                        end }
                    self.channel_row = row
                    return row
                end
                local visible = {}
                for index = 1, math.min(#model.tabs, 3) do
                    visible[#visible + 1] = model.tabs[index]
                end
                if #model.tabs > 3 then
                    for index = 4, #model.tabs do
                        if model.tabs[index].active then visible[#visible] = model.tabs[index] end
                    end
                end
                local has_more = #model.tabs > #visible
                local count = #visible + (has_more and 1 or 0) + 2
                local part = math.floor(self.screen_w / count)
                for _, tab in ipairs(visible) do
                    local current = tab
                    row[#row + 1] = Button:new{
                        text = current.active and "[" .. tostring(current.name) .. "]"
                            or tostring(current.name),
                        width = part, height = self.compact_h,
                        enabled = not model.busy,
                        callback = function()
                            return action((model.actions or {}).select_category, current.id)
                        end }
                end
                if has_more then
                    row[#row + 1] = Button:new{ text = "更多分类", width = part,
                        height = self.compact_h,
                        callback = function() return action(d.on_collection_categories, model) end }
                end
                row[#row + 1] = Button:new{ text = model.official and "刷新" or "管理分类", width = part,
                    height = self.compact_h,
                    enabled = not model.busy,
                    callback = function()
                        return action((model.actions or {})[model.official and "refresh" or "manage_categories"])
                    end }
                row[#row + 1] = Button:new{ text = model.official and "取消收藏" or "多选",
                    width = self.screen_w - part * (count - 1), height = self.compact_h,
                    enabled = not model.busy and (not model.official or model.state == "ready" and not model.error
                        and #((model.grid or {}).cells or {}) > 0),
                    callback = function()
                        return action((model.actions or {})[model.official and "choose_official_removal" or "begin_selection"])
                    end }
                self.channel_row = row
                return row
            end
            if (model.actions or {}).categories_shelf then
                self.channel_row = d.horizontal_group:new{
                    Button:new{ text = "分类架", width = self.screen_w, height = self.compact_h,
                        callback = function() return action(model.actions.categories_shelf) end },
                }
                return self.channel_row
            end
            self.channel_row = nil
            return d.rect_span:new{ width = self.screen_w, height = 0 }
        end
        local channels = model.channels or {}
        local has_filters = type((model.actions or {}).categories) == "function"
            or type((model.actions or {}).tags) == "function"
        local count = math.max(1, #channels + (has_filters and 1 or 0))
        local width = math.floor(self.screen_w / count)
        local row = d.horizontal_group:new{}
        for _, channel in ipairs(channels) do
            local current = channel
            row[#row + 1] = Button:new{
                text = current.active and "[" .. tostring(current.name) .. "]"
                    or tostring(current.name),
                width = width, height = self.compact_h,
                callback = function()
                    return action((model.actions or {}).apply_channel, current.id)
                end,
            }
        end
        if has_filters then
            local filters = model.filters or {}
            local selected = filters.category and filters.category ~= ""
                or filters.tag and filters.tag ~= ""
            row[#row + 1] = Button:new{ text = selected and "筛选 · 已选" or "筛选",
                width = self.screen_w - width * (count - 1), height = self.compact_h,
                callback = function() return action(d.on_filters, model) end }
        end
        self.channel_row = row
        return row
    end

    function GridWidget:_footer()
        local cells = (model.grid or {}).cells or {}
        local local_pages = math.max(1, math.ceil(#cells / self.page_size))
        local remote_page = tonumber(model.page_number) or 1
        local remote_pages = tonumber(model.total_pages) or 1
        if model.show_pagination == false then remote_page, remote_pages = 1, 1 end
        local footer = d.vertical_group:new{}
        local function turn(direction)
            if direction < 0 and self.local_page > 1 then
                return self:set_page(self.local_page - 1)
            end
            if direction > 0 and self.local_page < local_pages then
                return self:set_page(self.local_page + 1)
            end
            return action((model.actions or {})[direction < 0 and "previous_page" or "next_page"])
        end
        local function pager(width)
            local part_w = math.floor(width / 3)
            local display_page, display_pages = self.local_page, local_pages
            if model.show_pagination ~= false then
                -- ponytail: project server pages at the current page density; use a two-level label if sites vary it.
                display_page = (remote_page - 1) * local_pages + self.local_page
                display_pages = remote_pages * local_pages
            end
            self.paging_row = d.horizontal_group:new{
                Button:new{ icon = "chevron.left", width = part_w, height = self.compact_h,
                    enabled = self.local_page > 1 or remote_page > 1,
                    callback = function() return turn(-1) end },
                Button:new{ text = string.format("%d/%d", display_page, display_pages),
                    width = part_w, height = self.compact_h, enabled = false },
                Button:new{ icon = "chevron.right", width = width - part_w * 2,
                    height = self.compact_h,
                    enabled = self.local_page < local_pages or remote_page < remote_pages,
                    callback = function() return turn(1) end },
            }
            return self.paging_row
        end
        local navigation = model.navigation or {}
        self.navigation_count = #navigation
        if #navigation > 0 then
            local nav = d.horizontal_group:new{}
            local nav_w = math.floor(self.screen_w / (#navigation + 1))
            for index, item in ipairs(navigation) do
                nav[#nav + 1] = Button:new{
                    text = item.active and "[" .. tostring(item.text) .. "]" or tostring(item.text),
                    width = index == #navigation and self.screen_w - nav_w * #navigation or nav_w,
                    height = self.compact_h,
                    callback = function() return action(item.callback) end,
                }
                if index == math.min(2, #navigation) then nav[#nav + 1] = pager(nav_w) end
            end
            self.navigation_row = nav
            footer[#footer + 1] = nav
        else
            self.navigation_row = nil
            if model.show_pagination ~= false or local_pages > 1 then
                footer[#footer + 1] = pager(self.screen_w)
            else
                self.paging_row = nil
            end
        end
        return footer
    end

    function GridWidget:_content()
        local rows = d.vertical_group:new{}
        local state = model.error and "error" or model.state
        self.status_text, self.status_action = nil, nil
        local function status_content(message, action_text, callback)
            local action_w = callback and math.floor(self.screen_w / 3) or 0
            local text_w = self.screen_w - action_w
            self.status_text = d.text_box_widget:new{
                text = tostring(message), face = d.font:getFace("cfont", 18),
                width = text_w, alignment = "center", height_adjust = true,
                height_overflow_show_ellipsis = true,
            }
            local state_row = d.horizontal_group:new{ self.status_text }
            if callback then
                self.status_action = Button:new{
                    text = action_text, max_width = action_w, height = self.compact_h,
                    show_parent = self,
                    callback = function() return action(callback) end,
                }
                state_row[#state_row + 1] = self.status_action
            end
            return d.center_container:new{
                dimen = d.geom:new{ w = self.screen_w, h = self.layout.cell_h },
                state_row,
            }
        end
        if state == "error" or model.error then
            local error_result, actions = model.error or {}, model.actions or {}
            local message = tostring(error_result.user_message or "请求失败，请重试")
            local login_error = error_result.code == "login_required"
                or error_result.code == "login_unverified"
                or error_result.code == "invalid_credentials"
                or error_result.code == "verification_required"
            local callback = login_error and actions.relogin or actions.retry
            rows[1] = status_content(message,
                login_error and actions.relogin and "重新登录" or "重试", callback)
        elseif state == "loading" then
            rows[1] = status_content(model.loading_message or "加载中")
        elseif state == "empty" then
            local clear = (model.actions or {}).apply_channel
            rows[1] = status_content(model.empty_message or "当前条件没有漫画", "清除筛选",
                type(clear) == "function" and function() return clear("home") end or nil)
        else
            local cells = (model.grid or {}).cells or {}
            local first, last = NativeGrid.page_window(#cells, self.local_page, self.page_size)
            local row
            for index = first, last do
                if (index - first) % self.layout.columns == 0 then
                    row = d.horizontal_group:new{ align = "center" }
                    rows[#rows + 1] = row
                end
                local cell = GridCell:new{ item = cells[index],
                    dimen = d.geom:new{ w = self.layout.cell_w, h = self.layout.cell_h },
                    cell_w = self.layout.cell_w, cover_w = self.layout.cover_w,
                    cover_h = self.layout.cover_h, name_h = self.layout.name_h }
                row[#row + 1] = cell
                self.cells[index] = cell
            end
            if row then
                while #row < self.layout.columns do
                    row[#row + 1] = d.rect_span:new{ width = self.layout.cell_w,
                        height = self.layout.cell_h }
                end
            end
        end
        while #rows < self.layout.rows do
            local empty_row = d.horizontal_group:new{ align = "center" }
            for _ = 1, self.layout.columns do
                empty_row[#empty_row + 1] = d.rect_span:new{ width = self.layout.cell_w,
                    height = self.layout.cell_h }
            end
            rows[#rows + 1] = empty_row
        end
        self.content_group = rows
        return rows
    end

    function GridWidget:init()
        local groups = d.device and d.device.input and d.device.input.group or {}
        if next(groups) then self.key_events = { Back = { { groups.Back or { "Back" } } } } end
        self.screen_w = math.max(1, d.screen:getWidth())
        self.screen_h = math.max(1, d.screen:getHeight())
        self.dimen = d.screen.getSize and d.screen:getSize()
            or d.geom:new{ w = self.screen_w, h = self.screen_h }
        self.model = model
        self.page_id = model.page
        self.local_page = 1
        self.page_size = 1
        self.compact_h = math.max(30,
            d.screen.scaleBySize and d.screen:scaleBySize(34) or 34)
        local title, toolbar, footer = self:_title(), self:_toolbar(), self:_footer()
        local title_h = title:getSize().h
        local toolbar_h = toolbar:getSize().h
        local footer_h = footer:getSize().h
        if title.free then title:free() end
        if toolbar.free then toolbar:free() end
        if footer.free then footer:free() end
        self.layout = NativeGrid.layout{ screen_w = self.screen_w, screen_h = self.screen_h,
            columns = 4, rows = 3,
            title_h = title_h, toolbar_h = toolbar_h, footer_h = footer_h,
            min_name_h = d.screen.scaleBySize and d.screen:scaleBySize(38) or 38 }
        self.cover_w, self.cover_h = self.layout.cover_w, self.layout.cover_h
        self.page_size = self.layout.page_size
        self.cells = {}
        self:_rebuild()
    end

    function GridWidget:_free_page()
        for _, cell in pairs(self.cells or {}) do cell:free_cover() end
        if self.page_group and self.page_group.free then pcall(self.page_group.free, self.page_group) end
        self.cells, self.page_group = {}, nil
    end

    function GridWidget:_rebuild()
        self:_free_page()
        local rows = self:_content()
        self.page_group = d.frame_container:new{ width = self.screen_w, height = self.screen_h,
            margin = 0, padding = 0, bordersize = 0, background = d.blitbuffer.COLOR_WHITE,
            d.vertical_group:new{ self:_title(), self:_toolbar(), rows, self:_footer() } }
        self[1] = self.page_group
    end

    function GridWidget:update_model(next_model)
        next_model = next_model or {}
        local next_page = next_model.page or self.page_id
        if self.closed or self.retired
            or self.page_id and next_page and self.page_id ~= next_page then return false end
        local retained = {}
        local next_cells = (next_model.grid or {}).cells or {}
        for index, cell in pairs(self.cells or {}) do
            local previous, current = cell.item, next_cells[index]
            if cell.buffer and current and previous
                and tostring(previous.site_id or "") == tostring(current.site_id or "")
                and tostring(previous.comic_id or "") == tostring(current.comic_id or "")
                and previous.cover_url == current.cover_url then
                retained[index] = cell.buffer
                cell.buffer = nil
            end
        end
        local previous_remote_page = tonumber(self.model and self.model.page_number)
        local next_remote_page = tonumber(next_model.page_number)
        model = next_model
        self.model = model
        self.page_id = next_page
        if self.on_render_error and not model.on_render_error then
            model.on_render_error = self.on_render_error
        end
        local cells = (model.grid or {}).cells or {}
        local pages = math.max(1, math.ceil(#cells / self.page_size))
        if previous_remote_page and next_remote_page
            and previous_remote_page ~= next_remote_page then
            self.local_page = 1
        else
            self.local_page = math.max(1, math.min(self.local_page, pages))
        end
        self.paint_failed = false
        self:_rebuild()
        for index, buffer in pairs(retained) do
            if not self.cells[index] or self.cells[index]:set_cover(buffer) == false then
                if type(buffer.free) == "function" then pcall(buffer.free, buffer) end
            end
        end
        if d.ui_manager and d.ui_manager.setDirty then
            pcall(d.ui_manager.setDirty, d.ui_manager, self, "ui")
        end
        return true
    end

    function GridWidget:set_page(page)
        local cells = (model.grid or {}).cells or {}
        local pages = math.max(1, math.ceil(#cells / self.page_size))
        self.local_page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
        self:_rebuild()
        if self.on_page_changed then action(self.on_page_changed, self) end
        if d.ui_manager and d.ui_manager.setDirty then
            pcall(d.ui_manager.setDirty, d.ui_manager, self, "ui")
        end
        return true
    end

    function GridWidget:set_cover(index, buffer)
        if not self.cells[index] then return false end
        return self.cells[index]:set_cover(buffer)
    end

    function GridWidget:has_cover(index, url)
        local cell = self.cells[index]
        return cell ~= nil and cell.buffer ~= nil and cell.item.cover_url == url
    end

    function GridWidget:free_visible_images()
        for _, cell in pairs(self.cells or {}) do cell:free_cover() end
    end

    function GridWidget:paintTo(bb, x, y)
        if self.closed or self.retired or not self[1] then return end
        local ok, err = pcall(d.input_container.paintTo, self, bb, x, y)
        if ok or self.paint_failed then return end
        self.paint_failed = true
        local function recover()
            if not self.closed and not self.retired and owner.widget == self and model.on_render_error then
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

    function GridWidget:onBack()
        return action((model.actions or {}).back or model.on_close
            or (model.actions or {}).close or (model.actions or {}).site_center)
    end

    function GridWidget:onCloseWidget()
        if self.closed then return true end
        self.closed = true
        self:_free_page()
        return true
    end

    function GridWidget:onClose()
        if self.skip_close_callback then return true end
        return self:onBack()
    end

    local widget = GridWidget:new{}
    owner.widget = widget
    return widget
end

return NativeGrid
