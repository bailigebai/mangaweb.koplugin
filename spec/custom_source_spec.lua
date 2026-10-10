local Custom = require("mangaweb.sources.custom")

local rules = {
    list_path = "/albums?page={page}", search_path = "/search?q={query}&page={page}",
    list_block = "(<article.-</article>)", list_href = 'href="(.-)"',
    list_title = 'title="(.-)"', list_cover = 'src="(.-)"',
    detail_title = "<h1>(.-)</h1>", detail_cover = 'src="(.-)"',
    detail_description = "<p>(.-)</p>",
    chapter_block = "(<a.-</a>)", chapter_href = 'href="(.-)"',
    chapter_title = ">(.-)</a>", page_image = 'src="(.-)"',
}
local requested = {}
local responses = {
    ["https://example.com/albums?page=2"] = '<article><a href="/book/1" title="漫画一"><img src="/cover/1.jpg"></a></article>',
    ["https://example.com/search?q=A%20B&page=1"] = '<article><a href="/book/2" title="搜索结果"><img src="/cover/2.jpg"></a></article>',
    ["https://example.com/book/1"] = '<h1>漫画一</h1><img src="/cover/1.jpg"><p>简介</p><a href="/read/1">第一话</a>',
    ["https://example.com/read/1"] = '<img src="https://cdn.example.com/1.jpg"><img src="/pages/2.jpg">',
}
local http = {}
function http:get(url, options, callbacks)
    requested[#requested + 1] = { url = url, options = options }
    local body = responses[url]
    if body then return callbacks.on_success(body, { status = 200, headers = {} }) end
    return callbacks.on_error{ code = "http_error", status = 404 }
end
local auth = { headers = function(_, _, url)
    return url:find("https://example.com", 1, true) == 1
        and { Cookie = "session=local" } or {}
end }
local source = Custom:new{ definition = {
    id = "custom-1", name = "样本站", origin = "https://example.com", rules = rules,
}, http = http, auth = auth }
local listing
source:list({ page = 2 }, { on_success = function(value) listing = value end,
    on_error = function(value) assert(false, value.code) end })
assert(listing.cards[1].comic_id == "https://example.com/book/1"
    and listing.cards[1].cover_url == "https://example.com/cover/1.jpg")
assert(listing.cards[1].site_id == "custom-1")
local result
source:detail(listing.cards[1].comic_id, {
    on_success = function(value) result = value end,
    on_error = function(value) error(value.code) end,
})
assert(result.card.title == "漫画一" and result.description == "简介")
assert(#result.chapters == 1 and result.chapters[1].id == "https://example.com/read/1")
local pages
source:pages(listing.cards[1].comic_id, result.chapters[1].id, {
    on_success = function(value) pages = value.pages end,
    on_error = function(value) error(value.code) end,
})
assert(#pages == 2 and pages[1].url == "https://cdn.example.com/1.jpg"
    and pages[2].url == "https://example.com/pages/2.jpg")
assert(pages[1].headers.Cookie == nil and pages[2].headers.Cookie == "session=local",
    "custom-site Cookie must stay on its configured host")
local searched
source:list({ page = 1, query = "A B" }, {
    on_success = function(value) searched = value.cards end,
    on_error = function(value) error(value.code) end,
})
assert(searched[1].title == "搜索结果", "the query placeholder must be URL encoded")

responses["https://example.com/albums?page=1"] =
    '<article><a href="https://other.example.com/book/9" title="外站"><img src="/cover/9.jpg"></a></article>'
local unsafe
source:list({ page = 1 }, {
    on_success = function() error("cross-origin HTML link was accepted") end,
    on_error = function(value) unsafe = value end,
})
assert(unsafe.code == "parse_error", "HTML pages must stay on the configured domain")

print("custom_source_spec: passed")
