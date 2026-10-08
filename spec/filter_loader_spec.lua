local Loader=require("mangaweb.image_loader")
local removed,processed,downloaded={},0,0
local loader=Loader:new{
    http={get_file=function()downloaded=downloaded+1;error("preview must not download")end},
    temp_files={new_session=function()return{}end,path=function()return "/preview.png"end,
        track=function(_,_,path)return path end,remove=function(_,path)removed[path]=true end,
        remove_session=function()end},
    page_processor={process=function(source,output,profile)
        processed=processed+1;assert(source=="/reader-owned.jpg" and output=="/preview.png")
        return{width=1272,height=1696,source_width=1400,source_height=1991}
    end},
    async={available=function()return true end,run=function(work,done)
        done(true,work());return{cancel=function()end}
    end},
}
local generation=loader:begin_session("reader")
local ready,error_value
local handle=loader:request(generation,{key="preview",url="https://image.test/1.jpg",stage="image",
    source_path="/reader-owned.jpg",profile={target_width=1272,target_height=1696}},
    {on_ready=function(result)ready=result end,on_error=function(reason)error_value=reason end})
assert(ready and ready.path=="/preview.png" and processed==1 and downloaded==0 and not error_value,
    "preview processing must borrow the current source without another HTTP request")
handle:cancel();loader:release(generation,"preview")
assert(removed["/preview.png"] and not removed["/reader-owned.jpg"],
    "releasing a preview must remove only its derivative")
assert(loader.active_count==0)

-- The cache may be unwritable. A new processing epoch must take over the
-- temporary source instead of retaining every old epoch until reader close.
local Reader = require("mangaweb.reader")
local Settings = require("mangaweb.settings")
local files, downloads, pins = {}, 0, 0
local temporary = {
    new_session = function() return {} end,
    remove_session = function() end,
    reserve = function(_, _, name) return "/temp/" .. name .. ".part" end,
    publish = function(_, _, part)
        local path = part:gsub("%.part$", ".jpg")
        files[path] = true
        return path
    end,
    path = function(_, _, name, extension) return "/temp/" .. name .. "." .. extension end,
    track = function(_, _, path) return path end,
    discard = function() end,
    remove = function(_, path) files[path] = nil end,
}
local active_loader = Loader:new{
    http = {get_file = function(_, _, options, handlers)
        downloads = downloads + 1
        handlers.on_success(options.path, {bytes=1})
        handlers.on_reaped()
        return {cancel=function() end}
    end},
    temp_files = temporary,
    page_cache = {pin=function() pins=pins+1;return true end,
        unpin=function() pins=pins-1 end, get=function() end, reserve=function() end},
    render_image = {renderImageFile=function(_, path)
        assert(files[path], "a removed source must not be decoded")
        return {getWidth=function()return 1400 end,getHeight=function()return 1991 end,free=function()end}
    end},
    page_processor = {process=function(source, output)
        assert(files[source], "the active processing source must stay alive")
        files[output]=true
        return {width=1192,height=1696,source_width=1400,source_height=1991}
    end},
    async = {available=function()return true end,run=function(work,done)
        done(true,work());return {cancel=function()end}
    end},
}
local saved = {}
local settings = Settings:new{store={
    readSetting=function(_,key,fallback)return saved[key] or fallback end,
    saveSetting=function(_,key,value)saved[key]=value;return true end,
    flush=function()return true end,
}}
local config=settings:reader_settings()
config.preload_pages=0
assert(settings:save_reader_settings(config))
local active_reader = Reader:new{store={save_history=function()return true end},settings=settings,loader=active_loader,ui={
    content_width=1272,content_height=1696,show_page_loading=function()return true end,
    show_page=function(_,path)assert(files[path]);return true end,
}}
assert(active_reader:open{site_id="zero",comic_id="x",pages={
    {url="https://image.test/1.jpg"},{url="https://image.test/2.jpg"},{url="https://image.test/3.jpg"},
}})
local first_source=active_reader.entries[1].raw_path
for _,preset in ipairs({"clear","strong","clear"}) do
    assert(active_reader:update_settings{gray_enabled=true,gray_preset=preset})
    assert(files[first_source] and downloads==1)
end
assert(active_reader:go_to(3))
assert(not files[first_source], "an evicted page must release its temporary original after repeated filter changes")
active_reader:close()
assert(pins==0, "all processing and retained cache pins must be released")
print("filter_loader_spec: passed")
