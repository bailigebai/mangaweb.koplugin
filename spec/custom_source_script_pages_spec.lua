local Custom = require("mangaweb.sources.custom")

local rules = {
    list_path = "/albums-index-page-{page}.html",
    list_block = '(<div class="pic_box">.-</div>)',
    list_href = 'href="(.-)"', list_title = 'title="(.-)"',
    list_cover = 'src="(.-)"',
    detail_title = 'id="comicName"[^>]*>(.-)</',
    detail_cover = 'id="Cover".-src="(.-)"',
    comic_id_pattern = 'photos%-index%-aid%-(%d+)',
    reader_path = "/photos-item-aid-{id}.html",
    page_block = 'page_url.-%[(.-)%]',
    page_image = '["\']([^"\']+)["\']',
}
local responses = {
    ["https://www.wnacg.com/albums-index-page-1.html"] =
        '<div class="pic_box"><a href="/photos-index-aid-42.html" title="漫画">'
        .. '<img src="/cover/42.jpg"></a></div>',
    ["https://www.wnacg.com/photos-index-aid-42.html"] =
        '<h1 id="comicName">漫画</h1><div id="Cover"><img src="/cover/42.jpg"></div>',
    ["https://www.wnacg.com/photos-item-aid-42.html"] =
        '<script>var x={"page_url":["https:\\/\\/img.example.com\\/1.jpg",'
        .. '"https:\\/\\/img.example.com\\/2.jpg"]};</script>',
}
local requests = {}
local http = { get = function(_, url, _, callbacks)
    requests[#requests + 1] = url
    if responses[url] then return callbacks.on_success(responses[url], { status = 200 }) end
    return callbacks.on_error{ code = "http_error", status = 404 }
end }
local source = Custom:new{ definition = { id = "custom-1", name = "手动站点",
    origin = "https://www.wnacg.com", rules = rules }, http = http }
local listing
source:list({ page = 1 }, {
    on_success = function(value) listing = value.cards end,
    on_error = function(value) assert(false, value.code) end,
})
assert(listing and listing[1].comic_id == "https://www.wnacg.com/photos-index-aid-42.html")
local detail
source:detail(listing[1].comic_id, {
    on_success = function(value) detail = value end,
    on_error = function(value) assert(false, value.code) end,
})
assert(detail.chapters[1].id == listing[1].comic_id,
    "sites without chapter links use the gallery as one chapter")
local pages
source:pages(listing[1].comic_id, detail.chapters[1].id, {
    on_success = function(value) pages = value.pages end,
    on_error = function(value) assert(false, value.code) end,
})
assert(requests[3] == "https://www.wnacg.com/photos-item-aid-42.html"
    and #pages == 2 and pages[1].url == "https://img.example.com/1.jpg",
    "editable reader-path and script-array rules must resolve image pages")

print("custom_source_script_pages_spec: passed")
