local Presets = require("mangaweb.filter_presets")
local Settings = require("mangaweb.settings")
local Processor = require("mangaweb.page_processor")
local Reader = require("mangaweb.reader")
local Adapter = require("mangaweb.ui.koreader")
local Gray = require("mangaweb.gray_enhance")
local Tone = require("mangaweb.tone_adjust")

local values = {}
local storage = {
    readSetting = function(_, key, fallback) return values[key] or fallback end,
    saveSetting = function(_, key, value) values[key] = value; return true end,
    flush = function() return true end,
}
local settings = Settings:new{ store = storage }
for _, kind in ipairs({ "gray", "tone" }) do
    local all = Presets.all(kind)
    assert(#all == 3 and all[1].name == "原图" and all[2].name == "清晰" and all[3].name == "强力")
end
local custom = assert(Presets.normalize("gray", {name="测试",black=0,white=255,gamma=0.1}, "custom-1"))
assert(Presets.normalize("gray", {name="测试",black=254,white=255,gamma=5}, "custom-2"))
for _, invalid in ipairs({
    {black=-1,white=255,gamma=1}, {black=0,white=256,gamma=1},
    {black=20,white=20,gamma=1}, {black=0.5,white=200,gamma=1},
    {black=0,white=255,gamma=0.09}, {black=0,white=255,gamma=5.01},
    {black=0,white=255,gamma=0/0},
}) do
    invalid.name = "错误"
    assert(not Presets.normalize("gray", invalid, "custom-3"), "invalid gray parameters must fail")
end
assert(Presets.normalize("tone", {name="范围",brightness=-100,contrast=0}, "custom-1"))
assert(Presets.normalize("tone", {name="范围",brightness=100,contrast=200}, "custom-1"))
assert(not Presets.normalize("tone", {name="错误",brightness=101,contrast=100}, "custom-1"))
assert(not Presets.normalize("tone", {name="错误",brightness=0,contrast=math.huge}, "custom-1"))
local config = settings:reader_settings()
config.gray_custom_presets, config.gray_preset = {custom}, custom.id
assert(settings:save_reader_settings(config))
local read = settings:reader_settings()
assert(read.gray_preset == "custom-1" and read.gray_custom_presets[1].gamma == 0.1)
read.gray_custom_presets[1].black = 200
assert(settings:reader_settings().gray_custom_presets[1].black == 0, "reading a preset list must not mutate saved values")
local invalid = settings:reader_settings()
invalid.gray_custom_presets[2] = custom
assert(not settings:save_reader_settings(invalid), "duplicate preset IDs must fail before saving")
assert(Gray.find("custom-1", {custom}).gamma == 0.1)
assert(Tone.find("clear").contrast == 120)

local neutral = {gray_enabled=true,gray_preset="original",tone_enabled=true,tone_preset="original"}
assert(Processor.profile({width=1400,height=1991}, neutral,1272,1696) == nil,
    "original must bypass processing, including resizing")
local config = {gray_enabled=true,gray_preset="clear",fit_mode="page"}
local adapter = Adapter:new{ screen={getWidth=function()return 1272 end,getHeight=function()return 1696 end} }
local reader = Reader:new{store={},ui=adapter}
reader.reader_settings = config
local profile = reader:_profile({}, {width=1400,height=1991})
assert(profile.target_height == 1696 and profile.target_width > 1100,
    "Kindle processing must use the real screen, not 600x800")
local requested, freed, rendered = {},0,0
local output
local fake = {renderImageFile=function(_,_,_,w,h)
    rendered=rendered+1; requested[#requested+1]={w=w,h=h}
    return {getWidth=function()return w or 1400 end,getHeight=function()return h or 1991 end,
        free=function()freed=freed+1 end,writePNG=function()output=true;return true end}
end}
local deferred = assert(Processor.profile({},config,1272,1696), "unknown source dimensions must defer, not skip the filter")
local metadata = assert(Processor.process("/source.jpg","/result.png",deferred,
    {renderer=fake,lut_applier=function()return true end}))
assert(output and metadata.width > 1100 and metadata.height == 1696)
assert(metadata.source_width == 1400 and metadata.source_height == 1991,
    "processed metadata must preserve source dimensions for future edits")
assert(freed == rendered, "both dimension probes and processed buffers must be freed")
local last_request
local current = settings:reader_settings()
current.preload_pages=0
assert(settings:save_reader_settings(current))
local updating=Reader:new{store={save_history=function()return true end},settings=settings,
    ui={content_width=1272,content_height=1696,show_page_loading=function()return true end,show_page=function()return true end},
    loader={cancel_processing=function()end,release=function()end,request=function(_,_,spec,callbacks)
        last_request=spec
        callbacks.on_ready{path="/new.png",cached_raw=spec.source_path,
            metadata={width=1192,height=1696,source_width=1400,source_height=1991}}
        return{cancel=function()end}
    end}}
updating.closed=false;updating.position=1;updating.target=1
updating.context={site_id="zero",comic_id="x",pages={{url="https://image.test/1.jpg"}}}
updating.entries[1]={path="/old-processed.png",raw_path="/original.jpg",key="1:0",ready=true}
updating.page_metadata[1]={width=1400,height=1991}
for _,preset in ipairs({"clear","strong","clear"})do
    assert(updating:update_settings{gray_enabled=true,gray_preset=preset})
    assert(last_request.source_path=="/original.jpg" and last_request.profile.target_height==1696,
        "every setting change must reuse the original source and its dimensions")
end
print("filter_processing_spec: passed")
