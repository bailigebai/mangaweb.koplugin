local Registry = require("mangaweb.source_registry")
local Definitions = require("mangaweb.site_definitions")
local SiteManager = require("mangaweb.site_manager")
local Auth = require("mangaweb.auth")

local values = {}
local settings = {}
function settings:read(key, fallback) return values[key] or fallback end
function settings:write(key, value) values[key] = value; return true end
function settings:flush() return true end
local definitions = Definitions:new{ settings = settings }
local zero = { id = "zero", origin = definitions:zero_origin() }
local registry = Registry:new{ sources = { zero = zero }, settings = settings }
local auth = Auth:new{ settings = settings, origins = { zero = zero.origin } }
local manager = SiteManager:new{ definitions = definitions, registry = registry,
    auth = auth, http = { get = function() end } }
local rules = {
    list_path = "/list?page={page}", list_block = "(<article.-</article>)",
    list_href = 'href="(.-)"', list_title = 'title="(.-)"',
    list_cover = 'src="(.-)"', detail_title = "<h1>(.-)</h1>",
    detail_cover = 'src="(.-)"', page_image = 'src="(.-)"',
}
local created = assert(manager:add{ name = "自定义", origin = "https://example.com", rules = rules })
assert(registry.sources[created.id] and registry:ids()[1] == "zero"
    and registry:ids()[2] == created.id,
    "adding a site must register it after Zero")
assert(registry:switch(created.id))
assert(manager:update(created.id, { name = "新名称",
    origin = "https://new.example.com", rules = rules }))
assert(registry:current():meta().name == "新名称"
    and auth.origins[created.id] == "https://new.example.com")
assert(manager:set_zero_origin("https://zero.example.com"))
assert(zero.origin == "https://zero.example.com"
    and auth.origins.zero == "https://zero.example.com")
assert(manager:remove(created.id))
assert(registry:current_id() == "zero" and #registry:ids() == 1
    and settings:read("active_site") == "zero",
    "removing the active custom site must return to Zero")
assert(#definitions:list() == 0)

print("registry_custom_spec: passed")
