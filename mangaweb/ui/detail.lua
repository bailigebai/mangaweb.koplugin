local Models = require("mangaweb.models")

local Detail = {}
Detail.__index = Detail
local PREVIEW_PAGE_SIZE = 4

local function nonempty_pages(values)
    local pages = {}
    for _, page in ipairs(values or {}) do
        if page and page.url and page.url ~= "" then pages[#pages + 1] = page end
    end
    return pages
end

local function preview_page_count(count)
    return math.max(1, math.ceil(math.max(0, tonumber(count) or 0) / PREVIEW_PAGE_SIZE))
end

function Detail:new(options)
    options = options or {}
    return setmetatable({ source = options.source, store = options.store, shell = options.shell,
        view_token = options.view_token, request_token = 0, pages_requests = {}, closed = false,
        scheduler = options.scheduler, logger = options.logger,
        cache = options.cache or (options.shell and options.shell.detail_cache),
        pages_timeout = tonumber(options.pages_timeout) or 25 }, self)
end

local function value_length(value)
    return value == nil and 0 or #tostring(value)
end

function Detail:_log(event, chapter_id, extra)
    local logger = self.logger or (self.shell and self.shell.logger)
    if not logger then return end
    local model = {}
    if self.shell and type(self.shell.model) == "function" then
        local ok, value = pcall(self.shell.model, self.shell)
        if ok and type(value) == "table" then model = value end
    end
    local card = model.detail and model.detail.card or {}
    local values = { "MangaWeb: " .. tostring(event), "site", tostring(card.site_id or "?"),
        "comic_len", tostring(value_length(card.comic_id)),
        "chapter_len", tostring(value_length(chapter_id)) }
    if extra then
        for key, value in pairs(extra) do
            values[#values + 1], values[#values + 2] = tostring(key), tostring(value)
        end
    end
    if type(logger) == "function" then
        pcall(logger, unpack(values))
    elseif type(logger.warn) == "function" then
        pcall(logger.warn, unpack(values))
    end
end

function Detail:_schedule(delay, callback)
    local scheduler = self.scheduler
    if not scheduler and self.shell and self.shell.ui then
        scheduler = self.shell.ui.ui_manager or self.shell.ui
    end
    if not scheduler then
        local ok, value = pcall(require, "ui/uimanager")
        scheduler = ok and value or nil
    end
    if not scheduler or type(scheduler.scheduleIn) ~= "function" then return false end
    local ok, result = pcall(scheduler.scheduleIn, scheduler, delay, callback)
    return ok and result ~= false, scheduler
end

function Detail:_defer(callback)
    local scheduler = self.scheduler
    if not scheduler and self.shell and self.shell.ui then
        scheduler = self.shell.ui.ui_manager or self.shell.ui
    end
    if not scheduler then
        local ok, value = pcall(require, "ui/uimanager")
        scheduler = ok and value or nil
    end
    if not scheduler or type(scheduler.nextTick) ~= "function" then return false end
    local ok, result = pcall(scheduler.nextTick, scheduler, callback)
    return ok and result ~= false
end

function Detail:_next_request()
    self.request_token = self.request_token + 1
    return self.request_token
end

function Detail:_is_current(request_token)
    return not self.closed and (not request_token or request_token == self.request_token)
        and (not self.view_token or type(self.shell.is_view) ~= "function"
            or self.shell:is_view(self.view_token))
end

function Detail:close()
    if self.closed then return true end
    self.closed = true
    self:_next_request()
    local pending = self.pages_requests
    self.pages_requests = {}
    for _, request in pairs(pending) do
        if request and request.watchdog and request.scheduler
            and type(request.scheduler.unschedule) == "function" then
            pcall(request.scheduler.unschedule, request.scheduler, request.watchdog)
        end
        local handle = request and request.handle
        if handle and type(handle.cancel) == "function" then
            pcall(handle.cancel, handle)
        end
        if request then request.callbacks = {} end
    end
    return true
end

function Detail:_set_preview_window(model, page)
    model = model or {}
    local detail = model.detail or {}
    local card = detail.card or {}
    local pages = nonempty_pages(card.pages)
    local total = preview_page_count(#pages)
    page = math.max(1, math.min(total, math.floor(tonumber(page) or 1)))
    local first = (page - 1) * PREVIEW_PAGE_SIZE + 1
    model.preview_page = page
    model.preview_total_pages = total
    model.preview_pages = {}
    for index = first, math.min(first + PREVIEW_PAGE_SIZE - 1, #pages) do
        model.preview_pages[#model.preview_pages + 1] = pages[index]
    end
    return true
end

function Detail:_change_preview_page(delta)
    local model = self.shell:model()
    if not model or model.state == "loading_pages" then return false end
    local pages = model.detail and model.detail.card and model.detail.card.pages
    if type(pages) ~= "table" or #pages == 0 then return false end
    return self:_set_preview_window(model, (model.preview_page or 1) + (tonumber(delta) or 0))
        and self:_publish(model)
end

function Detail:_publish(model, request_token)
    if not self:_is_current(request_token) then return false end
    return self.shell:set_model(model, self.view_token)
end

function Detail:_pages_request_key(chapter_id)
    if chapter_id == nil or tostring(chapter_id) == "" then return "__default" end
    return tostring(chapter_id)
end

-- Preview enumeration and Start Reading can be triggered at the same time.
-- Keep one in-flight request per chapter and fan its result out to both
-- consumers so an older failure cannot reset the detail page after a newer
-- request has already succeeded.
function Detail:_request_pages(chapter_id, callbacks)
    callbacks = callbacks or {}
    local comic_id = (self.shell:model().detail or {}).card.comic_id
    local cache_key = self.cache and self.cache:key(self.source, comic_id, chapter_id, "pages")
    local cached = self.cache and self.cache:get(self.source, comic_id, chapter_id, "pages")
    if cached then
        self:_log("Detail:pages_request.cache_hit", chapter_id)
        if type(callbacks.on_success) == "function" then callbacks.on_success(cached) end
        return true
    end
    local key = self:_pages_request_key(chapter_id)
    local pending = self.pages_requests[key]
    if pending then
        self:_log("Detail:pages_request.reuse", chapter_id)
        pending.callbacks[#pending.callbacks + 1] = callbacks
        return pending.handle or true
    end
    pending = { callbacks = { callbacks } }
    self.pages_requests[key] = pending
    self:_log("Detail:pages_request.start", chapter_id)
    local function finish(kind, value)
        if self.pages_requests[key] ~= pending or pending.finished then return false end
        pending.finished = true
        if pending.watchdog and pending.scheduler
            and type(pending.scheduler.unschedule) == "function" then
            pcall(pending.scheduler.unschedule, pending.scheduler, pending.watchdog)
        end
        self.pages_requests[key] = nil
        local extra = { result = kind }
        if kind == "success" then
            extra.pages = type(value) == "table" and type(value.pages) == "table" and #value.pages or 0
            if cache_key and extra.pages > 0 then
                self.cache:put(self.source, comic_id, chapter_id, "pages", value, cache_key)
            end
        elseif type(value) == "table" then
            extra.code = value.code or "unknown"
            extra.status = value.status or "?"
        end
        self:_log("Detail:pages_request." .. kind, chapter_id, extra)
        local waiting = pending.callbacks
        pending.callbacks = {}
        for _, waiter in ipairs(waiting) do
            local callback = waiter and waiter["on_" .. kind]
            if type(callback) == "function" then pcall(callback, value) end
        end
        return true
    end
    local ok, handle = pcall(self.source.pages, self.source,
        (self.shell:model().detail or {}).card.comic_id, chapter_id, {
            on_success = function(result) return finish("success", result) end,
            on_error = function(error) return finish("error", error) end,
        })
    if not ok then
        finish("error", { code = "network_error" })
        return false
    end
    pending.handle = handle
    if self.pages_requests[key] == pending then
        local watchdog
        watchdog = function()
            if self.pages_requests[key] ~= pending or pending.finished then return false end
            self:_log("Detail:pages_request.timeout", chapter_id,
                { timeout = self.pages_timeout })
            local result = finish("error", Models.error({ code = "request_timeout" },
                (self.shell:model().detail or {}).card.site_id, "pages"))
            if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
            return result
        end
        local scheduled, scheduler = self:_schedule(self.pages_timeout, watchdog)
        if scheduled then
            pending.watchdog, pending.scheduler = watchdog, scheduler
        else
            self:_log("Detail:pages_request.watchdog_unavailable", chapter_id)
        end
    end
    return handle or true
end

function Detail:_load_previews(model, chapter_id, loading_published)
    if model.state == "loading_pages" then return false end
    local card = model.detail.card
    if not self.source or type(self.source.pages) ~= "function" then
        local pages = nonempty_pages(card.pages)
        if type(card.pages) == "table" and #pages == #card.pages then pages = card.pages end
        card.pages = pages
        model.preview_error = nil
        self:_set_preview_window(model, 1)
        model.preview_state = #pages > 0 and "ready" or "empty"
        return loading_published or self:_publish(model)
    end
    local request_token = self:_next_request()
    if not loading_published then
        card.pages, card.chapter_id = nil, nil
        model.preview_pages, model.preview_error, model.preview_state = {}, nil, "loading"
        if not self:_publish(model, request_token) then return false end
    end
    return self:_request_pages(chapter_id, {
        on_success = function(result)
            if not self:_is_current(request_token) then return false end
            local pages = nonempty_pages((result or {}).pages)
            card.pages, card.page_count = pages, #pages
            card.chapter_id, card.default_chapter_id = chapter_id, model.default_chapter_id
            self:_set_preview_window(model, 1)
            model.preview_state = #pages > 0 and "ready" or "empty"
            return self:_publish(model, request_token)
        end,
        on_error = function(error)
            if not self:_is_current(request_token) then return false end
            model.preview_error, model.preview_state = error, "error"
            return self:_publish(model, request_token)
        end,
    })
end

function Detail:show(card, options)
    options = options or {}
    if options.refresh and self.cache then
        self.cache:invalidate(self.source, card.comic_id, nil, "detail")
    end
    local request_token = self:_next_request()
    local function publish(detail, state, error_value)
        if not self:_is_current(request_token) then return false end
        detail = detail or { card = card }
        detail.card = detail.card or card
        for key, value in pairs(card or {}) do
            if detail.card[key] == nil or detail.card[key] == "" then detail.card[key] = value end
        end
        if self.store and type(self.store.is_favorite) == "function" then
            detail.card.favorite = self.store:is_favorite(detail.card.site_id, detail.card.comic_id)
        end
        local selected_category_id = self.store
            and type(self.store.category_for) == "function"
            and self.store:category_for(detail.card.site_id, detail.card.comic_id) or nil
        detail.chapters = detail.chapters or {}
        local first_chapter = detail.chapters[1]
        local history = self.store and type(self.store.get_history) == "function"
            and self.store:get_history(detail.card.site_id, detail.card.comic_id) or nil
        self.default_chapter_id = first_chapter and first_chapter.id or nil
        self.selected_chapter_id = self.default_chapter_id
        self.resume_page = history and history.page_index or nil
        local can_read = self.source ~= nil and type(self.source.pages) == "function"
            or type(detail.card.pages) == "table" and #detail.card.pages > 0
        local model = { page = "detail", detail = detail,
            selected_chapter_id = self.selected_chapter_id, state = state or "ready",
            default_chapter_id = self.default_chapter_id,
            resume_page = self.resume_page,
            selected_category_id = selected_category_id,
            can_read = can_read,
            tags = detail.card.tags or detail.tags or {}, chapters = detail.chapters,
            return_page = options.return_page or self.shell.return_page or "browse",
            return_options = options.return_options or self.shell.return_options,
            error = error_value, actions = {
            start_reading = function() return self:start_reading() end,
            retry = function()
                local refreshed = {}
                for key, value in pairs(options) do refreshed[key] = value end
                refreshed.refresh = true
                return self:show(card, refreshed)
            end,
            preview_retry = function()
                if self.cache then
                    self.cache:invalidate(self.source, card.comic_id, self.selected_chapter_id, "pages")
                end
                return self:_load_previews(self.shell:model(), self.selected_chapter_id)
            end,
            preview_previous_page = function() return self:_change_preview_page(-1) end,
            preview_next_page = function() return self:_change_preview_page(1) end,
            select_chapter = function(chapter) return self:select_chapter(chapter) end,
            open_tag = function(tag) return self.shell:show_tag(tag) end,
            categories = function(callback)
                local values = self.store and self.store:list_categories(detail.card.site_id) or {}
                if callback then callback(values) end
                return values
            end,
            select_category = function(category)
                return self:set_category(category)
            end,
            create_category = function(name)
                if not self.store or type(self.store.create_category) ~= "function" then return false end
                local created, reason = self.store:create_category(detail.card.site_id, name)
                if not created then return false, reason end
                return self:set_category(created)
            end,
            toggle_favorite = function() return self:toggle_favorite() end,
            back = function()
                if type(self.shell.back_from_detail) == "function" then
                    return self.shell:back_from_detail()
                end
                return self.shell:show(options.return_page or self.shell.return_page or "browse",
                    options.return_options or self.shell.return_options)
            end,
        } }
        model.on_start_error = function()
            self:_log("Detail:start_reading.callback_error", self.selected_chapter_id)
            model.state = "render_error"
            model.error = Models.error({ code = "render_error" }, detail.card.site_id, "reader")
            return self:_publish(model)
        end
        local has_pages_source = self.source and type(self.source.pages) == "function"
        if has_pages_source then
            model.preview_pages, model.preview_error, model.preview_state = {}, nil, "loading"
            model.preview_page, model.preview_total_pages = 1, 1
        else
            self:_load_previews(model, self.selected_chapter_id, true)
        end
        if not self:_publish(model, request_token) then return false end
        if state or error_value then return true end
        if options.refresh and self.cache then
            self.cache:invalidate(self.source, card.comic_id, self.selected_chapter_id, "pages")
        end
        if has_pages_source then return self:_load_previews(model, self.selected_chapter_id, true) end
        return true
    end
    if self.source and type(self.source.detail) == "function" then
        local cache_key = self.cache and self.cache:key(self.source, card.comic_id, nil, "detail")
        local cached = self.cache and self.cache:get(self.source, card.comic_id, nil, "detail")
        if cached then
            self:_log("Detail:detail_request.cache_hit")
            return publish(cached)
        end
        local completed = false
        local result = self.source:detail(card.comic_id, { on_success = function(detail)
            completed = true
            if cache_key and self:_is_current(request_token) then
                self.cache:put(self.source, card.comic_id, nil, "detail", detail, cache_key)
            end
            return publish(detail)
        end,
            on_error = function(error)
                completed = true
                return publish({ card = card }, error and error.code or "network_error", error)
            end })
        if not completed then publish({ card = card }, "loading") end
        return result
    end
    publish{ card = card }
    return true
end

function Detail:select_chapter(chapter)
    if not chapter or chapter.id == nil then return false end
    local request_token = self:_next_request()
    self.selected_chapter_id = chapter.id
    local model = self.shell:model()
    model.selected_chapter_id = chapter.id
    model.resume_page = tostring(chapter.id) == tostring(self.default_chapter_id)
        and self.resume_page or nil
    model.state = "ready"
    model.detail.card.pages, model.detail.card.chapter_id = nil, nil
    local has_pages_source = self.source and type(self.source.pages) == "function"
    model.preview_pages, model.preview_error, model.preview_state = {}, nil,
        has_pages_source and "loading" or "empty"
    model.preview_page, model.preview_total_pages = 1, 1
    if not self:_publish(model, request_token) then return false end
    if has_pages_source then return self:_load_previews(model, chapter.id, true) end
    return true
end

function Detail:toggle_favorite()
    if not self.store then return false end
    local model = self.shell:model()
    local card = model.detail.card
    local favorite = self.store:is_favorite(card.site_id, card.comic_id)
    local result
    if favorite then
        result = self.store:remove_favorite(card.site_id, card.comic_id)
    else
        result = self.store:add_favorite(card)
    end
    if result == false then return false end
    card.favorite = not favorite
    if favorite then model.selected_category_id = nil end
    self:_publish(model)
    return true
end

function Detail:set_category(category)
    if not self.store then return false end
    local model = self.shell:model()
    local card = model.detail.card
    local added = false
    if type(self.store.is_favorite) == "function"
        and not self.store:is_favorite(card.site_id, card.comic_id) then
        if type(self.store.add_favorite) ~= "function" or self.store:add_favorite(card) == false then
            return false
        end
        added = true
        card.favorite = true
    end
    local category_id = category and category.id or nil
    local result = self.store:assign_category(card.site_id, { card.comic_id }, category_id)
    if result == false then
        if added then
            self.store:remove_favorite(card.site_id, card.comic_id)
            card.favorite = false
        end
        return false
    end
    model.selected_category_id = category_id
    self:_publish(model)
    return result
end

function Detail:start_reading()
    local model = self.shell:model()
    local detail = model.detail
    local card = detail.card
    local default_chapter_id = model.default_chapter_id
    local chapter_id = self.selected_chapter_id or default_chapter_id
    self:_log("Detail:start_reading.enter", self.selected_chapter_id or model.default_chapter_id)
    local cached_pages = nonempty_pages(card.pages)
    if self.source and type(self.source.pages) == "function"
        and tostring(card.chapter_id) ~= tostring(chapter_id) then
        cached_pages = {}
    end
    local function report_open_error(reason)
        if not self:_is_current() or self.shell:model() ~= model then return false end
        local code = reason == "pages_empty" and "parse_error" or "render_error"
        self:_log("Detail:reader_open.failed", chapter_id, { code = code })
        model.state = code
        model.error = Models.error({ code = code }, card.site_id, "reader")
        return self:_publish(model)
    end
    local function load_pages(callbacks)
        callbacks = callbacks or {}
        local current_pages = nonempty_pages(card.pages)
        if #current_pages > 0 and (not self.source or type(self.source.pages) ~= "function"
            or tostring(card.chapter_id) == tostring(chapter_id)) then
            if type(callbacks.on_success) == "function" then
                return callbacks.on_success{ pages = current_pages }
            end
            return true
        end
        if not self.source or type(self.source.pages) ~= "function" then
            if type(callbacks.on_error) == "function" then
                return callbacks.on_error(Models.error({ code = "parse_error" }, card.site_id, "pages"))
            end
            return false
        end
        return self:_request_pages(chapter_id, {
        on_success = function(result)
            card.pages = nonempty_pages((result or {}).pages)
            card.page_count = #card.pages
            card.chapter_id = chapter_id
            card.default_chapter_id = default_chapter_id
            if #card.pages == 0 then
                if type(callbacks.on_error) == "function" then
                    return callbacks.on_error(Models.error({ code = "parse_error" }, card.site_id, "pages"))
                end
                return false
            end
            if type(callbacks.on_success) == "function" then
                return callbacks.on_success{ pages = card.pages }
            end
            return true
        end,
        on_error = function(error)
            if type(callbacks.on_error) == "function" then return callbacks.on_error(error) end
            return false
        end,
        })
    end
    self:_log("Detail:reader_open.start", chapter_id)
    local ok, opened, reason = pcall(self.shell.start_reading, self.shell, card, {
        chapter_id = chapter_id,
        default_chapter_id = default_chapter_id,
        page_index = model.resume_page,
        pages = cached_pages,
        load_pages = load_pages,
        on_open_error = report_open_error,
    })
    if not ok then opened, reason = false, "reader_error" end
    self:_log("Detail:reader_open.result", chapter_id,
        { opened = opened == true and reason ~= "activation_pending",
            pending = reason == "activation_pending", reason = reason or "" })
    if opened then return opened end
    report_open_error(reason)
    return false
end

return Detail
