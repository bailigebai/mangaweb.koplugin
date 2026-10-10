-- Real shared Session + source adapter/shell + hash-pinned ImageWidget/BB.
-- Only file decoding and physical e-ink/UI scheduling are synthetic.
local Native = require("imagewidget_test_support")
local Scheduler = require("refresh_test_support")
local UI, scheduler_screen = Scheduler.reset()
package.loaded["ui/uimanager"] = UI
package.preload["ui/widget/buttondialog"] = function() return Scheduler.Widget end
package.preload["document/documentregistry"] = function()
    return {isImageFile=function() return true end}
end
require("util").getFileNameSuffix = function(path) return path:match("%.([^%.]+)$") end
local Session = require("graydither.imagesession")
local Settings = require("mangaweb.settings")
local fixture = require("spec.helpers.reader_ui")
local BB = Native.BB

local function setup(existing_reader)
    package.loaded.pluginloader={getPluginInstance=function() return nil end}
    local adapter,reader,old_manager=fixture()
    local page=adapter.reader_widget
    UI,scheduler_screen=Scheduler.reset(page)
    old_manager.stack=UI.stack
    Native.reset();Native.screen.width,Native.screen.height=2,2
    scheduler_screen.width,scheduler_screen.height=2,2
    page.width,page.height=2,2
    adapter.ui_manager=UI
    -- The source's container tree remains real; simple layout containers only
    -- route paintTo to the actual native ImageWidget reached in that tree.
    function adapter.input_container:paintTo(target,x,y)
        local function paint(child)
            if child==self.image then child:paintTo(target,x,y)
            elseif type(child)=="table" then
                for _,grandchild in ipairs(child) do paint(grandchild) end
            end
        end
        paint(self[1])
    end
    local saved,store={},{}
    function store:readSetting(key,default)
        local value=saved[key];return value==nil and default or value
    end
    function store:saveSetting(key,value) saved[key]=value;return true end
    function store:flush() return not self.fail_flush end
    local settings=Settings:new{store=store}
    if existing_reader then
        local old=settings:reader_settings()
        for key in pairs(old) do
            if key:match("^graydither_") then old[key]=nil end
        end
        old.preload_pages=4
        saved.reader=old
    end
    reader.settings=settings
    function reader:settings_snapshot() return settings:reader_settings() end
    function reader:update_settings(changes)
        local values=settings:reader_settings()
        for key,value in pairs(changes) do values[key]=value end
        return settings:save_reader_settings(values)
    end
    G_reader_settings=Scheduler.store{graydither_enabled=true,graydither_refresh_enabled=true}
    local session
    package.loaded.pluginloader={getPluginInstance=function(_,name)
        assert(name=="graydither")
        return {createImageSession=function(_,options)
            session=Session.new(options);return session
        end}
    end}
    local raw=Native.image(2,2,nil,{8,9,128,246})
    require("ui/renderimage").renderImageFile=function() return raw:copy() end
    adapter.image_widget=Native.ImageWidget
    assert(adapter:show_page("/synthetic-native.png",11,178,{}))
    assert(session and session.owner==page)
    local target=BB.new(2,2)
    local function paint(index,options)
        if index then assert(adapter:show_page("/synthetic-native.png",index,178,options or {})) end
        target:fill(BB.COLOR_WHITE)
        page:paintTo(target,0,0)
        return target
    end
    local function cleanup()
        adapter:close_reader();raw:free();target:free()
    end
    return adapter,reader,page,session,store,settings,paint,cleanup,raw
end

test("source and real session default off ignore global true and failed save",function()
    local adapter,reader,page,session,store,settings,paint,cleanup=setup()
    eq(session.preferences:isEnabled(),false);eq(session.refresh_preferences:getEnabled(),false)
    local image=paint()
    for i,value in ipairs({8,9,128,246}) do
        eq(image:getPixel((i-1)%2,math.floor((i-1)/2)).a,value)
    end
    eq(session.refresher.count,0)
    store.fail_flush=true
    session:getMenuItems()[1].callback()
    eq(session.preferences:isEnabled(),false);eq(settings:reader_settings().graydither_enabled,false)
    assert(session.last_error,"failed source persistence must reach the shared menu's guarded error path")
    store.fail_flush=false
    session:getMenuItems()[1].callback()
    eq(session.preferences:isEnabled(),true);eq(settings:reader_settings().graydither_enabled,true)
    cleanup()
end)

test("MangaWeb embedded controls notify real session without external dialogs",function()
    local adapter,reader,page,session,store,settings,paint,cleanup=setup()
    local function choose(text)
        local model=assert(adapter.reader_controls).model
        for _,row in ipairs(model.rows or {})do
            for _,item in ipairs(row.items or {})do
                if item.text==text then return item.callback() end
            end
        end
        for _,item in ipairs(model.navigation or {})do
            if item.text==text then return item.callback() end
        end
        error("missing action: "..text)
    end
    assert(adapter:_show_graydither_controls())
    eq(session.menu,nil);eq(page.embedded_controls,adapter.reader_controls);eq(session.paused,true)
    assert(choose("灰度抖动：关闭"));eq(settings:reader_settings().graydither_enabled,true)
    assert(choose("墨水屏刷新"));assert(choose("自动全刷：关闭"))
    assert(choose("自动间隔：每 5 页"));assert(choose("−1"));assert(choose("保存"))
    eq(session.refresh_preferences:getInterval(),4);eq(session.refresh_preferences:getEnabled(),true)
    eq(session.menu,nil);eq(next(session.widgets),nil)
    assert(choose("返回阅读"));eq(session.paused,false)
    local image=paint()
    for i,value in ipairs({0,17,136,238})do eq(image:getPixel((i-1)%2,math.floor((i-1)/2)).a,value) end
    assert(adapter:_show_graydither_controls());assert(choose("墨水屏刷新"));assert(choose("立即全刷"))
    eq(page.embedded_controls,nil);UI:advance(0);eq(session.refresher.completed,1)
    assert(adapter:_show_graydither_controls());assert(choose("墨水屏刷新"))
    UI.currently_scrolling=true
    assert(choose("立即全刷"));eq(session.closed,false)
    assert(page.graydither_bridge:isAvailable(), "a deferred refresh must keep the healthy image service")
    assert(adapter.reader_controls.model.status:find("刷新未完成"))
    UI.currently_scrolling=false
    assert(choose("立即全刷"));UI:advance(0);eq(session.refresher.completed,2)
    cleanup()
end)

test("existing source preferences upgrade to explicit false and real toggles persist independently",function()
    local adapter,reader,page,session,store,settings,paint,cleanup=setup(true)
    local upgraded=settings:reader_settings()
    eq(upgraded.graydither_enabled,false);eq(upgraded.graydither_refresh_enabled,false)
    upgraded.preload_pages=5
    assert(settings:save_reader_settings(upgraded))
    session:getMenuItems()[1].callback()
    eq(settings:reader_settings().graydither_enabled,true)
    eq(settings:reader_settings().graydither_refresh_enabled,false)
    session.refresh_preferences:setEnabled(true)
    session:settingsChanged()
    session:getMenuItems()[1].callback()
    local reopened=Settings:new{store=store}:reader_settings()
    eq(reopened.preload_pages,5)
    eq(reopened.graydither_enabled,false);eq(reopened.graydither_refresh_enabled,true)
    session.refresh_preferences:setEnabled(false)
    session:settingsChanged()
    eq(settings:reader_settings().graydither_enabled,false)
    eq(settings:reader_settings().graydither_refresh_enabled,false)
    cleanup()
end)

test("source native body emits FS pixels and counts only actual successful logical screens",function()
    local adapter,reader,page,session,store,settings,paint,cleanup,raw=setup()
    local raw_before=BB.tostring(raw)
    session.preferences:setGlobal(true)
    session.refresh_preferences:setEnabled(true)
    session.refresh_preferences:setInterval(2)
    session:settingsChanged()
    eq(session.refresher.count,0)
    local image=paint()
    for i,value in ipairs({0,17,136,238}) do
        local actual=image:getPixel((i-1)%2,math.floor((i-1)/2)).a
        eq(actual,value);eq(actual%17,0)
    end
    eq(session.refresher.count,0)
    local ordinal=session.ordinal
    paint(11);eq(session.ordinal,ordinal);eq(session.refresher.count,0)
    assert(adapter:show_page_loading(12,178))
    eq(session.paused,true);eq(session.preserve_progress,true)
    paint(12);eq(session.refresher.count,1)
    paint(12);eq(session.refresher.count,1)
    -- Attaching an image or updating its model is not itself a displayed page.
    assert(adapter:show_page("/synthetic-native.png",13,178,{segment="right",pan_y=32}))
    eq(session.refresher.count,1)
    paint();eq(session.refresher.count,2);eq(#UI.tasks,1)
    UI:advance(0);eq(session.refresher.completed,1)
    eq(BB.tostring(raw),raw_before,"the downloaded/borrowed original must not change")
    cleanup()
end)

test("source embedded settings and close cancel real flash phases and pending page updates",function()
    local adapter,reader,page,session,store,settings,paint,cleanup=setup()
    session.refresh_preferences:setEnabled(true)
    session.refresh_preferences:setInterval(1)
    session.refresh_preferences:setMode("flash")
    session.refresh_preferences:setHold(0.1)
    session:settingsChanged();paint(11);paint(12)
    eq(#UI.tasks,1);UI:advance(0);assert(session.refresher.layer)
    assert(adapter:_show_reader_controls())
    eq(session.paused,true);eq(session.refresher.layer,nil);eq(#UI.tasks,0)
    assert(adapter:show_page("/synthetic-native.png",13,178,{}))
    paint();eq(session.ordinal,0);eq(session.refresher.count,0)
    assert(adapter:_close_reader_controls());paint();eq(session.refresher.count,0)
    assert(session:requestRefresh());UI:advance(0);assert(session.refresher.layer)
    assert(adapter:close_reader())
    eq(session.closed,true);eq(session.refresher.layer,nil);eq(#UI.tasks,0)
    UI:advance(1);eq(session.refresher.completed,0)
    cleanup()
end)
