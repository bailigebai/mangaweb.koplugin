local ImageLoader = require("mangaweb.image_loader")
local ImageDimensions = require("mangaweb.image_dimensions")

local function file_with(body)
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    assert(file:write(body))
    assert(file:close())
    return path
end

local jpeg = file_with("\255\216\255\192\0\17\8\7\199\5\120\3\1\17\0\2\17\0\3\17\0\255\217")
local png = file_with("\137PNG\r\n\26\n")
local broken_jpeg = file_with("\255\216\255\192\0\1")
assert(ImageDimensions.from_file(broken_jpeg) == nil,
    "a truncated JPEG header must not be treated as a decoded page")
local temp_files = {
    new_session = function() return {} end,
    remove_session = function() return true end,
    remove = function() return true end,
}

local function loader_for(path, renderer)
    return ImageLoader:new{
        http = { get_file = function() error("a cached image must not download again") end },
        temp_files = temp_files,
        page_cache = {
            pin = function() return true end,
            get = function() return path end,
            unpin = function() return true end,
        },
        render_image = renderer,
    }
end

local decoded = 0
local reader = loader_for(jpeg, { renderImageFile = function()
    decoded = decoded + 1
    return nil
end })
local ready, failure
reader:request(reader:begin_session("reader"), {
    key = "1:0", url = "https://example.test/1.jpg", stage = "image", site_id = "zero",
    cache_identity = { site_id = "zero", comic_id = "comic", chapter_id = "chapter",
        index = 1, url = "https://example.test/1.jpg" },
}, {
    on_ready = function(result) ready = result; return true end,
    on_error = function(err) failure = err end,
})
assert(ready and ready.path == jpeg, "a cached JPEG must reach the reader")
assert(ready.metadata.width == 1400 and ready.metadata.height == 1991,
    "the reader needs source dimensions for split-page settings")
assert(decoded == 0 and not failure, "the loader must not decode JPEG a second time")

local downloaded = os.tmpname() .. ".part"
local transfer = ImageLoader:new{
    temp_files = temp_files,
    page_cache = {
        pin = function() return true end,
        get = function() return nil end,
        reserve = function() return downloaded end,
        publish = function(_, _, part, bytes)
            assert(part == downloaded and bytes == 23)
            return jpeg
        end,
        discard = function() os.remove(downloaded) end,
        unpin = function() return true end,
    },
    render_image = { renderImageFile = function() error("the JPEG must not be decoded twice") end },
    http = { get_file = function(_, _, options, callbacks)
        assert(options.path == downloaded)
        local source = assert(io.open(jpeg, "rb"))
        local body = source:read("*a")
        source:close()
        local part = assert(io.open(downloaded, "wb"))
        assert(part:write(body))
        assert(part:close())
        callbacks.on_success(downloaded, { bytes = #body })
        callbacks.on_reaped()
        return { cancel = function() end }
    end },
}
local transferred
transfer:request(transfer:begin_session("reader"), {
    key = "download:1", url = "https://example.test/download.jpg", stage = "image",
    site_id = "zero", cache_identity = { site_id = "zero", comic_id = "comic",
        chapter_id = "chapter", index = 1, url = "https://example.test/download.jpg" },
}, { on_ready = function(result) transferred = result; return true end })
assert(transferred and transferred.path == jpeg and transferred.metadata.width == 1400,
    "a newly downloaded JPEG must pass through publish and reach the reader")
os.remove(downloaded)

local fallback = loader_for(png, { renderImageFile = function()
    decoded = decoded + 1
    return { width = 4, height = 8, free = function() end }
end })
local fallback_ready
fallback:request(fallback:begin_session("reader"), {
    key = "2:0", url = "https://example.test/2.png", stage = "image", site_id = "zero",
    cache_identity = { site_id = "zero", comic_id = "comic", chapter_id = "chapter",
        index = 2, url = "https://example.test/2.png" },
}, { on_ready = function(result) fallback_ready = result; return true end })
assert(fallback_ready and fallback_ready.metadata.width == 4 and decoded == 1,
    "unknown image dimensions must retain the existing renderer fallback")

local broken = loader_for(png, setmetatable({}, {
    __index = function() error("renderer unavailable") end,
}))
local broken_error
local ok = pcall(function()
    broken:request(broken:begin_session("reader"), {
        key = "3:0", url = "https://example.test/3.png", stage = "image", site_id = "zero",
        cache_identity = { site_id = "zero", comic_id = "comic", chapter_id = "chapter",
            index = 3, url = "https://example.test/3.png" },
    }, { on_error = function(err) broken_error = err end })
end)
assert(ok and broken_error and broken_error.code == "image_error",
    "a renderer exception must end loading with a retryable error")

os.remove(jpeg)
os.remove(png)
os.remove(broken_jpeg)
print("image_loader_first_page_spec: passed")
