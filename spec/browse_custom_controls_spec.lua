local Browse = require("mangaweb.ui.browse")

local model
local shell = {
    registry_state = function() return { page = 1 } end,
    set_model = function(_, value) model = value; return true end,
    model = function() return model end,
}
local source = {
    id = "custom-1", name = "个人站点",
    capabilities = function() return { search = false, categories = false, tags = false } end,
    list = function(_, _, callbacks)
        return callbacks.on_success{ cards = {}, page = 1, total_pages = 1 }
    end,
}
local browse = Browse:new{ source = source, shell = shell }
browse:load()
assert(model and model.actions.search == nil and model.actions.categories == nil
    and model.actions.tags == nil, "unsupported filters must not be offered")
assert(type(model.actions.refresh) == "function", "refresh must remain available")

source.capabilities = function()
    return { search = true, categories = true, tags = false }
end
source.list_categories = function(_, callbacks)
    return callbacks.on_success{}
end
browse:load()
assert(type(model.actions.search) == "function"
    and type(model.actions.categories) == "function" and model.actions.tags == nil,
    "supported controls should remain available")

print("browse_custom_controls_spec: passed")
