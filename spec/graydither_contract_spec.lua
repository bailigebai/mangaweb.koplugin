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

local function setup()
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
    reader.settings=settings
    function reader:settings_snapshot() return settings:reader_settings() end
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
