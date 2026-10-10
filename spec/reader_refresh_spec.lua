local Settings = require("mangaweb.settings")
local Reader = require("mangaweb.reader")
local fixture = require("spec.helpers.reader_ui")

local function action(adapter, text)
    local panel = assert(adapter.reader_controls)
    for _, row in ipairs(panel.model.rows or {}) do
        for _, item in ipairs(row.items or {}) do
            if item.text == text then return item.callback end
        end
    end
    for _, item in ipairs(panel.model.navigation or {}) do
        if item.text == text then return item.callback end
    end
    error("missing action: " .. text)
end

local function setup()
    package.loaded.pluginloader = {getPluginInstance=function() return nil end}
    local adapter, reader, manager = fixture()
    local saved, storage = {}, {}
    function storage:readSetting(key, fallback)
        local value = saved[key]; if value == nil then return fallback end; return value
    end
    function storage:saveSetting(key, value) saved[key]=value; return true end
    function storage:flush() return not self.fail_flush end
    local settings = Settings:new{store=storage}
    reader.settings = settings
    function reader:settings_snapshot() return settings:reader_settings() end
    function reader:update_settings(changes)
        local values = settings:reader_settings()
        for key, value in pairs(changes) do values[key]=value end
        return settings:save_reader_settings(values)
    end
    local session = {menus=0,changed=0,requests=0}
    function session:attachImage() return true end
    function session:pause() self.paused=true end
    function session:resume() self.paused=false end
    function session:close() self.closed=true end
    function session:settingsChanged()
        if self.fail_changed then error("synthetic service failure") end
        self.changed=self.changed+1
    end
    function session:requestRefresh()
        assert(not self.paused, "manual refresh must first leave settings")
        self.requests=self.requests+1; return true
    end
    function session:showMenu() self.menus=self.menus+1; return true end
    package.loaded.pluginloader = {getPluginInstance=function()
        return {createImageSession=function() return session end}
    end}
    assert(adapter:show_page("/body.jpg",11,178,{}))
    return adapter, reader, manager, settings, storage, session
end

local function owned_interval_and_drafts()
    local adapter, reader, manager, settings, storage, session = setup()
    assert(adapter:_show_graydither_controls())
    assert(session.menus==0 and adapter.reader_controls==adapter.reader_widget.embedded_controls,
        "MangaWeb must own gray/refresh settings inside its reading window")
    assert(action(adapter,"墨水屏刷新")())
    assert(action(adapter,"自动间隔：每 5 页")())
    local first = adapter.reader_controls
    assert(action(adapter,"−1")())
    assert(settings:reader_settings().graydither_refresh_interval==5, "drafts must not save before confirmation")
    assert(action(adapter,"保存")())
    assert(settings:reader_settings().graydither_refresh_interval==4 and session.changed==1)
    assert(action(adapter,"自动间隔：每 4 页")())
    assert(action(adapter,"默认 5")())
    assert(action(adapter,"保存")())
    assert(settings:reader_settings().graydither_refresh_interval==5)
    assert(action(adapter,"自动间隔：每 5 页")())
    assert(action(adapter,"＋5")()); assert(action(adapter,"← 返回")())
    assert(settings:reader_settings().graydither_refresh_interval==5, "cancel must discard numeric drafts")
    assert(first.closed and #manager.stack==1, "adjusting must not add child dialogs to the UI stack")
    assert(pcall(adapter.reader_widget.onGesture,adapter.reader_widget,{ges="multiswipe"}))
    assert(action(adapter,"返回阅读")())
    assert(not reader.closed and not adapter.reader_controls and not session.paused)
end

local function failed_save_and_retired_callbacks()
    local adapter, reader, manager, settings, storage, session = setup()
    assert(adapter:_show_graydither_controls()); assert(action(adapter,"墨水屏刷新")())
    assert(action(adapter,"自动间隔：每 5 页")()); assert(action(adapter,"−1")())
    local old_save=action(adapter,"保存")
    storage.fail_flush=true
    assert(old_save())
    assert(settings:reader_settings().graydither_refresh_interval==5 and session.changed==0)
    assert(adapter.reader_controls.model.status:find("保存失败"))
    storage.fail_flush=false
    assert(action(adapter,"保存")())
    assert(settings:reader_settings().graydither_refresh_interval==4)
    local before=adapter.reader_controls
    assert(old_save()); assert(adapter.reader_controls==before and session.changed==1,
        "a replaced numeric page must never save or reopen settings")
    local old_toggle=action(adapter,"自动全刷：关闭")
    assert(action(adapter,"返回阅读")())
    assert(old_toggle()); assert(not adapter.reader_controls and settings:reader_settings().graydither_refresh_enabled==false)
    assert(adapter:_show_graydither_controls())
    local old_open=action(adapter,"墨水屏刷新")
    assert(adapter:close_reader()); assert(old_open()); assert(not adapter.reader_controls)
end

local function hold_modes_bounds_and_manual_refresh()
    local adapter, reader, manager, settings, storage, session = setup()
    assert(adapter:_show_graydither_controls()); assert(action(adapter,"灰度抖动：关闭")())
    assert(settings:reader_settings().graydither_enabled)
    assert(action(adapter,"墨水屏刷新")()); assert(action(adapter,"自动全刷：关闭")())
    assert(action(adapter,"刷新方式：原生全刷")())
    local values=settings:reader_settings(); values.graydither_refresh_hold=0.10+0.05
    assert(settings:save_reader_settings(values))
    assert(adapter:_show_graydither_controls()); assert(action(adapter,"墨水屏刷新")())
    assert(action(adapter,"黑白各保持：0.15 秒")()); assert(action(adapter,"保存")())
    assert(settings:reader_settings().graydither_refresh_hold==0.10+0.05, "opening/applying must preserve old float values")
    assert(action(adapter,"黑白各保持：0.15 秒")()); assert(action(adapter,"默认 0.30")())
    assert(action(adapter,"保存")()); assert(settings:reader_settings().graydither_refresh_hold==0.30)
    assert(action(adapter,"自动间隔：每 5 页")())
    for _=1,12 do assert(action(adapter,"＋5")()) end
    assert(action(adapter,"保存")()); assert(settings:reader_settings().graydither_refresh_interval==50)
    assert(action(adapter,"自动间隔：每 50 页")())
    for _=1,12 do assert(action(adapter,"−5")()) end
    assert(action(adapter,"保存")()); assert(settings:reader_settings().graydither_refresh_interval==1)
    assert(action(adapter,"立即全刷")())
    assert(session.requests==1 and not adapter.reader_controls and not reader.closed)
end

local function service_errors_keep_host_reading()
    local adapter, reader, manager, settings, storage, session = setup()
    assert(adapter:_show_graydither_controls())
    session.fail_changed=true
    assert(pcall(action(adapter,"灰度抖动：关闭")))
    assert(session.closed and not reader.closed and adapter.reader_widget.image,
        "a service failure must detach the service and preserve the MangaWeb body")
    assert(adapter.reader_controls.model.status:find("不可用"))
    assert(action(adapter,"返回阅读")()); assert(not reader.closed)
end

local function failed_fallback_show_restores_reading()
    for _,register_first in ipairs({false,true}) do
        local adapter, reader, manager, settings, storage, session = setup()
        assert(adapter:_show_graydither_controls())
        local page = adapter.reader_widget
        function page:show_controls() return false end
        local native_show = manager.show
        function manager:show(widget)
            if register_first then native_show(self,widget) end
            error("synthetic Show failure")
        end
        local ok, shown = pcall(adapter._show_graydither_controls,adapter)
        assert(ok and not shown)
        assert(not adapter.reader_controls and not page.external_controls and not page.embedded_controls
            and #manager.stack==1 and manager.stack[1]==page and not session.paused and not reader.closed,
            "a failed fallback Show must retire the incomplete dialog and resume the reading body")
    end
end

local function drawing_settings_do_not_restart_downloads()
    local saved={}
    local settings=Settings:new{store={readSetting=function(_,key,default) return saved[key] or default end,
        saveSetting=function(_,key,value) saved[key]=value;return true end,flush=function()return true end}}
    local requested,canceled,shown=0,0,0
    local loader={begin_session=function()return 1 end,release=function()end,cancel_generation=function()canceled=canceled+1 end,
        request=function(_,_,spec,cb)
            requested=requested+1
            if spec.index==1 then cb.on_ready{path="/first.jpg",metadata={width=600,height=800}} end
            return{cancel=function()canceled=canceled+1 end}
        end}
    local reader=Reader:new{settings=settings,store={save_history=function()return true end},loader=loader,
        ui={show_page=function()shown=shown+1;return true end,show_page_loading=function()return true end,close_reader=function()end}}
    local context={site_id="zero",comic_id="a",chapter_id="c",pages={}}
    for index=1,9 do context.pages[index]={url="https://img/"..index..".jpg"} end
    assert(reader:open(context))
    local count,generation,epoch= requested,reader.generation,reader.processing_epoch
    local current=reader.entries[1]
    assert(reader:update_settings{graydither_enabled=true,graydither_refresh_interval=4})
    assert(reader.entries[1]==current and reader.generation==generation and reader.processing_epoch==epoch
        and requested==count and shown==1 and canceled==0,
        "final drawing/refresh preferences must not restart image processing or page requests")
    reader:close()
end

local failures={}
for _,case in ipairs({owned_interval_and_drafts,failed_save_and_retired_callbacks,
    hold_modes_bounds_and_manual_refresh,service_errors_keep_host_reading,
    failed_fallback_show_restores_reading,drawing_settings_do_not_restart_downloads}) do
    local ok,reason=pcall(case); if not ok then failures[#failures+1]=tostring(reason) end
end
assert(#failures==0,table.concat(failures,"\n"))
print("reader_refresh_spec: 6 scenarios passed")
