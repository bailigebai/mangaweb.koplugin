local Prefetch = {}
Prefetch.__index = Prefetch

function Prefetch:new(options)
    return setmetatable({ loader = options.loader, generation = options.generation,
        alive = options.alive, defer = options.defer, on_error = options.on_error,
        queue = {}, cursor = 1, seen = {}, active = 0 }, self)
end

function Prefetch:_schedule()
    if self.scheduled or self.pumping or not self.alive() then return end
    self.scheduled = true
    local function run() self.scheduled = false; self:_pump() end
    if not self.defer or self.defer(run) ~= true then run() end
end

function Prefetch:add(specs)
    for _, spec in ipairs(specs or {}) do
        if not self.seen[spec.key] then
            self.seen[spec.key] = true
            self.queue[#self.queue + 1] = spec
        end
    end
    self:_schedule()
end

function Prefetch:_pump()
    if self.pumping or not self.alive() then return end
    self.pumping = true
    local quota = 16
    while self.active < 2 and self.cursor <= #self.queue and self.alive() and quota > 0 do
        local spec = self.queue[self.cursor]
        self.cursor, quota, self.active = self.cursor + 1, quota - 1, self.active + 1
        spec.cache_only, spec.priority, spec.stage = true, 4, "cover"
        local settled = false
        local function done(err)
            if settled then return end
            settled = true
            self.active = self.active - 1
            self.loader:release(self.generation, spec.key)
            if err and self.alive() and self.on_error then pcall(self.on_error, spec, err) end
            self:_schedule()
            return true
        end
        local ok = pcall(self.loader.request, self.loader, self.generation, spec,
            { on_ready = function() return done() end, on_error = done })
        if not ok then done({ code = "image_error" }) end
    end
    self.pumping = false
    if self.active < 2 and self.cursor <= #self.queue then self:_schedule() end
end

return Prefetch
