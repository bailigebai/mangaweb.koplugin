-- Optional shared image service. MangaWeb keeps owning its settings, window and
-- downloads; an unavailable or failing service must leave reading untouched.
local Bridge = {}
Bridge.__index = Bridge

function Bridge:new(options)
    local bridge = setmetatable({}, self)
    local settings = options.settings
    local loaded, loader = pcall(require, "pluginloader")
    if not loaded or type(loader) ~= "table" or type(loader.getPluginInstance) ~= "function"
        or not settings or type(settings.graydither_store) ~= "function" then return bridge end
    local found, service = pcall(loader.getPluginInstance, loader, "graydither")
    if not found or type(service) ~= "table" or type(service.createImageSession) ~= "function" then return bridge end
    local created, session = pcall(service.createImageSession, service, {
        owner = options.owner, store = settings:graydither_store(),
        is_ready = options.is_ready, redraw = options.redraw,
    })
    if created and type(session) == "table" and type(session.attachImage) == "function"
        and type(session.close) == "function" then bridge.session = session end
    return bridge
end

function Bridge:isAvailable()
    return self.session ~= nil and self.session.closed ~= true
end

function Bridge:_call(method, ...)
    if not self:isAvailable() then return false end
    local session = self.session
    local callback = session[method]
    if type(callback) ~= "function" then self:close(); return false end
    local ok, value = pcall(callback, session, ...)
    if not ok or value == false then self:close(); return false end
    return true
end

function Bridge:attachImage(image, token)
    return self:_call("attachImage", image, token)
end

function Bridge:pause(preserve_progress)
    local preserve = preserve_progress == true
    if self.paused and (self.preserve_progress == false or preserve) then return end
    if self:_call("pause", preserve) then
        self.paused, self.preserve_progress = true, preserve
    end
end

function Bridge:resume()
    if self.paused and self:_call("resume") then
        self.paused, self.preserve_progress = false, nil
    end
end

function Bridge:reset() return self:_call("reset") end
function Bridge:settingsChanged() return self:_call("settingsChanged") end
function Bridge:requestRefresh()
    if not self:isAvailable() then return false end
    local session = self.session
    if type(session.requestRefresh) ~= "function" then self:close(); return false end
    local ok, accepted = pcall(session.requestRefresh, session)
    if not ok then self:close(); return false end
    -- Busy, scrolling and temporarily covered pages may decline a refresh.
    -- These normal refusals do not invalidate the healthy image session.
    return accepted == true
end

function Bridge:close()
    local session = self.session
    self.session = nil
    if session and session.closed ~= true and type(session.close) == "function" then pcall(session.close, session) end
end

return Bridge
