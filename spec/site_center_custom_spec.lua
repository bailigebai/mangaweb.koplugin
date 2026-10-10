local SiteCenter = require("mangaweb.ui.site_center")

local definitions = {
    { id = "custom-1", name = "我的站", origin = "https://example.com", rules = {} },
}
local manager = {}
function manager:list() return definitions end
function manager:add(value)
    local site = { id = "custom-2", name = value.name, origin = value.origin,
        rules = value.rules }
    definitions[#definitions + 1] = site
    return site
end
function manager:update(id, value)
    for index, site in ipairs(definitions) do
        if site.id == id then
            definitions[index] = { id = id, name = value.name,
                origin = value.origin, rules = value.rules }
            return definitions[index]
        end
    end
end
function manager:remove(id)
    for index, site in ipairs(definitions) do
        if site.id == id then table.remove(definitions, index); return true end
    end
    return false
end
local registry = { sources = {
    zero = { meta = function() return { name = "Zero", origin = "https://zero.example.com" } end },
    ["custom-1"] = { meta = function() return { name = "我的站", origin = "https://example.com" } end },
} }
function registry:ids() return { "zero", "custom-1" } end
local model
local shell = {}
function shell:set_model(value) model = value; return true end
function shell:show_site(id) return id end
function shell:show_settings(id) return id end
local center = SiteCenter:new{ shell = shell, source_registry = registry,
    site_manager = manager }
assert(center:show())
assert(#model.sites == 2 and model.sites[2].definition.id == "custom-1"
    and model.sites[2].custom == true,
    "the manager page must expose editable definitions for custom sites")
assert(type(model.actions.add_site) == "function"
    and type(model.actions.update_site) == "function"
    and type(model.actions.remove_site) == "function")
assert(model.actions.add_site{ name = "第二站", origin = "https://two.example.com", rules = {} })
assert(#definitions == 2)
assert(model.actions.update_site("custom-1", {
    name = "已改名", origin = "https://example.com", rules = {},
}))
assert(definitions[1].name == "已改名")
assert(model.actions.remove_site("custom-1"))
assert(#definitions == 1, "deletion should route through the site manager")

print("site_center_custom_spec: passed")
