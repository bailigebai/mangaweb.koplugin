local NativeDetail = {}
NativeDetail.__index = NativeDetail
local ButtonStyle = require("mangaweb.ui.button_style")

local function action(callback, ...)
    if type(callback) ~= "function" then return true end
    local ok, result = pcall(callback, ...)
    if not ok or result == nil or result == false then return true end
    return result
end

local function item_text(value)
    if type(value) == "table" then return tostring(value.name or value.title or value.id or "") end
    return tostring(value or "")
end

local function short_label(value, limit)
    local label, offset, count = tostring(value or ""), 1, 0
    while offset <= #label and count < limit do
        local lead = label:byte(offset)
        local width = lead < 128 and 1 or lead < 224 and 2 or lead < 240 and 3 or 4
        offset, count = offset + width, count + 1
    end
    if offset <= #label then return label:sub(1, offset - 1) .. "…" end
    return label
end

local function detail_identity(value)
    local current = ((value or {}).detail or {}).card or {}
    local stable_id = current.comic_id or current.id or current.url or current.detail_url
        or current.title or ""
    return tostring(current.site_id or "") .. "\0" .. tostring(stable_id)
end

local function desired_cover_url(value)
    local current = ((value or {}).detail or {}).card or {}
    if current.cover_url and current.cover_url ~= "" then return current.cover_url end
    local first = ((value or {}).preview_pages or {})[1]
    return first and first.url or nil
end

function NativeDetail:new(deps)
    return setmetatable({ deps = deps or {} }, self)
end

function NativeDetail:ready()
    local d = self.deps
    return d.input_container and d.button and d.frame_container and d.center_container
        and d.horizontal_group and d.vertical_group and d.image_widget and d.rect_span
        and d.geom and d.screen and d.title_bar and d.scrollable_container
        and d.text_box_widget and d.font and d.blitbuffer
end

function NativeDetail:show(model)
    if not self:ready() then return nil end
    model = model or {}
    local d, owner = self.deps, self
    local Button = ButtonStyle.extend(d.button, d.screen, d.blitbuffer)
    local face_ok, body_face = pcall(d.font.getFace, d.font, "cfont", 18)
    if not face_ok or not body_face then return nil end
    local detail, card, tags, chapters
    local function use_model(next_model)
        model = next_model or {}
        detail = model.detail or {}
        card = detail.card or {}
        tags = model.tags or card.tags or detail.tags or {}
        chapters = model.chapters or detail.chapters or {}
    end
    use_model(model)
    local InputContainer = d.input_container
    local DetailWidget = InputContainer:extend{
        modal = false, fullscreen = true, covers_fullscreen = true,
    }

    function DetailWidget:_cover_widget(buffer)
        local content
        if buffer then
            self.buffer = buffer
            content = d.image_widget:new{ image = buffer, image_disposable = false,
                width = self.cover_w, height = self.cover_h, scale_factor = 0 }
        else
            content = d.rect_span:new{ width = self.cover_w, height = self.cover_h }
        end
        return d.frame_container:new{ width = self.cover_w, height = self.cover_h,
            margin = 0, padding = 0,
            d.center_container:new{
                dimen = d.geom:new{ w = self.cover_w, h = self.cover_h }, content,
            },
        }
    end

    function DetailWidget:_title()
        return d.title_bar:new{
            title = model.title or "漫画详情", width = self.screen_w,
            with_bottom_line = true, left_icon = "chevron.left",
            left_icon_allow_flash = false,
            left_icon_tap_callback = function() return action((model.actions or {}).back) end,
            right_icon = model.on_close and "close" or nil,
            right_icon_allow_flash = false,
            right_icon_tap_callback = function() return action(model.on_close) end,
        }
    end

    function DetailWidget:_text(text, size, width)
        local ok, face = pcall(d.font.getFace, d.font, "cfont", size or 18)
        if not ok or not face then face = body_face end
        return d.text_box_widget:new{
            text = tostring(text or ""), face = face, width = width or self.content_w,
        }
    end

    function DetailWidget:_button_rows(values, format, callback)
        local rows = d.vertical_group:new{}
        local row, used
        for _, item in ipairs(values or {}) do
            local current = item
            local text = format(current)
            local width = math.min(self.content_w, math.max(100, #text * 10 + 36))
            if not row or used + width > self.content_w then
                row, used = d.horizontal_group:new{}, 0
                rows[#rows + 1] = row
            end
            row[#row + 1] = Button:new{
                text = text, width = width,
                bordersize = d.screen.scaleBySize and d.screen:scaleBySize(1) or 1,
                radius = 0, padding_h = 4, padding_v = 2, text_font_bold = false,
                show_parent = self,
                callback = function() return action(callback, current) end,
            }
            used = used + width
        end
        return rows
    end

    function DetailWidget:_resume_page()
        local default_chapter_id = model.default_chapter_id
            or (chapters[1] and chapters[1].id)
        local resume_page = tonumber(model.resume_page)
        if default_chapter_id and model.selected_chapter_id
            and tostring(default_chapter_id) ~= tostring(model.selected_chapter_id) then
            return nil
        end
        return resume_page
    end

    function DetailWidget:_summary_line(text, max_lines)
        local face_size = tonumber(body_face.size) or 18
        local line_height = math.max(1, math.floor(face_size * 1.3 + 0.5))
        return d.text_box_widget:new{
            text = tostring(text or ""), face = body_face, width = self.metadata_w,
            height = line_height * max_lines, height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end

    function DetailWidget:_summary_text()
        local resume_page = self:_resume_page()
        local info = {
            { tostring(card.title or "漫画"), 2 },
            { "作者: " .. tostring(card.author or "未知"), 1 },
            { "更新: " .. tostring(card.updated_at or "未知"), 1 },
            { "图片: " .. tostring(card.page_count or 0), 1 },
            { "章节: " .. tostring(model.selected_chapter_id or "默认"), 1 },
            { resume_page and "进度: 从第 " .. tostring(resume_page) .. " 页继续"
                or "状态: " .. tostring(model.state or "ready"), 1 },
        }
        local group, height = d.vertical_group:new{}, 0
        for _, row in ipairs(info) do
            local widget = self:_summary_line(row[1], row[2])
            group[#group + 1] = widget
            height = height + widget:getSize().h
        end
        return group, height
    end

    function DetailWidget:_summary()
        self.cover_slot = d.center_container:new{
            dimen = d.geom:new{ w = self.cover_w, h = self.cover_h },
            self:_cover_widget(nil),
        }
        self.cover_presentation = d.center_container:new{
            dimen = d.geom:new{ w = self.cover_w, h = self.cover_h },
            self.cover_slot,
        }
        self.summary_layout = "cover_metadata_row"
        return d.horizontal_group:new{
            self.cover_presentation,
            self.summary_text,
        }
    end

    function DetailWidget:_preview_widget(buffer)
        local content
        if buffer then
            content = d.image_widget:new{ image = buffer, image_disposable = false,
                width = self.preview_w, height = self.preview_h, scale_factor = 0 }
        else
            content = d.rect_span:new{ width = self.preview_w, height = self.preview_h }
        end
        return d.frame_container:new{ width = self.preview_w, height = self.preview_h,
            margin = 0, padding = 0,
            d.center_container:new{
                dimen = d.geom:new{ w = self.preview_w, h = self.preview_h }, content,
            },
        }
    end

    function DetailWidget:_preview_section()
        local slots = d.horizontal_group:new{}
        self.preview_slots, self.preview_buffers, self.preview_urls = {}, {}, {}
        self.preview_count = 4
        for index = 1, self.preview_count do
            local slot = d.center_container:new{
                dimen = d.geom:new{ w = self.preview_w, h = self.preview_h },
                self:_preview_widget(nil),
            }
            self.preview_slots[index] = slot
            slots[#slots + 1] = slot
        end
        local content = d.vertical_group:new{ self:_text("预览"), slots }
        local state = model.preview_state
        local status
        if state == "loading" then
            status = self:_text("预览加载中")
        elseif state == "error" then
            local error = model.preview_error or {}
            status = d.vertical_group:new{
                self:_text("预览错误: " .. tostring(error.user_message or error.code or "请求失败")),
                Button:new{ text = "重试预览", width = self.content_w,
                    enabled = model.state ~= "loading_pages", show_parent = self,
                    callback = function() return action((model.actions or {}).preview_retry) end },
            }
        elseif state == "empty" then
            status = self:_text("暂无预览")
        end
        content[#content + 1] = d.frame_container:new{ width = self.content_w, height = self.preview_status_h,
            margin = 0, padding = 0,
            d.center_container:new{
                dimen = d.geom:new{ w = self.content_w, h = self.preview_status_h },
                status or self:_text(""),
            },
        }
        local page = math.max(1, tonumber(model.preview_page) or 1)
        local total = math.max(1, tonumber(model.preview_total_pages) or 1)
        local control_width = math.max(1, math.floor(self.content_w / 3))
        content[#content + 1] = d.horizontal_group:new{
            Button:new{ text = "上一页", width = control_width,
                enabled = page > 1 and state ~= "loading" and state ~= "error",
                show_parent = self,
                callback = function() return action((model.actions or {}).preview_previous_page) end },
            self:_text(("第 %d / %d 页"):format(page, total), 16,
                self.content_w - control_width * 2),
            Button:new{ text = "下一页", width = self.content_w - control_width * 2,
                enabled = page < total and state ~= "loading" and state ~= "error",
                show_parent = self,
                callback = function() return action((model.actions or {}).preview_next_page) end },
        }
        return content
    end

    function DetailWidget:_body()
        local actions = model.actions or {}
        self.summary_group = self:_summary()
        self.preview_section = self:_preview_section()
        local content = d.vertical_group:new{ self.summary_group, self.preview_section }
        content[#content + 1] = self:_text("简介\n" .. tostring(detail.description or "暂无简介"))
        content[#content + 1] = self:_text("标签")
        if #tags == 0 then
            self.tag_rows = nil
            content[#content + 1] = self:_text("暂无标签")
        else
            self.tag_rows = self:_button_rows(tags, item_text, actions.open_tag)
            content[#content + 1] = self.tag_rows
        end
        content[#content + 1] = self:_text("章节")
        self.chapter_rows = {}
        self.chapter_grid = nil
        self.chapter_empty_label = nil
        if #chapters == 0 then
            local count = tonumber(card.page_count)
            local text = model.can_read == true and "默认章节" or "暂无章节"
            if model.can_read == true and count and count > 0 then
                text = text .. " · " .. tostring(count) .. " 页"
            end
            self.chapter_empty_label = self:_text(text)
            content[#content + 1] = self.chapter_empty_label
        else
            local columns = 6
            local width = math.floor(self.content_w / columns)
            local grid = d.vertical_group:new{}
            local row
            for index, chapter in ipairs(chapters) do
                if (index - 1) % columns == 0 then
                    row = d.horizontal_group:new{}
                    grid[#grid + 1] = row
                end
                local current = chapter
                local selected = tostring(chapter.id) == tostring(model.selected_chapter_id)
                local label = item_text(chapter)
                if label == "" then label = tostring(index) end
                local button = Button:new{
                    text = (selected and "●" or "") .. short_label(label, 4),
                    width = index % columns == 0 and self.content_w - width * (columns - 1)
                        or width,
                    height = d.screen.scaleBySize and d.screen:scaleBySize(36) or 36,
                    text_font_size = d.screen.scaleBySize and d.screen:scaleBySize(14) or 14,
                    padding_h = 1, padding_v = 1, menu_style = false,
                    bordersize = selected and 2 or 1, radius = 0,
                    preselect = false, show_parent = self,
                    callback = function() return action(actions.select_chapter, current) end,
                }
                self.chapter_rows[#self.chapter_rows + 1] = button
                row[#row + 1] = button
            end
            self.chapter_grid = grid
            content[#content + 1] = grid
        end
        if model.error or model.state and model.state ~= "ready" and model.state ~= "loading_pages" then
            local message = model.error and (model.error.user_message or model.error.code)
                or model.state or "请求失败"
            content[#content + 1] = self:_text("错误: " .. tostring(message))
            content[#content + 1] = Button:new{ text = "重试", width = self.content_w,
                show_parent = self, callback = function() return action(actions.retry) end }
        end
        return content
    end

    function DetailWidget:_footer()
        local actions = model.actions or {}
        local width = math.floor(self.screen_w / 2)
        local loading = model.state == "loading_pages"
        local failed = model.error or model.state and model.state ~= "ready"
            and model.state ~= "loading"
        local can_read = not failed and model.can_read == true
        local read_text = self:_resume_page() and "继续阅读" or "开始阅读"
        if loading then read_text = "加载中" end
        local function start_reading()
            if type(actions.start_reading) ~= "function" then return true end
            local ok, result = pcall(actions.start_reading)
            if not ok then return action(model.on_start_error) end
            if result == false then return action(model.on_start_error) end
            if result == nil then return true end
            return result
        end
        self.footer_actions = {
            function() return action(d.on_favorite, model) end,
            start_reading,
        }
        return d.horizontal_group:new{ width = self.screen_w,
            Button:new{ text = card.favorite and "已收藏" or "收藏", width = width,
                show_parent = self, callback = self.footer_actions[1] },
            Button:new{ text = read_text, width = self.screen_w - width,
                enabled = can_read and not loading, show_parent = self,
                callback = self.footer_actions[2] },
        }
    end

    function DetailWidget:init()
        local groups = d.device and d.device.input and d.device.input.group or {}
        if next(groups) then self.key_events = { Back = { { groups.Back or { "Back" } } } } end
        self.model = model
        self.screen_w = math.max(1, d.screen:getWidth())
        self.screen_h = math.max(1, d.screen:getHeight())
        self.dimen = d.screen.getSize and d.screen:getSize()
            or d.geom:new{ w = self.screen_w, h = self.screen_h }
        if d.gesture_range and type(d.gesture_range.new) == "function" then
            self.ges_events = {
                DetailTap = { d.gesture_range:new{ ges = "tap", range = self.dimen } },
            }
        end
        self.model = model
        self.page_id = model.page
        self:_rebuild()
    end

    function DetailWidget:_rebuild()
        self.title_bar, self.footer = self:_title(), self:_footer()
        local title_h, footer_h = self.title_bar:getSize().h, self.footer:getSize().h
        self.body_height = math.max(1, self.screen_h - title_h - footer_h)
        local scrollbar_width = d.scrollable_container.getScrollbarWidth
            and d.scrollable_container:getScrollbarWidth() or 0
        self.content_w = math.max(1, self.screen_w - scrollbar_width)
        self.cover_w = math.max(1, math.min(math.floor(self.content_w * 0.36),
            math.floor(self.body_height / 1.45)))
        self.cover_h = math.max(1, math.floor(self.cover_w * 1.45))
        self.metadata_w = math.max(1, self.content_w - self.cover_w)
        self.summary_text = self:_summary_text()
        self.preview_w = math.max(1, math.floor(self.content_w / 4))
        self.preview_h = math.max(1, math.floor(self.preview_w * 1.45))
        self.preview_status_h = math.max(1, math.floor(self.preview_h * 0.5))
        self.body_content = self:_body()
        self.scrollable_body = d.scrollable_container:new{
            dimen = d.geom:new{ w = self.screen_w, h = self.body_height },
            show_parent = self,
            self.body_content,
        }
        self.cropping_widget = self.scrollable_body
        self.page_group = d.frame_container:new{
            width = self.screen_w, height = self.screen_h, margin = 0, padding = 0, bordersize = 0,
            background = d.blitbuffer.COLOR_WHITE,
            d.vertical_group:new{ self.title_bar, self.scrollable_body, self.footer },
        }
        self[1] = self.page_group
    end

    function DetailWidget:update_model(next_model)
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
        local same_detail = detail_identity(model) == detail_identity(next_model)
        local next_cover_url = desired_cover_url(next_model)
        local old_cover, old_cover_url = self.buffer, self.cover_url
        local old_previews, old_preview_urls = self.preview_buffers or {}, self.preview_urls or {}
        -- ImageWidget is deliberately non-disposable. Detach decoded buffers
        -- before freeing the old layout, then install matching URLs into the
        -- rebuilt slots. Metadata/favourite/preview-state updates must not
        -- blank the page or restart image decoding.
        self.buffer, self.cover_url = nil, nil
        self.preview_buffers, self.preview_urls = {}, {}
        if self.page_group and self.page_group.free then pcall(self.page_group.free, self.page_group) end
        use_model(next_model)
        self.model = model
        self.page_id = next_page
        self.paint_failed = false
        self:_rebuild()
        local retained = {}
        if same_detail and old_cover and old_cover_url == next_cover_url then
            self:set_cover(old_cover, old_cover_url)
            retained[old_cover] = true
        end
        for index, old_buffer in pairs(old_previews) do
            local next_page = (next_model.preview_pages or {})[index]
            local next_url = next_page and next_page.url or nil
            if same_detail and old_buffer and old_preview_urls[index] == next_url
                and self:set_preview(index, old_buffer, next_url) then
                retained[old_buffer] = true
            end
        end
        local function release(buffer)
            if buffer and not retained[buffer] and type(buffer.free) == "function" then
                retained[buffer] = true
                pcall(buffer.free, buffer)
            end
        end
        release(old_cover)
        for _, old_buffer in pairs(old_previews) do release(old_buffer) end
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
            pcall(d.ui_manager.setDirty, d.ui_manager, self.show_parent or self, "ui")
        end
        if type(self.on_layout_changed) == "function" then
            pcall(self.on_layout_changed, self)
        end
        return true
    end

    function DetailWidget:set_cover(buffer, url)
        local old_buffer, old_widget = self.buffer, self.cover_slot and self.cover_slot[1]
        if not self.cover_slot then
            return false
        end
        self.cover_slot[1] = self:_cover_widget(buffer)
        self.cover_url = url
        if old_widget and old_widget.free then pcall(old_widget.free, old_widget) end
        if old_buffer and old_buffer ~= buffer and old_buffer.free then pcall(old_buffer.free, old_buffer) end
        if d.ui_manager and d.ui_manager.setDirty then
            pcall(d.ui_manager.setDirty, d.ui_manager, self.show_parent or self, "ui")
        end
        return true
    end

    function DetailWidget:free_cover()
        local buffer = self.buffer
        self.buffer, self.cover_url = nil, nil
        if buffer and buffer.free then pcall(buffer.free, buffer) end
    end

    function DetailWidget:set_preview(index, buffer, url)
        local slot = self.preview_slots and self.preview_slots[index]
        if not slot then
            return false
        end
        local old_buffer, old_widget = self.preview_buffers[index], slot[1]
        slot[1] = self:_preview_widget(buffer)
        self.preview_buffers[index] = buffer
        self.preview_urls[index] = url
        if old_widget and old_widget.free then pcall(old_widget.free, old_widget) end
        if old_buffer and old_buffer ~= buffer and old_buffer.free then pcall(old_buffer.free, old_buffer) end
        if d.ui_manager and d.ui_manager.setDirty then
            pcall(d.ui_manager.setDirty, d.ui_manager, self.show_parent or self, "ui")
        end
        return true
    end

    function DetailWidget:has_cover(url)
        return self.buffer ~= nil and self.cover_url == url
    end

    function DetailWidget:has_preview(index, url)
        return self.preview_buffers and self.preview_buffers[index] ~= nil
            and self.preview_urls and self.preview_urls[index] == url
    end

    function DetailWidget:onDetailTap(_, gesture)
        local position = gesture and gesture.pos or {}
        local x, y = tonumber(position.x), tonumber(position.y)
        local footer = self.footer
        local footer_size = footer and footer.getSize and footer:getSize() or nil
        if not x or not y or not footer_size
            or y < self.screen_h - (tonumber(footer_size.h) or 0) then
            return false
        end
        local actions = self.footer_actions or {}
        local index = x < self.screen_w / 2 and 1 or 2
        if type(actions[index]) ~= "function" then return false end
        actions[index]()
        return true
    end

    function DetailWidget:free_previews()
        for index, buffer in pairs(self.preview_buffers or {}) do
            self.preview_buffers[index] = nil
            if self.preview_urls then self.preview_urls[index] = nil end
            if buffer and buffer.free then pcall(buffer.free, buffer) end
        end
    end

    function DetailWidget:paintTo(bb, x, y)
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

    function DetailWidget:onBack()
        return action((model.actions or {}).back)
    end

    function DetailWidget:onCloseWidget()
        if self.closed then return true end
        self.closed = true
        self:free_cover()
        self:free_previews()
        self[1], self.page_group, self.body_content = nil, nil, nil
        self.scrollable_body, self.cropping_widget = nil, nil
        self.cover_slot, self.preview_slots, self.summary_text, self.summary_group = nil, nil, nil, nil
        self.preview_section, self.tag_rows, self.chapter_rows = nil, nil, nil
        self.chapter_grid, self.chapter_empty_label = nil, nil
        self.title_bar, self.footer, self.footer_actions = nil, nil, nil
        return true
    end

    function DetailWidget:onClose()
        if self.skip_close_callback then return true end
        return action((model.actions or {}).back)
    end

    local widget = DetailWidget:new{}
    self.widget = widget
    return widget
end

return NativeDetail
