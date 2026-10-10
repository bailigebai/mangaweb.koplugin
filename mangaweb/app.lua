local App = {}
App.__index = App

local Registry = require("mangaweb.source_registry")
local Shell = require("mangaweb.ui.shell")
local RemoteChapterIndex = require("mangaweb.remote_chapter_index")
local ImageLoader = require("mangaweb.image_loader")
local CoverLoader = require("mangaweb.cover_loader")
local SiteDefinitions = require("mangaweb.site_definitions")
local SiteManager = require("mangaweb.site_manager")

function App.build_sources(options)
    options = options or {}
    local definitions = assert(options.definitions, "site definitions are required")
    local Zero = require("mangaweb.sources.zero")
    local Custom = require("mangaweb.sources.custom")
    local sources = { zero = Zero:new{ http = options.http, auth = options.auth,
        logger = options.logger, origin = definitions:zero_origin() } }
    local api = require("mangaweb.bilibili_api"):new{http=options.http,
        json=options.bilibili_json,logger=options.logger}
    local session = require("mangaweb.bilibili_session"):new{settings=options.settings or definitions.settings}
    local account_auth = require("mangaweb.bilibili_auth"):new{api=api,session=session,
        scheduler=options.bilibili_scheduler,logger=options.logger}
    sources.bilibili = require("mangaweb.sources.bilibili"):new{api=api,account_auth=account_auth}
    for _, definition in ipairs(definitions:list()) do
        sources[definition.id] = Custom:new{
            definition = definition, http = options.http, auth = options.auth,
        }
    end
    return sources
end

local function ensure_license_runtime(options)
    if not options.license then
        local LicenseStore = require("mangaweb.license_store")
        local LicenseDevice = require("mangaweb.license_device")
        local LicenseTransport = require("mangaweb.license_transport")
        local License = require("mangaweb.license")
        options.license_store = options.license_store or LicenseStore:new(options.license_store_options)
        options.license_device = options.license_device or LicenseDevice:new(options.license_device_options)
        options.license_transport = options.license_transport
            or LicenseTransport:new(options.license_transport_options)
        options.license = License:new{
            store = options.license_store,
            device = options.license_device,
            transport = options.license_transport,
            crypto = options.license_crypto,
            protocol = options.license_protocol,
            public_key = options.license_public_key,
            public_key_path = options.license_public_key_path,
            read_file = options.license_read_file,
        }
    end
    if options.license and options.ui and not options.license_dialog then
        options.license_dialog = require("mangaweb.license_dialog"):new{
            license = options.license,
            ui = options.ui,
        }
    end
end

local function ensure_loader(options)
    options.catalogue_cache = options.catalogue_cache or require("mangaweb.catalogue_cache"):new{}
    local loader = options.loader or (options.reader and options.reader.loader)
    if not loader and options.http and options.temp_files then
        loader = ImageLoader:new{ http = options.http, temp_files = options.temp_files,
            page_cache = options.page_cache, logger = options.logger }
    end
    if loader then
        if options.page_cache and not loader.page_cache then loader.page_cache = options.page_cache end
        options.loader = loader
        if options.reader then
            options.reader.loader = loader
            options.reader.page_cache = loader.page_cache
        end
        if options.ui then options.ui.loader = loader end
    end
    if not options.cover_loader and options.http and options.temp_files then
        options.cover_cache = options.cover_cache or require("mangaweb.page_cache"):new{
            directory = "covers", upper_bytes = 48 * 1048576, lower_bytes = 32 * 1048576 }
        options.cover_loader = CoverLoader:new{ http = options.http, temp_files = options.temp_files,
            cache = options.cover_cache, page_cache = options.page_cache, logger = options.logger }
    end
    if options.ui then options.ui.cover_loader = options.cover_loader end
    return loader
end

local function default_runtime(options)
    if options.source_registry then
        ensure_loader(options)
        if not options.reader and options.store and options.http and options.temp_files and options.ui then
            local Reader = require("mangaweb.reader")
            options.reader = Reader:new{
                store = options.store, http = options.http,
                temp_files = options.temp_files, ui = options.ui, loader = options.loader,
                settings = options.settings, logger = options.logger,
            }
        end
        return options
    end
    if options.sources and options.settings and options.http and options.auth
        and options.store and options.reader then
        ensure_loader(options)
        options.source_registry = Registry:new{ sources = options.sources, settings = options.settings }
        ensure_license_runtime(options)
        return options
    end
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local settings_path = DataStorage:getSettingsDir() .. "/mangaweb.lua"
    local data_root = DataStorage.getDataDir and DataStorage:getDataDir() or "."
    if type(DataStorage.getFullDataDir) == "function" then
        local ok, full = pcall(DataStorage.getFullDataDir, DataStorage)
        if ok and type(full) == "string" and full ~= "" then data_root = full end
    end
    local settings = options.settings or require("mangaweb.settings"):new{ path = settings_path }
    local definitions = options.site_definitions or SiteDefinitions:new{ settings = settings }
    local logger = options.logger
    if logger == nil then
        local ok, value = pcall(require, "logger")
        logger = ok and value or nil
    end
    options.logger = logger
    local transport = require("mangaweb.transport"):new{ logger = logger }
    local http = options.http or require("mangaweb.http"):new{ transport = transport, logger = logger }
    local auth = options.auth or require("mangaweb.auth"):new{
        settings = settings, http = http,
        origins = { zero = definitions:zero_origin() },
        login_paths = { zero = "/Android/my/" },
    }
    local Store = require("mangaweb.store")
    local store = options.store or Store:new{ path = data_root .. "/mangaweb.sqlite3" }
    local TempFiles = require("mangaweb.temp_files")
    local temp_files = options.temp_files or TempFiles:new{ root = data_root .. "/mangaweb-reader" }
    options.http, options.temp_files = http, temp_files
    if not options.page_cache then
        options.page_cache = require("mangaweb.page_cache"):new{}
    end
    ensure_loader(options)
    local ui = options.ui
    if not ui or type(ui.show_fullscreen) ~= "function" then
        ui = require("mangaweb.ui.koreader"):new{ http = http, temp_files = temp_files,
            loader = options.loader, cover_loader = options.cover_loader }
        options.ui = ui
    elseif ui.loader == nil then
        ui.loader = options.loader
    end
    local Reader = require("mangaweb.reader")
    local sources = options.sources or App.build_sources{
        definitions = definitions, http = http, auth = auth, logger = logger,settings=settings,
        bilibili_scheduler=options.bilibili_scheduler,bilibili_json=options.bilibili_json,
    }
    if auth.origins then
        for site_id, source in pairs(sources) do auth.origins[site_id] = source.origin end
    end
    options.settings, options.http, options.auth, options.store = settings, http, auth, store
    options.sources = sources
    options.reader = options.reader or Reader:new{
        store = store, http = http, temp_files = temp_files, ui = ui,
        loader = options.loader, settings = settings, logger = logger,
    }
    options.source_registry = options.source_registry or Registry:new{ sources = sources, settings = settings }
    options.site_definitions = definitions
    options.site_manager = options.site_manager or SiteManager:new{
        definitions = definitions, registry = options.source_registry,
        auth = auth, http = http,
    }
    options.settings_store = LuaSettings
    ensure_license_runtime(options)
    return options
end

function App:new(options)
    options = options or {}
    if options.deps then
        for key, value in pairs(options.deps) do
            if options[key] == nil then options[key] = value end
        end
    end
    options = default_runtime(options)
    local sources = options.sources or {}
    local registry = options.source_registry
    if not registry and next(sources) then
        registry = Registry:new{ sources = sources, settings = options.settings }
    end
    return setmetatable({
        ui = options.ui,
        opened = false,
        site_id = options.site_id or "zero",
        registry = registry,
        sources = sources,
        store = options.store,
        reader = options.reader,
        auth = options.auth,
        settings = options.settings,
        http = options.http,
        logger = options.logger,
        loader = options.loader,
        cover_loader = options.cover_loader,
        catalogue_cache = options.catalogue_cache,
        license = options.license,
        license_dialog = options.license_dialog,
        site_manager = options.site_manager,
        shell_object = nil,
    }, self)
end

function App:_remote_context(card)
    card = card or {}
    local site_id = tostring(card.site_id or self:active_site() or "remote")
    local comic_id = tostring(card.comic_id or "comic")
    local chapter_id = tostring(card.chapter_id or card.default_chapter_id or "chapter-1")
    local prefix = ("mangaweb://%s/%s/%s"):format(
        site_id:gsub("[^%w_%-]", "_"), comic_id:gsub("[^%w_%-]", "_"),
        chapter_id:gsub("[^%w_%-]", "_"))
    local manga_path = ("mangaweb://%s/%s"):format(
        site_id:gsub("[^%w_%-]", "_"), comic_id:gsub("[^%w_%-]", "_"))
    local source = self.sources[site_id]
        or (self.registry and self.registry.sources and self.registry.sources[site_id])
        or {}
    return {
        connection = {
            kind = "remote",
            server_url = tostring(source.origin or ""),
            username = site_id,
            root_path = "mangaweb://" .. site_id,
        },
        manga = { name = card.title, path = manga_path, is_folder = true },
        chapter = { name = card.chapter_title or chapter_id, path = prefix, is_folder = true },
        chapter_index = RemoteChapterIndex:new{ pages = card.pages, path_prefix = prefix },
        chapter_position = card.chapter_position,
        prefetch_near_count = 2,
        prefetch_far_count = 2,
        layout = "remote",
        source_context = {
            on_return = function()
                if self.ui and type(self.ui.show_fullscreen) == "function" then
                    return self.ui:show_fullscreen(self.shell_object)
                end
                return true
            end,
        },
    }
end

function App:show()
    if not self.registry then
        self.opened = true
        if self.ui and type(self.ui.show_fullscreen) == "function" then self.ui:show_fullscreen(self) end
        return true
    end
    self.opened = true
    if not self.ui or type(self.ui.show_fullscreen) ~= "function" then
        self.ui = require("mangaweb.ui.koreader"):new{
            http = self.http, loader = self.loader, cover_loader = self.cover_loader }
    end
    if self.license and not self.license_dialog then
        self.license_dialog = require("mangaweb.license_dialog"):new{
            license = self.license,
            ui = self.ui,
        }
    end
    if self.shell_object and self.shell_object.closed then self.shell_object = nil end
    self.shell_object = self.shell_object or Shell:new{
        ui = self.ui,
        source_registry = self.registry,
        store = self.store,
        auth = self.auth,
        http = self.http,
        reader = self.reader,
        scheduler = self.ui and self.ui.ui_manager,
        logger = self.logger,
        license = self.license,
        license_dialog = self.license_dialog,
        site_manager = self.site_manager,
        on_close = function() return self:close() end,
        catalogue_cache = self.catalogue_cache,
        on_start_reading = function(card, reader_context)
            if not self.reader or type(self.reader.open) ~= "function" then
                return false, "reader_unavailable"
            end
            reader_context = reader_context or {}
            local pages = reader_context.pages or (type(card) == "table" and card.pages) or {}
            if type(card) ~= "table" or #pages == 0 and type(reader_context.load_pages) ~= "function" then
                return false, "pages_empty"
            end
            local context = self:_remote_context(card)
            for key, value in pairs(reader_context) do context[key] = value end
            context.site_id, context.comic_id = card.site_id, card.comic_id
            context.title, context.author = card.title, card.author
            context.cover_url, context.detail_url = card.cover_url, card.detail_url
            context.chapter_id = reader_context.chapter_id or card.chapter_id
            context.default_chapter_id = reader_context.default_chapter_id or card.default_chapter_id
            context.page_index, context.pages = reader_context.page_index or card.page_index, pages
            return self.reader:open(context)
        end,
    }
    if self.ui and self.ui.set_reader and self.reader then self.ui:set_reader(self.reader) end
    self.shell_object:show(self.registry:has_saved_active_site() and "browse" or "site_center")
    if self.ui and type(self.ui.show_fullscreen) == "function" then
        self.ui:show_fullscreen(self.shell_object)
    end
    return true
end

function App:close()
    self.opened = false
    if self.license_dialog and type(self.license_dialog.close) == "function" then
        pcall(self.license_dialog.close, self.license_dialog, "app_close")
    elseif self.license and type(self.license.cancel) == "function" then
        pcall(self.license.cancel, self.license)
    end
    if self.reader and self.reader.close then self.reader:close("app_close") end
    if self.http and self.http.cancel_all then self.http:cancel_all() end
    if self.settings and self.settings.flush then self.settings:flush() end
    if self.shell_object then
        self.shell_object.closed = true
        if self.shell_object.ui and self.shell_object.ui.close_fullscreen then
            self.shell_object.ui:close_fullscreen(self.shell_object)
        end
        self.shell_object = nil
    elseif self.ui and type(self.ui.close_fullscreen) == "function" then
        self.ui:close_fullscreen(self)
    end
    return true
end

function App:is_open()
    return self.opened
end

function App:active_site()
    return self.registry and self.registry:current_id() or self.site_id
end

function App:shell()
    return self.shell_object
end

return App
