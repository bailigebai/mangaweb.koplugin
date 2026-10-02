local Async = {}

local function dependencies(options)
    options = options or {}
    local scheduler = options.scheduler
    if not scheduler then
        local ok, value = pcall(require, "ui/uimanager")
        if ok then scheduler = value end
    end
    local ffiutil = options.ffiutil
    if ffiutil == nil then
        local ok, value = pcall(require, "ffi/util")
        ffiutil = ok and value or false
    end
    return scheduler, ffiutil
end

local function schedule(scheduler, delay, callback)
    if not scheduler or type(scheduler.scheduleIn) ~= "function" then return false end
    local ok, result = pcall(scheduler.scheduleIn, scheduler, delay or 0, callback)
    return ok and result ~= false
end

local function serialize(value)
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    if kind ~= "table" then return "nil" end
    local fields = {}
    for key, item in pairs(value) do
        if type(key) == "string" or type(key) == "number" then
            fields[#fields + 1] = "[" .. serialize(key) .. "]=" .. serialize(item)
        end
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

local function deserialize(value)
    if type(value) ~= "string" or value == "" then return nil end
    local loader = loadstring or load
    local chunk = loader("return " .. value)
    if not chunk then return nil end
    if setfenv then setfenv(chunk, {}) end
    local ok, result = pcall(chunk)
    return ok and result or nil
end

function Async.available(options)
    local scheduler, ffiutil = dependencies(options)
    return scheduler and type(scheduler.scheduleIn) == "function" and ffiutil
        and type(ffiutil.runInSubProcess) == "function"
        and type(ffiutil.writeToFD) == "function"
        and type(ffiutil.readAllFromFD) == "function"
        and type(ffiutil.isSubProcessDone) == "function" or false
end

function Async.run(work, done, options)
    options = options or {}
    local scheduler, ffiutil = dependencies(options)
    local handle = { canceled = false }
    local settled = false
    local function settle(ok, result, error_value)
        if settled then return end
        settled = true
        if not handle.canceled and type(done) == "function" then pcall(done, ok, result, error_value) end
    end
    if not Async.available{ scheduler = scheduler, ffiutil = ffiutil } then
        schedule(scheduler, 0, function() settle(false, nil, "background subprocess unavailable") end)
        return handle
    end

    local max_payload = tonumber(options.max_payload_bytes) or 16384
    local function child_entry(_, write_fd)
        local ok, result = pcall(work)
        local payload = serialize(ok and { ok = true, result = result }
            or { ok = false, error = tostring(result):sub(1, 500) })
        if #payload > max_payload then
            payload = serialize{ ok = false, error = "subprocess payload too large" }
        end
        pcall(ffiutil.writeToFD, write_fd, payload, true)
    end

    local launched, pid, read_fd = pcall(ffiutil.runInSubProcess, child_entry, true)
    if not launched or not pid then
        schedule(scheduler, 0, function() settle(false, nil, "subprocess launch failed") end)
        return handle
    end
    handle.pid, handle.fd = pid, read_fd
    local poll_interval = tonumber(options.poll_interval) or 0.1
    local started_at = os.time()

    local function read_pipe()
        if not handle.fd then return nil end
        local fd = handle.fd
        handle.fd = nil
        local ok, value = pcall(ffiutil.readAllFromFD, fd)
        return ok and value or nil
    end
    local function is_done()
        local ok, value = pcall(ffiutil.isSubProcessDone, handle.pid)
        return ok and value == true
    end
    local function terminate()
        if handle.pid and type(ffiutil.terminateSubProcess) == "function" then
            pcall(ffiutil.terminateSubProcess, handle.pid)
        end
    end
    local reap
    reap = function()
        if not handle.pid then return true end
        if not is_done() then
            schedule(scheduler, poll_interval, reap)
            return false
        end
        handle.pid = nil
        read_pipe()
        if type(options.on_reaped) == "function" then pcall(options.on_reaped) end
        return true
    end
    function handle:cancel()
        if self.canceled then return end
        self.canceled = true
        terminate()
        reap()
    end

    local poll
    poll = function()
        if handle.canceled then return reap() end
        if os.difftime(os.time(), started_at) >= (tonumber(options.timeout) or 30) then
            terminate()
            settle(false, nil, "async timeout")
            return reap()
        end
        if not is_done() then
            if not schedule(scheduler, poll_interval, poll) then settle(false, nil, "UI scheduler unavailable") end
            return
        end
        handle.pid = nil
        local decoded = deserialize(read_pipe())
        if type(decoded) ~= "table" then
            settle(false, nil, "malformed subprocess output")
        elseif decoded.ok then
            settle(true, decoded.result)
        else
            settle(false, nil, decoded.error or "subprocess failed")
        end
    end
    if not schedule(scheduler, options.delay or 0, poll) then
        terminate()
        settle(false, nil, "UI scheduler unavailable")
        reap()
    end
    return handle
end

return Async
