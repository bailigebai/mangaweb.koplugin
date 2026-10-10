local Settings = require("mangaweb.ui.settings")

local origin = "https://old.example.com"
local source = { id = "zero", origin = origin }
function source:meta() return { name = "Zero", origin = self.origin } end
function source:capabilities() return { login = true } end
local manager = {}
function manager:set_zero_origin(value)
    origin, source.origin = value, value
    return true
end
local model
local shell = { set_model = function(_, value) model = value; return true end }
local page = Settings:new{ shell = shell, source = source,
    site_manager = manager }
assert(page:show())
assert(type(model.actions.set_origin) == "function"
    and model.origin == "https://old.example.com",
    "Zero settings must expose an editable domain action")
assert(model.actions.set_origin("https://new.example.com"))
assert(origin == "https://new.example.com"
    and model.origin == "https://new.example.com",
    "the settings page must refresh after changing Zero's domain")

print("site_settings_domain_spec: passed")
