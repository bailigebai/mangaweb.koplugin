local models = require("mangaweb.models")
local CoverGrid = require("mangaweb.ui.cover_grid")

local Browse = {}
Browse.__index = Browse

function Browse:new(options)
    options = options or {}
    return setmetatable({
        source = assert(options.source, "source is required"),
        shell = assert(options.shell, "shell is required"),
        cover_grid = options.cover_grid or CoverGrid:new{},
        store = options.store,
        catalogue_cache = options.catalogue_cache or options.shell.catalogue_cache,
        view_token = options.view_token,
        request_token = 0,
        current_page = nil,
        request_handle = nil,
        categories_handle = nil,
        closed = false,
    }, self)
end

function Browse:_next_request()
    self.request_token = self.request_token + 1
    return self.request_token
end

function Browse:_is_current(request_token)
    return not self.closed and (not request_token or request_token == self.request_token)
        and (not self.view_token or type(self.shell.is_view) ~= "function"
            or self.shell:is_view(self.view_token))
end

local function cancel(handle)
    if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
end

function Browse:close()
    if self.closed then return true end
    self.closed = true
    self:_next_request()
    cancel(self.request_handle)
    cancel(self.categories_handle)
    self.request_handle, self.categories_handle = nil, nil
    return true
end

function Browse:_publish(model, request_token)
    if not self:_is_current(request_token) then return false end
    local state = self.shell:registry_state() or {}
    local meta = type(self.source.meta) == "function" and self.source:meta() or {}
    model.site = model.site or {
        id = meta.id or self.source.id,
        name = meta.name or self.source.name or self.source.id,
    }
    model.channels = model.channels or self:channels()
    model.filters = model.filters or {
        query = state.query, category = state.category, tag = state.tag,
    }
    model.navigation = model.navigation or self:_navigation()
    model.actions = model.actions or self:_actions()
    model.grid = model.grid or self.cover_grid:build({}, {})
    model.grid.columns = 4
    model.on_close = model.on_close or model.actions.close
    return self.shell:set_model(model, self.view_token)
end

local function filter_value(value)
    if type(value) == "table" then value = value.id or value.value or value.name end
    if value == nil then return nil end
    value = tostring(value)
    return value ~= "" and value or nil
end

function Browse:_options(overrides)
    local state = self.shell:registry_state() or {}
    for _, key in ipairs({ "page", "query", "category", "tag", "sort", "channel" }) do
        local value = overrides and overrides[key]
        if value ~= nil then
            state[key] = key == "page" and math.max(1, math.floor(tonumber(value) or 1)) or filter_value(value)
        end
    end
    state.page = math.max(1, math.floor(tonumber(state.page) or 1))
    return { page = state.page, query = state.query, category = state.category,
        tag = state.tag, sort = state.sort, refresh = overrides and overrides.refresh == true }
end

function Browse:_actions()
    local capabilities = type(self.source.capabilities) == "function"
        and self.source:capabilities() or {}
    local actions = {
        search = function(keyword) return self:search(keyword) end,
        categories = function(callback) return self:show_categories(callback) end,
        tags = function(query, callback) return self:show_tags(query, callback) end,
        select_category = function(category) return self:apply_category(category) end,
        select_tag = function(tag) return self:apply_tag(tag) end,
        apply_channel = function(channel_id) return self:apply_channel(channel_id) end,
        next_page = function() return self:next_page() end,
        previous_page = function() return self:previous_page() end,
        refresh = function() return self:load{refresh=true} end,
        retry = function() return self:load{refresh=true} end,
        relogin = function() return self.shell:show_settings(self.source.id) end,
        site_center = function() return self.shell:show("site_center") end,
        close = function() return self.shell:close() end,
    }
    if capabilities.search == false then actions.search = nil end
    if capabilities.categories == false or type(self.source.list_categories) ~= "function" then
        actions.categories, actions.select_category = nil, nil
    end
    if capabilities.tags == false or type(self.source.list_tags) ~= "function" then
        actions.tags, actions.select_tag = nil, nil
    end
    return actions
end

function Browse:_exclusive_filters()
    return type(self.source.capabilities) == "function"
        and (self.source:capabilities() or {}).combined_filters == false
end

local function channel_options(value)
    local result = {}
    for key, option in pairs(value or {}) do result[key] = option end
    return result
end

function Browse:channels()
    local state = self.shell:registry_state() or {}
    local source_channels = type(self.source.primary_channels) == "function"
        and self.source:primary_channels() or nil
    if type(source_channels) ~= "table" or #source_channels == 0 then
        source_channels = { { id = "home", name = "首页", options = {} } }
    end
    local categories = self.source._mangaweb_primary_categories
    if type(categories) == "table" then
        source_channels = { { id = "home", name = "首页", options = {} } }
        local seen = { home = true }
        for _, category in ipairs(categories) do
            local id = type(category) == "table" and filter_value(category.id) or nil
            if id and not seen[id] and #source_channels < 4 then
                seen[id] = true
                source_channels[#source_channels + 1] = {
                    id = id, name = category.name or id, options = { category = id },
                }
            end
        end
    end
    local active_id = filter_value(state.channel)
    if not active_id and not filter_value(state.query) and not filter_value(state.category)
        and not filter_value(state.tag) then active_id = "home" end
    local result = {}
    for _, channel in ipairs(source_channels) do
        if type(channel) == "table" and filter_value(channel.id) then
            result[#result + 1] = {
                id = tostring(channel.id),
                name = tostring(channel.name or channel.id),
                options = channel_options(channel.options),
                active = tostring(channel.id) == active_id,
            }
        end
    end
    return result
end

function Browse:_load_primary_categories()
    if self.source._mangaweb_primary_categories or self.categories_loading
        or type(self.source.list_categories) ~= "function" then return true end
    self.categories_loading = true
    local browse = self
    local handle = self.source:list_categories{
        on_success = function(items)
            browse.categories_loading = false
            browse.source._mangaweb_primary_categories = type(items) == "table" and items or {}
            if not browse:_is_current() then return false end
            local current = browse.shell:model()
            if not current or current.page ~= "browse" then return false end
            current.channels = browse:channels()
            return browse.shell:set_model(current, browse.view_token)
        end,
        on_error = function()
            browse.categories_loading = false
            return false
        end,
    }
    if not self.closed then self.categories_handle = handle end
    return handle
end

function Browse:_navigation()
    return {
        { text = "发现", active = true, callback = function() return self.shell:show("browse") end },
        { text = "收藏", callback = function() return self.shell:show("library") end },
        { text = "历史", callback = function() return self.shell:show("history") end },
        { text = "我的", callback = function() return self.shell:show("site_center") end },
    }
end

function Browse:apply_channel(channel_id)
    channel_id = tostring(channel_id or "")
    local selected
    for _, channel in ipairs(self:channels()) do
        if channel.id == channel_id then selected = channel; break end
    end
    if not selected then return false end
    local options = { page = 1, query = "", category = "", tag = "", sort = "",
        channel = selected.id }
    for key, value in pairs(selected.options or {}) do options[key] = value end
    return self:load(options)
end

function Browse:_publish_result(result, request, request_token, extra)
    if not self:_is_current(request_token) then return false end
    local cards = {}
    for _, card in ipairs(result.cards or result) do
        local value = models.card(card)
        if self.source.image_headers and value.cover_url then
            local ok, headers = pcall(self.source.image_headers, self.source, value.cover_url)
            if ok then value.cover_headers = headers end
        end
        if self.store and type(self.store.is_favorite) == "function" then
            value.favorite = self.store:is_favorite(value.site_id, value.comic_id)
        end
        local history = self.store and type(self.store.get_history) == "function"
            and self.store:get_history(value.site_id, value.comic_id) or nil
        if history then value.progress = tostring(history.page_index or 1) .. "/" .. tostring(history.total_pages or 1) end
        cards[#cards + 1] = value
    end
    local model = { page = "browse", grid = self.cover_grid:build(cards, {
        on_card = function(card) return self:open_card(card) end,
        on_tag = function(tag) return self:apply_tag(tag) end,
    }), actions = self:_actions(),
        filters = { query = request.query, category = request.category, tag = request.tag },
        state = #cards == 0 and "empty" or "ready", page_number = tonumber(result.page) or request.page,
        total_pages = tonumber(result.total_pages) or 1 }
    for key, value in pairs(extra or {}) do model[key] = value end
    self.current_page = model.page_number
    return self:_publish(model, request_token), cards
end

function Browse:load(options)
    options = options or {}
    local request_token = self:_next_request()
    cancel(self.request_handle)
    self.request_handle = nil
    local source = self.source
    if type(source.list) ~= "function" then
        self:_publish({ page = "browse", grid = self.cover_grid:build({}, {}),
            state = "empty", actions = self:_actions() }, request_token)
        return true
    end
    local request = self:_options(options)
    self.current_page = request.page
    local cache, key, snapshot = self.catalogue_cache
    if cache then
        local ok, value = pcall(cache.key, cache, source, request, "browse")
        if ok then key = value end
        if key then local got, value = pcall(cache.get, cache, key); if got then snapshot = value end end
    end
    local published
    if snapshot then
        published = self:_publish_result(snapshot, request, request_token, { refreshing = true, cached = true })
    else
        published = self:_publish({
            page = "browse",
            grid = self.cover_grid:build({}, {}),
            actions = self:_actions(),
            filters = { query = request.query, category = request.category, tag = request.tag },
            state = "loading",
            page_number = request.page,
            total_pages = 1,
        }, request_token)
    end
    if not published then return false end
    self:_load_primary_categories()
    local handle = source:list(request, {
        on_success = function(result)
            if not self:_is_current(request_token) then return false end
            local _, cards = self:_publish_result(result, request, request_token)
            if self:_is_current(request_token) and cache then
                -- Sources can merge Set-Cookie before this callback. Persist in the
                -- current session namespace so the next visit can find the snapshot.
                local ok, current_key = pcall(cache.key, cache, source, request, "browse")
                if ok and current_key then pcall(cache.put, cache, current_key, {cards=cards,
                    page=tonumber(result.page) or request.page,total_pages=tonumber(result.total_pages) or 1}) end
            end
        end,
        on_error = function(error)
            if not self:_is_current(request_token) then return false end
            if snapshot and (error or {}).code ~= "login_required" then
                return self:_publish_result(snapshot, request, request_token,
                    { cached = true, refresh_error = error })
            end
            if cache and key and (error or {}).code == "login_required" then pcall(cache.invalidate, cache, key) end
            self:_publish({ page = "browse", grid = self.cover_grid:build({}, {}),
                state = error and error.code or "network_error", error = error,
            actions = self:_actions() }, request_token)
        end,
    })
    if self:_is_current(request_token) then self.request_handle = handle end
    return handle
end

function Browse:search(keyword)
    local options = { query = tostring(keyword or ""), channel = "", page = 1 }
    if self:_exclusive_filters() then options.category, options.tag = "", "" end
    return self:load(options)
end

function Browse:apply_tag(tag)
    local options = { tag = filter_value(tag) or "", channel = "", page = 1 }
    if self:_exclusive_filters() then options.query, options.category = "", "" end
    return self:load(options)
end

function Browse:apply_category(category)
    local options = { category = filter_value(category) or "", channel = "", page = 1 }
    if self:_exclusive_filters() then options.query, options.tag = "", "" end
    return self:load(options)
end

local function choices(loader, callback, is_current)
    if type(loader) ~= "function" then callback({ { id = "", name = "全部" } }); return true end
    return loader({
        on_success = function(items)
            if not is_current() then return false end
            local result = { { id = "", name = "全部" } }
            for _, item in ipairs(items or {}) do result[#result + 1] = item end
            return callback(result)
        end,
        on_error = function(error)
            if not is_current() then return false end
            return callback({}, models.error(error))
        end,
    })
end

function Browse:show_categories(callback)
    -- Loading the picker must not invalidate the manga list request already
    -- visible underneath it. A later search/filter still advances the token
    -- through load(), so stale picker results remain safely ignored then.
    local request_token = self.request_token
    return choices(self.source.list_categories and function(callbacks)
        return self.source:list_categories(callbacks)
    end, callback or function() end, function() return self:_is_current(request_token) end)
end

function Browse:show_tags(query, callback)
    if type(query) == "function" then callback, query = query, "" end
    query = tostring(query or "")
    local request_token = self.request_token
    return choices(self.source.list_tags and function(callbacks)
        return self.source:list_tags(query, callbacks)
    end, callback or function() end, function() return self:_is_current(request_token) end)
end

function Browse:next_page()
    local state = self.shell:registry_state() or {}
    return self:load{ page = (tonumber(self.current_page) or tonumber(state.page) or 1) + 1 }
end

function Browse:previous_page()
    local state = self.shell:registry_state() or {}
    return self:load{ page = math.max(1, (tonumber(self.current_page) or tonumber(state.page) or 1) - 1) }
end

function Browse:open_card(card)
    return self.shell:show_detail(card)
end

return Browse
