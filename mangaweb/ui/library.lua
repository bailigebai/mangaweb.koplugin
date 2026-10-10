local Library = {}
Library.__index = Library
Library.OFFICIAL_ID = "official:zero"

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

function Library:new(options)
    options = options or {}
    local registry = options.source_registry
    local source = registry and type(registry.current) == "function" and registry:current() or nil
    local capabilities = source and type(source.capabilities) == "function" and source:capabilities() or {}
    local official_source = source and source.id == "zero" and capabilities.official_favorites
        and type(source.favorites) == "function" and type(source.remove_favorite) == "function" and source or nil
    return setmetatable({
        source_registry = registry,
        site_id = registry:current_id(),
        official_source = official_source,
        store = options.store,
        shell = options.shell,
        view_token = options.view_token,
        category_id = options.category_id,
        selecting = false,
        selected = {},
        official_page = math.max(1, math.floor(tonumber(options.official_page) or 1)),
        remote = { items = {}, state = "loading", page = 1, total_pages = 1 },
        catalogue_cache = options.shell.catalogue_cache,
        cover_pages = {}, cover_complete = false,
        request_token = 0,
    }, self)
end

function Library:_is_current(token)
    return not self.closed and (token == nil or token == self.request_token)
        and self.site_id == self.source_registry:current_id()
        and (type(self.shell.is_view) ~= "function" or self.shell:is_view(self.view_token))
end

function Library:close()
    self.closed = true
    self.request_token = self.request_token + 1
    if self.request_handle and type(self.request_handle.cancel) == "function" then
        pcall(self.request_handle.cancel, self.request_handle)
    end
    self.request_handle = nil
    self:_cancel_cover_scan()
end

function Library:_cancel_cover_scan()
    if self.cover_scan_handle and type(self.cover_scan_handle.cancel) == "function" then
        pcall(self.cover_scan_handle.cancel, self.cover_scan_handle)
    end
    self.cover_scan_handle = nil
end

function Library:_official_cache_key(page, kind)
    local cache = self.catalogue_cache
    if not cache or not self.official_source then return nil end
    local ok, key = pcall(cache.key, cache, self.official_source, {page=page}, kind or "favorites")
    return ok and key or nil
end

function Library:_scan_cover_pages(total, token)
    if not self:_is_current(token) then return end
    local next_page
    for page = 1, total do if not self.cover_pages[page] then next_page = page; break end end
    if not next_page then
        local seen, count = {}, 0
        for page = 1, total do
            for _, card in ipairs(self.cover_pages[page]) do
                local id = tostring(card.comic_id or "")
                if id ~= "" and not seen[id] then seen[id], count = true, count + 1 end
            end
        end
        self.cover_complete = self.cover_count_consistent and count == self.remote.total_count
        return self:show()
    end
    local completed = false
    local ok, handle = pcall(self.official_source.favorites, self.official_source, {page=next_page}, {
        on_success = function(result)
            completed = true
            if not self:_is_current(token) then return false end
            self.cover_scan_handle = nil
            -- Do not certify a full snapshot when a server silently repeats or clamps a page.
            if (tonumber(result.page) or next_page) ~= next_page then return false end
            if tonumber(result.total_count) ~= self.remote.total_count then self.cover_count_consistent = false end
            self.cover_pages[next_page] = result.cards or {}
            local key = self:_official_cache_key(next_page)
            if key then pcall(self.catalogue_cache.put, self.catalogue_cache, key, result) end
            self:show()
            return self:_scan_cover_pages(math.max(1, math.floor(tonumber(result.total_pages) or total)), token)
        end,
        on_error = function()
            completed = true
            if self:_is_current(token) then self.cover_scan_handle = nil end
        end,
    })
    if ok and not completed and self:_is_current(token) then self.cover_scan_handle = handle end
end

function Library:load_official(page)
    if not self:_is_current() or not self.official_source or self.busy then return false end
    if self.request_handle and self.request_handle.cancel then pcall(self.request_handle.cancel, self.request_handle) end
    self.request_handle = nil
    self:_cancel_cover_scan()
    self.request_token = self.request_token + 1
    local token, completed = self.request_token, false
    self.started = true
    self.remote = { items = {}, state = "loading", page = page or 1, total_pages = 1 }
    self.cover_pages, self.cover_complete = {}, false
    self.cover_count_consistent = true
    local cache_key = self:_official_cache_key(page or 1)
    if cache_key then
        local got, snapshot = pcall(self.catalogue_cache.get, self.catalogue_cache, cache_key)
        if got and snapshot then
            self.remote = { items = snapshot.cards, state = #snapshot.cards == 0 and "empty" or "ready",
                page = snapshot.page, total_pages = snapshot.total_pages, total_count = snapshot.total_count, cached = true }
            self.cover_pages[page or 1] = snapshot.cards
        end
    end
    self:show()
    local function failure(err)
        completed = true
        if not self:_is_current(token) then return false end
        self.request_handle = nil
        if self.remote.cached and (err or {}).code ~= "login_required" then
            self.remote.refresh_error = err
        else
            self.remote.state, self.remote.error = "error", err
            if cache_key and (err or {}).code == "login_required" then
                pcall(self.catalogue_cache.invalidate, self.catalogue_cache, cache_key)
            end
        end
        return self:show()
    end
    local ok, handle = pcall(self.official_source.favorites, self.official_source, { page = page or 1 }, {
        on_success = function(result)
            completed = true
            if not self:_is_current(token) then return false end
            self.request_handle = nil
            self.remote = { items = result.cards or {}, state = #result.cards == 0 and "empty" or "ready",
                page = result.page or 1, total_pages = result.total_pages or 1, total_count = result.total_count }
            self.official_page = self.remote.page
            self.cover_pages[self.remote.page] = self.remote.items
            local current_key = self:_official_cache_key(self.remote.page)
            if current_key then pcall(self.catalogue_cache.put, self.catalogue_cache, current_key, result) end
            self:show()
            return self:_scan_cover_pages(self.remote.total_pages, token)
        end,
        on_error = failure,
    })
    if not ok then failure({ code = "network_error", stage = "favorites" }) end
    if not completed and self:_is_current(token) then self.request_handle = handle end
    return ok and (handle or true) or false
end

function Library:can_remove_official(record)
    if not self:_is_current() or not self.official_source or self.busy
        or self.category_id ~= Library.OFFICIAL_ID or self.remote.state ~= "ready" then return false end
    for _, item in ipairs(self.remote.items) do
        if tostring(item.comic_id) == tostring((record or {}).comic_id) then return true end
    end
    return false
end

function Library:remove_official(record)
    if not self:can_remove_official(record) then return false end
    self.busy = true
    self.request_token = self.request_token + 1
    self:_cancel_cover_scan()
    if self.request_handle and self.request_handle.cancel then pcall(self.request_handle.cancel, self.request_handle) end
    self.request_handle = nil
    local token, completed = self.request_token, false
    self:show()
    local function failure(err)
        completed = true
        if not self:_is_current(token) then return false end
        self.busy, self.request_handle = false, nil
        self.remote.state, self.remote.error = "error", err
        return self:show()
    end
    local ok, handle = pcall(self.official_source.remove_favorite, self.official_source, record.comic_id, {
        on_success = function()
            completed = true
            if not self:_is_current(token) then return false end
            self.busy, self.request_handle = false, nil
            return self:load_official(1)
        end,
        on_error = failure,
    })
    if not ok then failure({ code = "favorite_remove_uncertain", stage = "favorite_remove" }) end
    if not completed and self:_is_current(token) then self.request_handle = handle end
    return ok and (handle or true) or false
end

function Library:toggle_selected(comic_id)
    if not self.selecting then return false end
    comic_id = tostring(comic_id or "")
    self.selected[comic_id] = not self.selected[comic_id] or nil
    return self:show()
end

function Library:show()
    if not self:_is_current() then return false end
    local site_id = self.site_id
    local categories = self.store and self.store:list_categories(site_id) or {}
    if self.category_id == Library.OFFICIAL_ID and not self.official_source then self.category_id = nil end
    local official = self.category_id == Library.OFFICIAL_ID
    if self.category_id ~= nil and not official then
        local found = false
        for _, category in ipairs(categories) do
            if tonumber(category.id) == tonumber(self.category_id) then found = true; break end
        end
        if not found then self.category_id = nil end
    end
    local tabs = { { name = "默认", id = nil, active = self.category_id == nil } }
    if self.official_source then
        tabs[#tabs + 1] = { name = "官方收藏", id = Library.OFFICIAL_ID, kind = "official", active = official }
    end
    for _, category in ipairs(categories) do
        tabs[#tabs + 1] = { name = category.name, id = category.id,
            active = tonumber(category.id) == tonumber(self.category_id) }
    end
    local records = official and self.remote.items or self.category_id == nil
        and (self.store and self.store:list_favorites(site_id) or {})
        or (self.store and self.store:list_category_items(site_id, self.category_id) or {})
    local items, count = {}, 0
    for _, record in ipairs(records) do
        local item = copy(record)
        local comic_id = tostring(item.comic_id or "")
        item.selected = self.selected[comic_id] == true
        if item.selected then count = count + 1 end
        item.on_tap = function()
            if not self:_is_current() or self.busy then return false end
            if self.selecting then return self:toggle_selected(comic_id) end
            return self.shell:show_detail(record, {
                return_page = "library", return_options = { category_id = self.category_id,
                    official_page = official and self.remote.page or nil },
            })
        end
        items[#items + 1] = item
    end
    local model = {
        page = "library", items = items, state = #items == 0 and "empty" or "ready",
        tabs = tabs, category_id = self.category_id,
        site_id = site_id, official = official, busy = self.busy == true,
        selecting = self.selecting, selection_count = count,
        actions = {
            select_category = function(category_id)
                if not self:_is_current() or self.selecting or self.busy then return false end
                self.category_id = category_id
                return self:show()
            end,
            begin_selection = function()
                if not self:_is_current() or official then return false end
                self.selecting, self.selected = true, {}
                return self:show()
            end,
            cancel_selection = function()
                self.selecting, self.selected = false, {}
                return self:show()
            end,
            assign_selected = function(category)
                if not self:_is_current() or not self.selecting then return false end
                if category and (category.kind == "official" or not tonumber(category.id)) then return false end
                local ids = {}
                for _, record in ipairs(records) do
                    if self.selected[tostring(record.comic_id or "")] then
                        ids[#ids + 1] = record.comic_id
                    end
                end
                if #ids == 0 then return false end
                local category_id = category and category.id or nil
                local saved = self.store:assign_category(site_id, ids, category_id)
                if saved == false then return false end
                self.category_id = category_id
                self.selecting, self.selected = false, {}
                return self:show()
            end,
            manage_categories = function()
                return self.shell:show("categories", { return_category_id = self.category_id })
            end,
        },
    }
    model.cover_groups = { { owner = "local:" .. site_id, complete = true,
        items = self.store and self.store:list_favorites(site_id) or {} } }
    -- This owner represents the current collection for one source. Authentication
    -- remains part of each catalogue/thumbnail identity, not the retention policy.
    local owner = self.official_source and ("official:" .. self.site_id .. ":" .. tostring(self.official_source.origin))
    if owner then
        local pages, covers, seen = {}, {}, {}
        for page in pairs(self.cover_pages) do pages[#pages + 1] = page end
        table.sort(pages)
        for _, page in ipairs(pages) do
            for _, card in ipairs(self.cover_pages[page]) do
                local id = tostring(card.comic_id)
                if not seen[id] then covers[#covers + 1] = card; seen[id] = true end
            end
        end
        model.cover_groups[#model.cover_groups + 1] = { owner = owner, items = covers, complete = self.cover_complete }
    end
    if official then
        model.state, model.error = self.remote.state, self.remote.error
        model.page_number, model.total_pages, model.total_count = self.remote.page, self.remote.total_pages, self.remote.total_count
        model.subtitle = self.busy and "正在取消 Zero 网页收藏…"
            or model.state == "loading" and "正在同步 Zero 网页收藏…"
            or self.remote.refresh_error and "本地缓存 · Zero 网页收藏（刷新失败）"
            or ("Zero 网页收藏 · " .. tostring(self.remote.total_count or #items) .. " 本")
        model.loading_message, model.empty_message = "正在同步 Zero 网页收藏…", "Zero 网页收藏夹为空"
        model.actions.begin_selection, model.actions.assign_selected, model.actions.manage_categories = nil, nil, nil
        model.actions.refresh = function() return self:load_official(1) end
        model.actions.retry = model.actions.refresh
        model.actions.relogin = function() return self.shell:show("settings") end
        model.actions.previous_page = function()
            if self.remote.page <= 1 then return false end
            return self:load_official(self.remote.page - 1)
        end
        model.actions.next_page = function()
            if self.remote.page >= self.remote.total_pages then return false end
            return self:load_official(self.remote.page + 1)
        end
        model.actions.can_remove_official = function(record) return self:can_remove_official(record) end
        model.actions.remove_official = function(record) return self:remove_official(record) end
    end
    local published = self.shell:set_model(model, self.view_token)
    if self.official_source and not self.started then return self:load_official(self.official_page) end
    return published
end

return Library
