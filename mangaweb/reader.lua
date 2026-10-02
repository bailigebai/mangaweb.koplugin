local Models = require("mangaweb.models")
local PageProcessor = require("mangaweb.page_processor")
local PageSequence = require("mangaweb.page_sequence")

local Reader = {}
Reader.__index = Reader

local DEFAULT_SETTINGS = {
    preload_pages = 3, direction = "ltr", fit_mode = "page", split_enabled = false,
    split_min_ratio = 1.20, split_max_ratio = 2.20, split_cut_percent = 50,
    split_first_segment = "auto", gray_enabled = false, gray_preset = "original",
    tone_enabled = false, tone_preset = "original",
}

local function clamp(value, minimum, maximum)
    value = math.floor(tonumber(value) or minimum)
    return math.max(minimum, math.min(maximum, value))
end

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function readable_pages(values)
    local pages = {}
    for _, page in ipairs(values or {}) do
        if type(page) == "table" and page.url and page.url ~= "" then
            pages[#pages + 1] = page
        end
    end
    return pages
end

function Reader:new(options)
    options = options or {}
    return setmetatable({
        store = assert(options.store, "store is required"),
        ui = assert(options.ui, "ui is required"),
        loader = options.loader,
        page_cache = options.page_cache or (options.loader and options.loader.page_cache),
        settings = options.settings,
        logger = options.logger,
        scheduler = options.scheduler or (options.ui and (options.ui.ui_manager or options.ui)),
        timeout_seconds = tonumber(options.timeout_seconds) or 25,
        page_sequence = options.page_sequence or PageSequence,
        generation = 0,
        processing_epoch = 0,
        closed = true,
        entries = {},
        watchdogs = {},
        page_metadata = {},
        reader_settings = options.settings and options.settings:reader_settings() or copy(DEFAULT_SETTINGS),
    }, self)
end

function Reader:_log(stage, event, index, code)
    local logger = self.logger
    if not logger or type(logger.warn) ~= "function" then return end
    local site = tostring((self.context or {}).site_id or "?")
    if #site > 32 or not site:match("^[%w_%-]+$") then site = "?" end
    local safe_code = tostring(code or "-")
    if #safe_code > 32 or not safe_code:match("^[%w_%-]+$") then safe_code = "?" end
    pcall(logger.warn, "MangaWeb Reader", tostring(stage), tostring(event),
        "site", site, "page", tonumber(index) or 0,
        "total", #(self.context and self.context.pages or {}), "code", safe_code)
end

function Reader:_configure_cache()
    if not self.page_cache or type(self.page_cache.configure) ~= "function" then return end
    local upper = tonumber(self.reader_settings.cache_upper_mb)
    local lower = tonumber(self.reader_settings.cache_lower_mb)
    if upper and lower then
        pcall(self.page_cache.configure, self.page_cache, upper * 1048576, lower * 1048576)
    end
end

function Reader:_cancel_watchdog(stage)
    if stage then
        local watchdog = self.watchdogs[stage]
        if not watchdog then return end
        watchdog.active = false
        if self.scheduler and type(self.scheduler.unschedule) == "function" then
            pcall(self.scheduler.unschedule, self.scheduler, watchdog.callback)
        end
        self.watchdogs[stage] = nil
        return
    end
    local stages = {}
    for name in pairs(self.watchdogs) do stages[#stages + 1] = name end
    for _, name in ipairs(stages) do self:_cancel_watchdog(name) end
end

function Reader:_arm_watchdog(stage, generation, callback)
    self:_cancel_watchdog(stage)
    if not self.scheduler or type(self.scheduler.scheduleIn) ~= "function" then return nil end
    local watchdog = { active = true }
    watchdog.callback = function()
        if not watchdog.active or self.closed or generation ~= self.generation then return false end
        watchdog.active = false
        if self.watchdogs[stage] == watchdog then self.watchdogs[stage] = nil end
        return callback()
    end
    local ok, scheduled = pcall(self.scheduler.scheduleIn, self.scheduler,
        self.timeout_seconds, watchdog.callback)
    if not ok or scheduled == false then return nil end
    self.watchdogs[stage] = watchdog
    return watchdog
end

function Reader:_uses_history(context)
    context = context or self.context or {}
    return not context.default_chapter_id or not context.chapter_id
        or tostring(context.chapter_id) == tostring(context.default_chapter_id)
end

function Reader:_save_history()
    if not self:_uses_history() then return true end
    local context = self.context
    return self.store:save_history{
        site_id = context.site_id, comic_id = context.comic_id, title = context.title,
        author = context.author, cover_url = context.cover_url, detail_url = context.detail_url,
        page_index = self.position, total_pages = #context.pages,
    }
end

function Reader:_show_error(value, stage)
    if self.ui.show_error then
        local error_stage = stage or (type(value) == "table" and value.stage) or "image"
        self.ui:show_error(Models.error(value, (self.context or {}).site_id, error_stage))
    end
end

function Reader:_profile(page, metadata)
    if page.profile then return page.profile end
    local width = tonumber((metadata or {}).width or page.width)
    local height = tonumber((metadata or {}).height or page.height)
    if not width or not height then return nil end
    return PageProcessor.profile({ width = width, height = height }, self.reader_settings,
        self.ui.content_width or 600, self.ui.content_height or 800)
end

function Reader:_display(entry, wanted_segment)
    local page = self.context.pages[entry.index] or {}
    local metadata = entry.metadata or {}
    local width = tonumber(metadata.width or page.width) or 1
    local height = tonumber(metadata.height or page.height) or 1
    local segments = self.page_sequence.segments(width, height, self.reader_settings)
    local segment = wanted_segment
    local found = false
    for _, value in ipairs(segments) do if value == segment then found = true end end
    if not found then segment = segments[1] end
    local options = {
        segment = segment, pan_y = 0, fit_mode = self.reader_settings.fit_mode,
        split_cut_percent = self.reader_settings.split_cut_percent,
        direction = self.reader_settings.direction,
        processing_error = metadata.processing_error,
    }
    if self.ui.show_page and self.ui:show_page(entry.path, entry.index, #self.context.pages, options) == false then
        self:_show_error{ code = "image_display_error" }
        return false, "image_display_error"
    end
    self:_log("image", "displayed", entry.index)
    self.position = entry.index
    self.position_detail = { index = entry.index, segment = segment, pan_y = 0 }
    self.current_path = entry.path
    if self:_uses_history() then self.context.page_index = entry.index end
    self:_save_history()
    self.target = entry.index
    if self.page_cache and type(self.page_cache.set_position) == "function" then
        pcall(self.page_cache.set_position, self.page_cache, {
            site_id = self.context.site_id, comic_id = self.context.comic_id,
            chapter_id = self.context.chapter_id or self.context.default_chapter_id,
            index = entry.index, url = page.url,
        })
    end
    self:_prefetch_after(entry.index)
    return true
end

function Reader:_request(index, wanted_segment, is_prefetch, force, loading_shown)
    local page = self.context.pages[index]
    if not page then return false, "page_out_of_range" end
    if not is_prefetch then
        self.target = index
        self.target_segment = wanted_segment
        self:_cancel_watchdog("image")
    end
    local entry = self.entries[index]
    if entry and entry.ready and not force then
        if is_prefetch then return true end
        local shown, reason = self:_display(entry, wanted_segment or entry.segment)
        if shown == false then self:_reject_entry(index, entry) end
        return shown, reason
    end
    if force and entry then self:_cancel_entry(entry) end
    if self.ui.show_page_loading and not is_prefetch and not loading_shown then
        self.ui:show_page_loading(index, #self.context.pages)
    end
    local request_generation = self.generation
    local function watch_image(active_entry)
        if self.target ~= index then return end
        self:_arm_watchdog("image", request_generation, function()
            if self.entries[index] ~= active_entry or self.target ~= index then return false end
            self:_log("image", "timeout", index, "request_timeout")
            self:_reject_entry(index, active_entry)
            self:_show_error({ code = "request_timeout" }, "image")
            return false
        end)
    end
    if entry and entry.handle and not force then
        watch_image(entry)
        return true
    end
    local key = tostring(index) .. ":" .. tostring(self.processing_epoch)
    local metadata = self.page_metadata[index] or page.metadata or {}
    entry = { index = index, key = key, segment = wanted_segment,
        source_metadata = { width = tonumber(metadata.width), height = tonumber(metadata.height) } }
    self.entries[index] = entry
    local function ready(result)
        if self.closed or request_generation ~= self.generation
            or self.entries[index] ~= entry then return false end
        if self.target == index then self:_cancel_watchdog("image") end
        entry.path, entry.metadata, entry.ready = result.path, result.metadata or {}, true
        if self.target == index then self:_log("image", "ready", index) end
        if entry.source_metadata.width and entry.source_metadata.height then
            self.page_metadata[index] = entry.source_metadata
        else
            self.page_metadata[index] = entry.metadata
        end
        if self.target == index then
            local shown = self:_display(entry, entry.segment)
            if shown == false then self:_reject_entry(index, entry) end
        end
        self:_evict()
        return true
    end
    local function failed(error_value)
        if not self.closed and request_generation == self.generation
            and self.entries[index] == entry and self.target == index then
            self:_cancel_watchdog("image")
            self:_log("image", "error", index,
                type(error_value) == "table" and error_value.code or "image_error")
            self:_show_error(error_value)
        end
    end
    if not is_prefetch then
        self:_log("image", "start", index)
    end
    if self.loader then
        local function progress(bytes, total)
            if self.closed or request_generation ~= self.generation
                or self.target ~= index or self.entries[index] ~= entry then return end
            local amount = tonumber(bytes)
            if amount and amount > (entry.progress_bytes or 0) then
                entry.progress_bytes = amount
                watch_image(entry)
            end
            if type(self.ui.show_download_progress) == "function" then
                pcall(self.ui.show_download_progress, self.ui, bytes, total)
            end
        end
        watch_image(entry)
        entry.handle = self.loader:request(self.loader_generation, {
            key = key, index = index, url = page.url, headers = page.headers,
            site_id = self.context.site_id, stage = "image", priority = is_prefetch and 4 or 1,
            width = entry.source_metadata.width, height = entry.source_metadata.height,
            profile = self:_profile(page, entry.source_metadata),
            cache_identity = { site_id = self.context.site_id,
                comic_id = self.context.comic_id,
                chapter_id = self.context.chapter_id or self.context.default_chapter_id,
                index = index, url = page.url },
        }, { on_ready = ready, on_error = failed, on_progress = progress })
        return true
    end
    self:_show_error({ code = "http_unavailable" }, "image")
    return false, "loader_unavailable"
end

function Reader:_prefetch_after(index)
    local preload = math.max(0, math.min(10, tonumber(self.reader_settings.preload_pages) or 0))
    for next_index = index + 1, math.min(#self.context.pages, index + preload) do
        self:_request(next_index, nil, true)
    end
end

function Reader:_cancel_entry(entry, preserve_raw)
    if not entry then return end
    if preserve_raw and self.loader and self.loader.cancel_processing and entry.key then
        self.loader:cancel_processing(self.loader_generation, entry.key)
    elseif entry.handle and entry.handle.cancel then
        entry.handle:cancel()
    end
end

function Reader:_reject_entry(index, entry)
    if self.entries[index] == entry then self.entries[index] = nil end
    self:_cancel_entry(entry, false)
    if self.loader and self.loader.release then
        self.loader:release(self.loader_generation, entry.key)
    end
end

function Reader:_evict()
    if not self.position then return end
    local low = math.max(1, self.position - 1)
    local high = math.min(#self.context.pages,
        self.position + (tonumber(self.reader_settings.preload_pages) or 0))
    local stale = {}
    for index in pairs(self.entries) do
        if index ~= self.target and (index < low or index > high) then stale[#stale + 1] = index end
    end
    for _, index in ipairs(stale) do
        local entry = self.entries[index]
        self:_cancel_entry(entry, false)
        if self.loader and self.loader.release then
            self.loader:release(self.loader_generation, entry.key)
        end
        self.entries[index] = nil
    end
end

function Reader:open(context)
    assert(context and context.site_id and context.comic_id, "reader context is required")
    self:close("replace")
    self.generation = self.generation + 1
    context.pages = readable_pages(context.pages)
    self.context, self.closed, self.entries = context, false, {}
    self.page_metadata = {}
    self.position, self.position_detail, self.current_path = nil, nil, nil
    self.target, self.target_segment = nil, nil
    if self.settings then self.reader_settings = self.settings:reader_settings() end
    self:_configure_cache()
    if self.loader then self.loader_generation = self.loader:begin_session("reader") end
    if self.ui.show_page_loading and self.ui:show_page_loading(1, #context.pages) == false then
        return false, "reader_unavailable"
    end
    local request_generation = self.generation
    local function start_pages(values)
        if self.closed or request_generation ~= self.generation then return false end
        context.pages = readable_pages(values)
        self:_log("pages", "ready", 0)
        if #context.pages == 0 then
            self:_show_error({ code = "parse_error" }, "pages")
            return false, "pages_empty"
        end
        local history = self:_uses_history(context) and self.store.get_history
            and self.store:get_history(context.site_id, context.comic_id) or nil
        local wanted = history and history.page_index or (self:_uses_history(context) and context.page_index or 1)
        wanted = clamp(wanted, 1, #context.pages)
        return self:_request(wanted, nil, false, false, true)
    end
    local function request_first_page()
        if #context.pages > 0 then return start_pages(context.pages) end
        if type(context.load_pages) ~= "function" then return start_pages({}) end
        self:_log("pages", "start", 0)
        local completed = false
        self:_arm_watchdog("pages", request_generation, function()
            completed = true
            self:_log("pages", "timeout", 0, "request_timeout")
            self:_show_error({ code = "request_timeout" }, "pages")
            return false
        end)
        local ok, result = pcall(context.load_pages, {
            on_success = function(value)
                if completed then return false end
                completed = true
                self:_cancel_watchdog("pages")
                return start_pages(type(value) == "table" and value.pages or value)
            end,
            on_error = function(error_value)
                if completed or self.closed or request_generation ~= self.generation then return false end
                completed = true
                self:_cancel_watchdog("pages")
                self:_log("pages", "error", 0,
                    type(error_value) == "table" and error_value.code or "parse_error")
                self:_show_error(error_value or { code = "parse_error" }, "pages")
                return false
            end,
        })
        if not ok then
            completed = true
            self:_cancel_watchdog("pages")
            self:_show_error({ code = "parse_error" }, "pages")
            return false, "pages_error"
        end
        if result == false and not completed then
            completed = true
            self:_cancel_watchdog("pages")
            self:_show_error({ code = "transport_error" }, "pages")
            return false, "pages_error"
        end
        return result ~= false
    end
    self.resolve_pages = request_first_page
    if type(self.ui.defer) == "function" then
        local ok, deferred = pcall(self.ui.defer, self.ui, request_first_page)
        if ok and deferred == true then return true end
    end
    return request_first_page()
end

function Reader:_move(direction)
    if self.closed then return false, "reader_closed" end
    local position = self.position_detail or { index = self.position or 1, segment = "whole", pan_y = 0 }
    local entry = self.entries[position.index]
    if self.reader_settings.fit_mode == "width" and entry and entry.ready then
        local viewport = self.ui.viewport_height or 600
        local pan_y = self.page_sequence.pan(position.pan_y, (entry.metadata or {}).height,
            viewport, direction > 0)
        if pan_y ~= nil then
            position.pan_y = pan_y
            self.position_detail = position
            if self.ui.show_page then
                return self.ui:show_page(entry.path, entry.index, #self.context.pages, {
                    segment = position.segment, pan_y = pan_y, fit_mode = "width",
                    split_cut_percent = self.reader_settings.split_cut_percent,
                    direction = self.reader_settings.direction,
                    processing_error = (entry.metadata or {}).processing_error,
                })
            end
            return true
        end
    end
    local width = entry and entry.metadata and entry.metadata.width
    local height = entry and entry.metadata and entry.metadata.height
    local segments = self.page_sequence.segments(width, height, self.reader_settings)
    local next_position = direction > 0
        and self.page_sequence.next(position, segments, #self.context.pages)
        or self.page_sequence.previous(position, segments, #self.context.pages)
    if not next_position then return true end
    if next_position.index == position.index and entry and entry.ready then
        return self:_display(entry, next_position.segment)
    end
    return self:_request(next_position.index, next_position.segment)
end

function Reader:next() return self:_move(1) end
function Reader:previous() return self:_move(-1) end

function Reader:go_to(index)
    if self.closed then return false, "reader_closed" end
    return self:_request(clamp(index, 1, #self.context.pages))
end

function Reader:retry()
    if self.closed then return false, "reader_closed" end
    if #self.context.pages == 0 and self.resolve_pages then
        if self.ui.show_page_loading then self.ui:show_page_loading(1, 0) end
        return self.resolve_pages()
    end
    local index = self.target or self.position or 1
    local segment = self.target_segment or (self.position_detail and self.position_detail.segment)
    self.generation = self.generation + 1
    for _, entry in pairs(self.entries) do
        self:_cancel_entry(entry, false)
        if self.loader and self.loader.release then
            self.loader:release(self.loader_generation, entry.key)
        end
    end
    self.entries = {}
    return self:_request(index, segment)
end

function Reader:current_page() return self.position end

function Reader:update_settings(changes)
    if not self.settings then return false, "settings_unavailable" end
    local values = self.settings:reader_settings()
    for key, value in pairs(changes or {}) do if values[key] ~= nil then values[key] = value end end
    local saved, reason = self.settings:save_reader_settings(values)
    if not saved then return false, reason end
    self.reader_settings = self.settings:reader_settings()
    self:_configure_cache()
    local cache_only = true
    for key in pairs(changes or {}) do
        if key ~= "cache_upper_mb" and key ~= "cache_lower_mb" then cache_only = false end
    end
    if cache_only then return true end
    if self.closed then return true end
    self.processing_epoch = self.processing_epoch + 1
    self.generation = self.generation + 1
    local index = self.target or self.position or 1
    local preload = math.max(0, math.min(10, tonumber(self.reader_settings.preload_pages) or 0))
    local keep_high = math.min(#self.context.pages, index + preload)
    local keep_urls, preserve = {}, {}
    if self.loader then
        for next_index = index, keep_high do
            local page = self.context.pages[next_index]
            local url = page and page.url
            if url then keep_urls[url] = (keep_urls[url] or 0) + 1 end
        end
        for entry_index in pairs(self.entries) do
            if entry_index >= index and entry_index <= keep_high then
                local page = self.context.pages[entry_index]
                local url = page and page.url
                if url and (keep_urls[url] or 0) > 0 then
                    preserve[entry_index], keep_urls[url] = true, keep_urls[url] - 1
                end
            end
        end
        for entry_index in pairs(self.entries) do
            if not preserve[entry_index] then
                local page = self.context.pages[entry_index]
                local url = page and page.url
                if url and (keep_urls[url] or 0) > 0 then
                    preserve[entry_index], keep_urls[url] = true, keep_urls[url] - 1
                end
            end
        end
    end
    for entry_index, entry in pairs(self.entries) do
        local keep_raw = preserve[entry_index] == true
        self:_cancel_entry(entry, keep_raw)
        if not keep_raw then
            if self.loader and self.loader.release then
                self.loader:release(self.loader_generation, entry.key)
            end
        end
    end
    self.entries = {}
    self.position_detail = { index = index, segment = "whole", pan_y = 0 }
    return self:_request(index)
end

function Reader:settings_snapshot() return copy(self.reader_settings) end

function Reader:close(reason)
    if self.closed then return true end
    self.closed = true
    self.generation = self.generation + 1
    self:_cancel_watchdog()
    if self.loader and self.loader.cancel_generation and self.loader_generation then
        self.loader:cancel_generation(self.loader_generation)
    end
    self.entries, self.context, self.current_path, self.position = {}, nil, nil, nil
    self.resolve_pages = nil
    self.position_detail, self.target = nil, nil
    if self.ui.close_reader then self.ui:close_reader(reason)
    elseif self.ui.close then self.ui:close() end
    return true
end

return Reader
