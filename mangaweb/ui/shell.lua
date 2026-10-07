local Picker = require("mangaweb.ui.source_picker")
local Browse = require("mangaweb.ui.browse")
local Detail = require("mangaweb.ui.detail")
local Library = require("mangaweb.ui.library")
local History = require("mangaweb.ui.history")
local Settings = require("mangaweb.ui.settings")
local SiteCenter = require("mangaweb.ui.site_center")
local CategoryShelf = require("mangaweb.ui.category_shelf")
local Models = require("mangaweb.models")
local DetailCache = require("mangaweb.detail_cache")

local Shell = {}
Shell.__index = Shell

function Shell:new(options)
    options = options or {}
    return setmetatable({
        ui = options.ui or options.ui_manager,
        registry = assert(options.source_registry, "source_registry is required"),
        store = options.store,
        auth = options.auth,
        http = options.http,
        catalogue_cache = options.catalogue_cache,
        detail_cache = options.detail_cache or DetailCache:new{ keyer = options.catalogue_cache },
        reader = options.reader,
        license = options.license,
        license_dialog = options.license_dialog,
        site_manager = options.site_manager,
        scheduler = options.scheduler or (options.ui and options.ui.ui_manager),
        logger = options.logger or (options.ui and options.ui.logger),
        model_value = { page = "browse", state = "loading" },
        view_token = 0,
        root_page = "browse",
        root_options = nil,
        return_page = nil,
        return_options = nil,
        closed = false,
        on_close = options.on_close,
        on_start_reading = options.on_start_reading,
    }, self)
end

function Shell:_next_view()
    if self.license_dialog and type(self.license_dialog.close) == "function" then
        pcall(self.license_dialog.close, self.license_dialog, "route")
    end
    if self.reader and self.reader.closed == false then self.reader:close("route") end
    if self.detail and type(self.detail.close) == "function" then self.detail:close() end
    self.detail = nil
    if self.browse and type(self.browse.close) == "function" then self.browse:close() end
    self.browse = nil
    if self.library and type(self.library.close) == "function" then self.library:close() end
    self.library = nil
    if self.settings_page and type(self.settings_page.close) == "function" then
        self.settings_page:close()
    end
    self.settings_page = nil
    self.view_token = self.view_token + 1
    return self.view_token
end

function Shell:is_view(token)
    return not self.closed and token == self.view_token
end

function Shell:set_model(model, token)
    if self.closed or token and not self:is_view(token) then return false end
    self.model_value = model or {}
    if self.model_value.error then
        self.model_value.error = Models.error(self.model_value.error,
            self.model_value.site_id or (self.model_value.site or {}).id or self.registry:current_id())
        self.model_value.state = self.model_value.error.code
    end
    if self.model_value.page == "detail" and self.model_value.actions then
        self.model_value.actions.back = function() return self:back_from_detail() end
    end
    if self.ui and type(self.ui.update_model) == "function" then self.ui:update_model(self.model_value) end
    return true
end

function Shell:model()
    return self.model_value
end

function Shell:registry_state()
    return self.registry:state(self.registry:current_id())
end

function Shell:show(page, options)
    options = options or {}
    local token = self:_next_view()
    if page == "detail" then
        self.return_page = options.return_page or self.root_page
        self.return_options = options.return_options or self.root_options
        if not options.card then return self:set_model{ page = "detail" } end
        local detail = Detail:new{ source = self.registry:current(), store = self.store,
            shell = self, view_token = token, scheduler = self.scheduler, logger = self.logger }
        self.detail = detail
        return detail:show(options.card)
    end
    self.root_page, self.root_options = page, options
    if page == "site_center" then
        self.site_center = SiteCenter:new{ source_registry = self.registry, auth = self.auth, shell = self,
            license = self.license, license_dialog = self.license_dialog,
            site_manager = self.site_manager, view_token = token }
        return self.site_center:show()
    end
    if page == "library" then
        self.library = Library:new{ source_registry = self.registry, store = self.store, shell = self,
            view_token = token, category_id = options.category_id, official_page = options.official_page }
        return self.library:show()
    end
    if page == "history" then
        self.history = History:new{ source_registry = self.registry, store = self.store, shell = self,
            view_token = token }
        return self.history:show()
    end
    if page == "categories" then
        self.category_shelf = CategoryShelf:new{ store = self.store, shell = self,
            site_id = self.registry:current_id(), view_token = token,
            return_category_id = options.return_category_id }
        return self.category_shelf:show(options.category)
    end
    if page == "settings" then
        return self:show_settings(self.registry:current_id(), token)
    end
    local browse = Browse:new{ source = self.registry:current(), shell = self, store = self.store,
        view_token = token }
    self.browse = browse
    return browse:load(self:registry_state())
end

function Shell:show_site(site_id)
    local source, error_code = self.registry:switch(site_id)
    if not source then return nil, error_code end
    return self:show("browse")
end

function Shell:show_settings(site_id, token)
    local source = self.registry.sources[site_id]
    if not source then return nil, "unknown_site" end
    token = token or self:_next_view()
    self.settings_page = Settings:new{ source = source, auth = self.auth, http = self.http,
        shell = self, site_manager = self.site_manager, view_token = token }
    return self.settings_page:show()
end

function Shell:set_page(page)
    return self:show(page)
end

function Shell:show_detail(card, options)
    options = options or {}
    options.card = card
    return self:show("detail", options)
end

function Shell:back_from_detail()
    local result = self:show(self.return_page or "browse", self.return_options)
    return result ~= false and result ~= nil
end

function Shell:show_tag(tag)
    local token = self:_next_view()
    local browse = Browse:new{ source = self.registry:current(), shell = self, store = self.store,
        view_token = token }
    self.browse = browse
    self.root_page = "browse"
    local result = browse:apply_tag(tag)
    local state = self:registry_state() or {}
    self.root_options = { page = state.page, query = state.query, category = state.category,
        tag = state.tag, sort = state.sort, channel = state.channel }
    return result
end

function Shell:_open_reader(card, reader_context)
    if self.on_start_reading then return self.on_start_reading(card, reader_context) end
    return false, "reader_not_connected"
end

function Shell:start_reading(card, reader_context)
    if self.closed then return false, "shell_closed" end
    if not self.license or not self.license_dialog then
        return false, "license_unavailable"
    end
    local checked, authorized = pcall(self.license.is_authorized, self.license)
    if checked and authorized == true then return self:_open_reader(card, reader_context) end

    local token = self.view_token
    local resumed = false
    local function resume()
        if resumed or self.closed or self.view_token ~= token then
            return false, "stale_read_request"
        end
        resumed = true
        local opened, result, reason = pcall(self._open_reader, self, card, reader_context)
        if not opened then result, reason = false, "reader_error" end
        if not result then
            reason = reason or "reader_error"
            if reader_context and type(reader_context.on_open_error) == "function" then
                pcall(reader_context.on_open_error, reason)
            end
            return false, reason
        end
        return result, reason
    end
    local requested, result, code = pcall(
        self.license_dialog.request_read, self.license_dialog, resume
    )
    if not requested then return false, "license_dialog_failed" end
    if result == nil or result == false then return false, code or "license_dialog_failed" end
    return true, "activation_pending"
end

function Shell:show_source_picker()
    local shell = self
    return Picker:new{ on_choose = function(site_id)
        local source, error_code = shell.registry:switch(site_id)
        if not source then return nil, error_code end
        return shell:show("browse")
    end }
end

function Shell:source_ids()
    return self.registry:ids()
end

function Shell:close()
    if self.closed then return true end
    self:_next_view()
    self.closed = true
    if self.detail_cache then self.detail_cache:clear() end
    if self.on_close then return self.on_close() end
    if self.ui and self.ui.close_fullscreen then self.ui:close_fullscreen(self) end
    return true
end

return Shell
