local Settings = require("mangaweb.settings")
local fixture = require("spec.helpers.reader_ui")

local function storage_fixture()
    local values, storage = {}, {}
    function storage:readSetting(key, fallback)
        local value = values[key]
        return value == nil and fallback or value
    end
    function storage:saveSetting(key, value)
        values[key] = value
        return true
    end
    function storage:flush() return not self.fail_flush end
    return Settings:new{store=storage}, storage, values
end

local function find_action(panel, text)
    for _, row in ipairs(panel.model.rows or {}) do
        for _, item in ipairs(row.items or {}) do
            if item.text == text then return item end
        end
    end
    error("missing action: " .. text)
end

-- The shared service is an optional external boundary. Exercise the real source
-- settings, reader window and UI adapter; observe the contract sent to it.
local function service_fixture()
    local service = {sessions={}}
    function service:createImageSession(options)
        if self.fail_create then error("service unavailable") end
        local session = {options=options, images={}, pauses=0, resumes=0, resets=0, closes=0,pause_modes={}}
        function session:attachImage(image, token)
            if service.fail_attach then error("image session unavailable") end
            if service.reject_attach then return false end
            self.images[#self.images+1] = {widget=image,token=token}
            return true
        end
        function session:pause(preserve)
            self.pauses=self.pauses+1;self.pause_modes[#self.pause_modes+1]=preserve==true
        end
        function session:resume() self.resumes=self.resumes+1 end
        function session:reset() self.resets=self.resets+1 end
        function session:close() self.closes=self.closes+1;self.closed=true end
        function session:showMenu(return_to_reading)
            self.return_to_reading=return_to_reading
            return true
        end
        service.sessions[#service.sessions+1]=session
        return session
    end
    package.loaded.pluginloader = {getPluginInstance=function(_, name)
        assert(name=="graydither", "only the enabled GrayDither instance may be requested")
        return service
    end}
    return service
end

local function connected_fixture()
    package.loaded.pluginloader = {getPluginInstance=function() return nil end}
    local adapter, reader, manager = fixture()
    local settings = storage_fixture()
    reader.settings = settings
    function reader:settings_snapshot() return settings:reader_settings() end
    local service = service_fixture()
    assert(adapter:show_page("/synthetic-body.jpg",11,178,{}))
    return adapter,reader,manager,service
end

local function independent_defaults_and_persistence()
    G_reader_settings = {readSetting=function() return true end}
    local settings, storage, values = storage_fixture()
    local config = settings:reader_settings()
    assert(config.graydither_enabled==false and config.graydither_refresh_enabled==false,
        "a new MangaWeb reader must keep both switches off even when global defaults are true")
    config.graydither_enabled,config.graydither_refresh_enabled=true,true
    config.graydither_refresh_interval,config.graydither_refresh_mode,config.graydither_refresh_hold=9,"flash",0.4
    assert(settings:save_reader_settings(config))
    local reopened=Settings:new{store=storage}:reader_settings()
    assert(reopened.graydither_enabled and reopened.graydither_refresh_enabled,
        "the two source preferences must survive reopening")
    assert(reopened.graydither_refresh_interval==9 and reopened.graydither_refresh_mode=="flash"
        and reopened.graydither_refresh_hold==0.4)
    config.graydither_refresh_interval=0
    assert(not settings:save_reader_settings(config), "invalid refresh parameters must fail before persistence")
    assert(settings:reader_settings().graydither_refresh_interval==9)
    config=settings:reader_settings();config.graydither_enabled=false
    storage.fail_flush=true
    assert(not settings:save_reader_settings(config), "failed persistence must be reported")
    assert(settings:reader_settings().graydither_enabled==true,
        "a failed save must keep the previously effective setting")
    assert(values.reader.graydither_enabled==true)
end

local function local_image_and_stable_screen_identity()
    local adapter,reader,manager,service=connected_fixture()
    local session=assert(service.sessions[1], "the actual reading window must create an optional image session")
    local page=adapter.reader_widget
    assert(session.options.owner==page and session.options.is_ready(),
        "the owner must be the real visible Page, with its readiness guard")
    assert(#session.images==1 and session.images[1].widget==page.image,
        "only the final body ImageWidget must be attached")
    local first=session.images[1].token
    assert(type(first)=="string" and not first:find("synthetic"), "screen tokens must contain no file paths")
    assert(adapter:show_page("/other-body.jpg",11,178,{}))
    assert(session.images[2].token==first, "same logical page redraw must keep the same identity")
    assert(adapter:show_page("/other-body.jpg",11,178,{segment="right"}))
    local segment=session.images[3].token
    assert(segment~=first, "another split of the same physical image is another reading screen")
    assert(adapter:show_page("/other-body.jpg",11,178,{segment="right",pan_y=640,fit_mode="width"}))
    assert(session.images[4].token~=segment, "another viewport of the same image needs its own screen identity")
    assert(adapter:show_page("/other-body.jpg",12,178,{}))
    assert(session.images[5].token~=first)
    local store=session.options.store
    assert(store:readSetting("graydither_enabled")==false)
    assert(store:saveSetting("graydither_enabled",true)~=false)
    assert(reader:settings_snapshot().graydither_enabled==true,
        "the shared menu must write the source's persisted reader preference")
    assert(store:delSetting("graydither_enabled")~=false)
    assert(reader:settings_snapshot().graydither_enabled==false)
    local dirtied=0
    function manager:setDirty(widget) assert(widget==page);dirtied=dirtied+1 end
    session.options.redraw()
    assert(dirtied==1, "menu changes must redraw the actual reading window")
end

local function controls_loading_error_suspend_and_close()
    local adapter,reader,manager,service=connected_fixture()
    local session,page=service.sessions[1],adapter.reader_widget
    assert(session, "an available service must be attached")
    assert(adapter:_show_reader_controls())
    assert(session.pauses>0 and not session.options.is_ready(),
        "embedded settings must immediately cancel refresh and hide the body")
    local action=find_action(adapter.reader_controls,"灰度与全刷")
    assert(action.callback())
    assert(type(session.return_to_reading)=="function", "the shared menu needs a real return-to-reading action")
    session.return_to_reading()
    assert(not page.embedded_controls and session.options.is_ready(),
        "manual refresh must be able to leave all source settings before returning")
    assert(adapter:show_page_loading(12,178))
    assert(not session.options.is_ready() and session.pauses>=2)
    assert(session.pause_modes[#session.pause_modes]==true,
        "temporary loading must preserve successful page tokens and accumulated progress")
    assert(adapter:show_page("/synthetic-body2.jpg",12,178,{}))
    assert(session.options.is_ready() and session.resumes>0)
    assert(page:set_error{code="image_error"})
    assert(not session.options.is_ready())
    assert(adapter:show_page("/synthetic-body2.jpg",12,178,{}))
    page:onSuspend()
    assert(not session.options.is_ready(), "sleep must make the reading body unavailable")
    assert(session.pause_modes[#session.pause_modes]==false, "sleep must reset the counting baseline")
    page:onResume()
    assert(session.options.is_ready())
    local resets=session.resets
    page:onSetDimensions()
    assert(session.resets>resets, "size changes must cancel stale refresh geometry")
    assert(adapter:close_reader())
    assert(session.closed and session.closes==1 and not session.options.is_ready(),
        "closing the real window must close the optional session once")
    assert(page:release())
    assert(session.closes==1, "release and close must be idempotent")
end

local function rejected_or_stopped_session_is_not_reused()
    local adapter,reader,manager,service=connected_fixture()
    local session=service.sessions[1]
    service.reject_attach=true
    assert(adapter:show_page("/synthetic-next.jpg",12,178,{}))
    assert(session.closed, "a rejected optional attach must release the failed shared session")
    assert(adapter.reader_widget.image.file=="/synthetic-next.jpg")
    assert(adapter:_show_reader_controls())
    assert(find_action(adapter.reader_controls,"灰度与全刷").callback())
    assert(adapter.reader_controls.model.status:find("不可用"))
    adapter,reader,manager,service=connected_fixture()
    session=service.sessions[1]
    session:close() -- GrayDither stopPlugin closes sessions owned by source windows.
    assert(adapter:show_page("/synthetic-next.jpg",12,178,{}))
    assert(#session.images==1, "a stopped service must not receive more image work")
    assert(adapter:_show_reader_controls())
    assert(find_action(adapter.reader_controls,"灰度与全刷").callback())
    assert(adapter.reader_controls.model.status:find("不可用"))
end

local function fallback_controls_cancel_and_hide_shared_body()
    local adapter,reader,manager,service=connected_fixture()
    local page,session=adapter.reader_widget,service.sessions[1]
    -- A native panel may fall back to a separate modal when embedding fails.
    function page:show_controls() return false end
    assert(adapter:_show_reader_controls())
    assert(not page.embedded_controls and adapter.reader_controls)
    assert(session.pauses>0 and not session.options.is_ready(),
        "separate fallback settings must cancel refresh as soon as they open")
    assert(adapter:show_page("/late-while-settings.jpg",12,178,{}))
    assert(not session.options.is_ready(), "a late page completion must keep fallback settings paused")
    assert(adapter:_close_reader_controls())
    assert(session.options.is_ready() and session.resumes>0)
    function reader:go_to() return true end
    assert(adapter:_show_page_picker())
    assert(not session.options.is_ready(), "the fallback page picker must also hide the reading body")
    assert(adapter:_close_reader_controls())
    assert(session.options.is_ready())
end

local function unavailable_and_failed_services_preserve_reading()
    for _, mode in ipairs({"disabled","old","lookup_failure","create_failure","attach_failure"}) do
        package.loaded.pluginloader={getPluginInstance=function() return nil end}
        local adapter,reader=fixture()
        reader.settings=storage_fixture()
        if mode=="old" then package.loaded.pluginloader={getPluginInstance=function() return {} end}
        elseif mode=="lookup_failure" then package.loaded.pluginloader={getPluginInstance=function() error("unavailable") end}
        elseif mode=="create_failure" or mode=="attach_failure" then
            local service=service_fixture()
            service.fail_create=mode=="create_failure"
            service.fail_attach=mode=="attach_failure"
        end
        local ok,shown=pcall(adapter.show_page,adapter,"/synthetic.jpg",1,2,{})
        assert(ok and shown and adapter.reader_widget.image,
            mode..": an unavailable optional service must leave the normal image path intact")
        assert(adapter:_show_reader_controls())
        assert(find_action(adapter.reader_controls,"灰度与全刷").callback())
        assert(adapter.reader_controls.model.status:find("安装") or adapter.reader_controls.model.status:find("不可用"),
            mode..": settings must explain the unavailable feature")
        assert(not reader.closed)
        assert(adapter:close_reader())
    end
end

local failures={}
for _,test in ipairs({independent_defaults_and_persistence,local_image_and_stable_screen_identity,
    controls_loading_error_suspend_and_close,unavailable_and_failed_services_preserve_reading,
    rejected_or_stopped_session_is_not_reused,fallback_controls_cancel_and_hide_shared_body}) do
    local ok,reason=pcall(test)
    if not ok then failures[#failures+1]=tostring(reason) end
end
assert(#failures==0,table.concat(failures,"\n"))
print("graydither_integration_spec: passed")
