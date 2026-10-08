local Reader = require("mangaweb.reader")

local scheduler = { pending = {} }
function scheduler:scheduleIn(_, callback)
    self.pending[#self.pending + 1] = callback
    return true
end
function scheduler:unschedule(callback)
    for index, value in ipairs(self.pending) do
        if value == callback then self.pending[index] = false end
    end
    return true
end
function scheduler:fire_next()
    for index, callback in ipairs(self.pending) do
        if callback then
            self.pending[index] = false
            callback()
            return true
        end
    end
    return false
end

local requests = {}
local loader = {}
function loader:begin_session() return 1 end
function loader:request(_, _, callbacks)
    requests[#requests + 1] = callbacks
    return { cancel = function()
        callbacks.on_error{ code = "transport_error" }
        return true
    end }
end
function loader:release() return true end
function loader:cancel_generation() return true end

local ui = { errors = {}, pages = {}, progress = {} }
function ui:show_page_loading() return true end
function ui:show_download_progress(bytes)
    self.progress[#self.progress + 1] = bytes
    return true
end
function ui:show_error(error)
    self.errors[#self.errors + 1] = error
    return true
end
function ui:show_page(path)
    self.pages[#self.pages + 1] = path
    return true
end
function ui:close_reader() return true end

local store = {}
function store:get_history() return nil end
function store:save_history() return true end

local reader = Reader:new{
    store = store, ui = ui, loader = loader, scheduler = scheduler,
    timeout_seconds = 25,
}
assert(reader:open{
    site_id = "zero", comic_id = "stalled", pages = { { url = "https://img/1.jpg" } },
})
assert(#requests == 1, "the first image request must start")
requests[1].on_progress(24 * 1024)
assert(#ui.progress == 1, "download progress must remain visible")
assert(scheduler:fire_next(), "a stalled image needs its own timeout")
assert(#ui.errors == 1 and ui.errors[1].code == "request_timeout",
    "a stalled first image must show a retryable timeout")
requests[1].on_ready{ path = "/tmp/late.jpg", metadata = { width = 600, height = 800 } }
assert(#ui.pages == 0, "a late completion must not replace the timeout screen")

assert(reader:retry(), "the timeout screen must allow a new image request")
assert(#requests == 2)
local old_timer = scheduler.pending[#scheduler.pending]
requests[2].on_progress(32 * 1024)
old_timer()
assert(#ui.errors == 1, "recent progress must reset the idle deadline")
requests[2].on_ready{ path = "/tmp/ready.jpg", metadata = { width = 600, height = 800 } }
assert(#ui.pages == 1 and ui.pages[1] == "/tmp/ready.jpg",
    "a retried image must display successfully")
assert(not scheduler:fire_next(), "displaying the image must cancel the watchdog")

reader:close("back")
scheduler.pending, requests = {}, {}
local promoted = Reader:new{
    store = store, ui = ui, loader = loader, scheduler = scheduler,
    timeout_seconds = 25,
}
assert(promoted:open{
    site_id = "zero", comic_id = "prefetch", pages = {
        { url = "https://img/1.jpg" }, { url = "https://img/2.jpg" },
    },
})
requests[1].on_ready{ path = "/tmp/first.jpg", metadata = { width = 600, height = 800 } }
assert(#requests == 2, "displaying page one must prefetch page two")
assert(promoted:go_to(2), "the prefetched request can become the target page")
local promoted_timer = scheduler.pending[#scheduler.pending]
local errors_before_progress = #ui.errors
requests[2].on_progress(16 * 1024)
promoted_timer()
assert(#ui.errors == errors_before_progress,
    "new bytes from a promoted prefetch must reset the target-page timeout")

print("reader_loading_spec: passed")
