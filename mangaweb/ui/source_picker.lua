local Picker = {}
Picker.__index = Picker

function Picker:new(options)
    return setmetatable(options or {}, self)
end

function Picker:choose(site_id)
    if self.on_choose then return self.on_choose(site_id) end
    return nil, "picker_not_connected"
end

return Picker
