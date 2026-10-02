local Custom = require("mangaweb.sources.custom")

local Manager = {}
Manager.__index = Manager

function Manager:new(options)
    options = options or {}
    return setmetatable({
        definitions = assert(options.definitions, "site definitions are required"),
        registry = assert(options.registry, "source registry is required"),
        auth = options.auth,
        http = options.http,
    }, self)
end

function Manager:list() return self.definitions:list() end
function Manager:zero_origin() return self.definitions:zero_origin() end

function Manager:_source(definition)
    return Custom:new{ definition = definition, http = self.http, auth = self.auth }
end

function Manager:add(definition)
    local saved, reason = self.definitions:add(definition)
    if not saved then return nil, reason end
    local source = self:_source(saved)
    local registered, error_code = self.registry:register(saved.id, source)
    if not registered then
        self.definitions:remove(saved.id)
        return nil, error_code
    end
    if self.auth and self.auth.origins then self.auth.origins[saved.id] = saved.origin end
    return saved
end

function Manager:update(site_id, definition)
    local saved, reason = self.definitions:update(site_id, definition)
    if not saved then return nil, reason end
    self.registry:register(site_id, self:_source(saved))
    if self.auth and self.auth.origins then self.auth.origins[site_id] = saved.origin end
    return saved
end

function Manager:remove(site_id)
    local removed, reason = self.definitions:remove(site_id)
    if not removed then return false, reason end
    self.registry:remove(site_id)
    if self.auth and self.auth.origins then self.auth.origins[site_id] = nil end
    return true
end

function Manager:set_zero_origin(origin)
    local saved, reason = self.definitions:set_zero_origin(origin)
    if not saved then return false, reason end
    local source = self.registry.sources.zero
    if source then
        source.origin = self.definitions:zero_origin()
        source.session_verified = false
        source._mangaweb_primary_categories = nil
    end
    if self.auth and self.auth.origins then
        self.auth.origins.zero = self.definitions:zero_origin()
    end
    self.registry:reset_state("zero")
    return true
end

return Manager
