-- A UI-thread coordinator for worker-only HTTP-to-file downloads.
-- The parent observes file size, but never reads or serializes image bytes.
local FileTransport = {}

local POLL_SECONDS = 0.25
local MAX_BYTES = 64 * 1048576

local function scheduler_for(transport)
    if transport.file_scheduler then return transport.file_scheduler end
    local ok, scheduler = pcall(require, "ui/uimanager")
    return ok and scheduler or nil
end

local function clock_for(transport)
    if type(transport.file_clock) == "function" then return transport.file_clock end
    if transport.socket and type(transport.socket.gettime) == "function" then
        return transport.socket.gettime
    end
    return os.time
end

local function file_size(transport, path)
    if type(transport.file_size) == "function" then
        local ok, size = pcall(transport.file_size, path)
        return ok and tonumber(size) or 0
    end
    local ok, lfs = pcall(require, "lfs")
    if ok and type(lfs.attributes) == "function" then
        local size = lfs.attributes(path, "size")
        return tonumber(size) or 0
    end
    local file = io.open(path, "rb")
    if not file then return 0 end
    local size = file:seek("end")
    file:close()
    return tonumber(size) or 0
end

local function notify(callback, ...)
    if type(callback) == "function" then pcall(callback, ...) end
end

function FileTransport.request(transport, request, part_path, callbacks)
    request, callbacks = request or {}, callbacks or {}
    local async = transport and transport.async
    local scheduler = transport and scheduler_for(transport)
    local available = async and type(async.run) == "function"
        and scheduler and type(scheduler.scheduleIn) == "function"
    if available and type(async.available) == "function" then
        local ok, result = pcall(async.available)
        available = ok and result == true
    end
    if not available then
        notify(callbacks.on_done, { error = "ui_nonblocking_unavailable" })
        notify(callbacks.on_reaped)
        return { cancel = function() end }
    end

    local clock = clock_for(transport)
    local started = clock()
    local first_byte = false
    local last_progress = started
    local observed = 0
    local canceled, finished, reaped = false, false, false
    local worker_handle
    local setting_up = true
    local buffered_done, buffered_reap
    local connect_timeout = math.min(15, tonumber(request.connect_timeout) or 15)
    local idle_timeout = math.min(30, tonumber(request.idle_timeout) or 30)
    local total_timeout = math.min(180, tonumber(request.total_timeout) or 180)
    local expected = tonumber(request.expected_bytes)
    if expected and expected < 0 then expected = nil end

    local function reap()
        if reaped then return end
        reaped = true
        notify(callbacks.on_reaped)
    end
    local function finish(result)
        if canceled or finished then return end
        finished = true
        local logger = transport.logger
        if result.error and logger and type(logger.warn) == "function" then
            local function token(value)
                value = tostring(value or "unknown")
                return #value <= 32 and value:match("^[%w_%-]+$") and value or "unknown"
            end
            notify(logger.warn, "MangaWeb file download", "site", token(request.site_id),
                "stage", token(request.stage), "status", tonumber(result.status) or 0,
                "error", token(result.error), "cause", token(result.cause or result.error),
                "elapsed_ms", math.max(0, math.floor((clock() - started) * 1000)))
        end
        notify(callbacks.on_done, result)
    end
    local function stop(error_code)
        if canceled or finished then return end
        finish({ error = error_code })
        if worker_handle and type(worker_handle.cancel) == "function" then
            pcall(worker_handle.cancel, worker_handle)
        end
    end

    local function poll()
        if canceled or finished then return end
        local now = clock()
        local size = file_size(transport, part_path)
        if size > observed then
            observed = size
            first_byte = true
            last_progress = now
            notify(callbacks.on_progress, observed, expected)
        end
        if size > MAX_BYTES then
            stop("response_too_large")
        elseif now - started >= total_timeout then
            stop("total_timeout")
        elseif not first_byte and now - started >= connect_timeout then
            -- A distinct TCP connection event is not exposed across the
            -- subprocess boundary; first byte is the stricter deadline.
            stop("first_byte_timeout")
        elseif first_byte and now - last_progress >= idle_timeout then
            stop("idle_timeout")
        end
        if not canceled and not finished then
            local ok, scheduled = pcall(scheduler.scheduleIn, scheduler, POLL_SECONDS, poll)
            if not ok or scheduled == false then stop("ui_scheduler_unavailable") end
        end
    end

    local function completed(ok, result, error_value)
        if setting_up then
            buffered_done = { ok, result, error_value }
            return
        end
        if canceled or finished then return end
        if not ok or type(result) ~= "table" then
            finish({ error = "background_request_failed" })
        else
            finish({ status = result.status, headers = result.headers or {},
                bytes = result.bytes, error = result.error, cause = result.cause,
                path = not result.error and part_path or nil })
        end
        -- Normal Async completion is already reaped. Timeout/failure may
        -- deliver before the child exits; its on_reaped callback owns cleanup.
        if not worker_handle or not worker_handle.pid then reap() end
    end

    local function work()
        local sink = transport.file_sink or require("mangaweb.file_sink")
        local ok, result = pcall(sink.download, request, part_path, {
            client_for = function(url) return transport:_client(url) end,
            open_file = transport.open_file,
            socketutil = transport.socketutil,
            redirect_request = function(current, status, headers)
                return transport:redirect_request(current, status, headers)
            end,
        })
        if not ok or type(result) ~= "table" then return { error = "transport_error" } end
        return result
    end
    local launched, handle = pcall(async.run, work, completed, {
        timeout = total_timeout,
        poll_interval = 0.1,
        on_reaped = function()
            if setting_up then buffered_reap = true else reap() end
        end,
    })
    worker_handle = launched and handle or nil
    setting_up = false
    if buffered_done then completed(buffered_done[1], buffered_done[2], buffered_done[3]) end
    if buffered_reap then reap() end
    if not launched or not worker_handle then
        finish({ error = "background_request_failed" })
        reap()
    end
    if not canceled and not finished then
        local ok, scheduled = pcall(scheduler.scheduleIn, scheduler, POLL_SECONDS, poll)
        if not ok or scheduled == false then stop("ui_scheduler_unavailable") end
    end
    return {
        cancel = function()
            if canceled or reaped then return end
            canceled = true
            if worker_handle and type(worker_handle.cancel) == "function" then
                pcall(worker_handle.cancel, worker_handle)
            else
                reap()
            end
        end,
    }
end

return FileTransport
