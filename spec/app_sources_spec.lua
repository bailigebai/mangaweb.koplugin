local App = require("mangaweb.app")
local definitions = { list = function() return {
    { id = "custom-1", name = "自定义", origin = "https://example.com", rules = {
        list_path = "/list?page={page}", list_block = "(<article.-</article>)",
        list_href = 'href="(.-)"', list_title = 'title="(.-)"',
        list_cover = 'src="(.-)"', detail_title = "<h1>(.-)</h1>",
        detail_cover = 'src="(.-)"', page_image = 'src="(.-)"',
    } },
} end, zero_origin = function() return "https://zero.example.com" end }
local sources = App.build_sources{ definitions = definitions, auth = {}, http = {} }
assert(sources.zero and sources.zero.origin == "https://zero.example.com")
assert(sources["custom-1"] and sources["custom-1"]:meta().name == "自定义")
assert(sources.nhentai == nil and sources.wnacg == nil,
    "the normal site list must contain only Zero and user-created sites")

local runtime_ui, reader_loader = {}, { max_active = 2 }
local app=App:new{source_registry={},http={},temp_files={new_session=function()return{}end},
    loader=reader_loader,ui=runtime_ui}
assert(runtime_ui.loader==reader_loader and runtime_ui.cover_loader==app.cover_loader)
assert(app.cover_loader and app.cover_loader.loader.max_active==6,
    "the application must inject a separate cover pool without changing the reader pool")

print("app_sources_spec: passed")
