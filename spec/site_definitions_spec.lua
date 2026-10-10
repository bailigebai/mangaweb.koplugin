local Definitions = require("mangaweb.site_definitions")

local data, fail_flush, fail_write = {}, false, false
local settings = {}
function settings:read(key, fallback) return data[key] or fallback end
function settings:write(key, value) data[key] = value; return not fail_write end
function settings:flush() return not fail_flush end

local rules = {
    list_path = "/albums?page={page}", search_path = "/search?q={query}&page={page}",
    list_block = "(<article.-</article>)", list_href = 'href="(.-)"',
    list_title = 'title="(.-)"', list_cover = 'src="(.-)"',
    detail_title = "<h1>(.-)</h1>", detail_cover = 'src="(.-)"',
    chapter_block = "(<a.-</a>)", chapter_href = 'href="(.-)"',
    chapter_title = ">(.-)</a>", page_image = 'src="(.-)"',
}
local definitions = Definitions:new{ settings = settings }
assert(definitions:zero_origin() == "https://www.zerobyw33.com")
local created = assert(definitions:add{
    name = "样本站", origin = "HTTPS://Example.com/", rules = rules,
})
assert(created.id == "custom-1" and created.origin == "https://example.com")
assert(#definitions:list() == 1)
local reloaded = Definitions:new{ settings = settings }
assert(reloaded:list()[1].id == "custom-1", "custom sites must survive restart")
assert(reloaded:update("custom-1", {
    name = "改名", origin = "https://reader.example.com", rules = rules,
}).name == "改名")
assert(reloaded:list()[1].origin == "https://reader.example.com")
assert(reloaded:set_zero_origin("https://zero.example.com"))
assert(Definitions:new{ settings = settings }:zero_origin() == "https://zero.example.com")

local malformed = {}
for key, value in pairs(rules) do malformed[key] = value end
malformed.page_image = "["
assert(reloaded:add{ name = "坏规则", origin = "https://bad.example.com", rules = malformed } == nil,
    "invalid patterns must be rejected before save")
assert(reloaded:add{ name = "危险地址", origin = "http://example.com", rules = rules } == nil)
assert(reloaded:add{ name = "同源地址", origin = "https://user@example.com", rules = rules } == nil)
assert(#reloaded:list() == 1, "invalid drafts must not be persisted")

fail_flush = true
assert(reloaded:update("custom-1", {
    name = "未保存", origin = "https://reader.example.com", rules = rules,
}) == nil, "a failed flush must reject the update")
assert(reloaded:list()[1].name == "改名", "a failed flush must restore the previous site")
fail_flush = false
fail_write = true
assert(reloaded:set_zero_origin("https://unsaved.example.com") == false)
assert(reloaded:zero_origin() == "https://zero.example.com"
    and Definitions:new{ settings = settings }:zero_origin() == "https://zero.example.com",
    "a rejected settings write must restore the previous value")
fail_write = false
assert(reloaded:remove("custom-1"))
assert(#reloaded:list() == 0)
local next_site = assert(reloaded:add{
    name = "新站", origin = "https://new.example.com", rules = rules,
})
assert(next_site.id == "custom-2", "removed IDs must never be reused")

print("site_definitions_spec: passed")
