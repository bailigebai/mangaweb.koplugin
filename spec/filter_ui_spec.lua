local fixture = require("spec.helpers.reader_ui")
local Filters = require("mangaweb.ui.reader_filters")
local Settings = require("mangaweb.settings")
local Reader = require("mangaweb.reader")
local function action(panel, text)
    for _, rows in ipairs({panel.model.rows or {}, {{kind="actions",items=panel.model.actions or {}}}}) do
        for _, row in ipairs(rows) do
            for _, item in ipairs(row.items or {}) do
                if item.text == text then return item.callback end
            end
        end
    end
    error("missing action: "..text)
end
local function setup()
    local adapter,reader,manager=fixture()
    local saved, saves={},0
    local settings=Settings:new{store={readSetting=function(_,key,default)return saved[key] or default end,
        saveSetting=function(_,key,value)saved[key]=value;saves=saves+1;return true end,flush=function()return true end}}
    function reader:settings_snapshot()return settings:reader_settings()end
    function reader:update_settings(changes)
        local values=settings:reader_settings()
        for key,value in pairs(changes)do values[key]=value end
        return settings:save_reader_settings(values)
    end
    adapter.single_input_dialog.getInputText=function(self)return self.test_input or self.input end
    local filters=Filters:new{adapter=adapter,reader=reader}
    return filters,adapter,reader,manager,function()return saves end
end
local function press_input(adapter,text)
    local dialog=assert(adapter.input_dialog)
    dialog.test_input=text
    for _,row in ipairs(dialog.buttons)do
        for _,button in ipairs(row)do if button.text=="确定" then return button.callback() end end
    end
    error("missing input confirm")
end
for _,kind in ipairs({"gray","tone"})do
    local filters,adapter,reader,manager,saves=setup()
    assert(filters:show(kind))
    action(adapter.reader_controls,"○ 清晰")()
    local values=reader:settings_snapshot()
    assert(values[kind.."_preset"]=="clear" and values[kind.."_enabled"]==false,
        "preset selection must preserve the independent switch")
    action(adapter.reader_controls,"调整参数 / 另存预设")()
    local label=kind=="gray" and "black 黑点：40" or "亮度：0"
    action(adapter.reader_controls,label)()
    local before=saves()
    press_input(adapter,kind=="gray" and "300" or "101")
    assert(adapter.input_dialog and saves()==before,"invalid numbers must keep the input and settings")
    press_input(adapter,kind=="gray" and "42" or "10")
    assert(not adapter.input_dialog and saves()==before,"editing a draft must not persist")
    action(adapter.reader_controls,"保存预设")()
    values=reader:settings_snapshot()
    assert(values[kind.."_preset"]=="custom-1" and #values[kind.."_custom_presets"]==1)
    assert(values[kind.."_custom_presets"][1][kind=="gray" and "black" or "brightness"]==(kind=="gray" and 42 or 10))
    action(adapter.reader_controls,"管理自定义预设")()
    action(adapter.reader_controls,"编辑：清晰（副本）")()
    action(adapter.reader_controls,"名称：清晰（副本）")()
    press_input(adapter,"改名")
    action(adapter.reader_controls,"取消编辑")()
    assert(reader:settings_snapshot()[kind.."_custom_presets"][1].name=="清晰（副本）",
        "cancelled rename must leave stored presets unchanged")
    action(adapter.reader_controls,"管理自定义预设")()
    action(adapter.reader_controls,"删除：清晰（副本）")()
    local cancelled_delete=action(adapter.reader_controls,"确认删除")
    action(adapter.reader_controls,"取消")()
    cancelled_delete()
    assert(#reader:settings_snapshot()[kind.."_custom_presets"]==1)
    action(adapter.reader_controls,"删除：清晰（副本）")()
    action(adapter.reader_controls,"确认删除")()
    assert(reader:settings_snapshot()[kind.."_preset"]=="original",
        "deleting the selected custom preset must return to original")
    local callbacks,cancelled
    function reader:preview_filter(_,preset,handlers)
        callbacks=handlers
        return {cancel=function()cancelled=true end}
    end
    filters:show(kind)
    before=saves()
    action(adapter.reader_controls,"预览前后（当前页）")()
    assert(adapter.filter_preview and adapter.filter_preview.modal)
    callbacks.on_ready{before_path="/raw.jpg",after_path="/after.png"}
    local preview=adapter.filter_preview
    assert(preview.before_path=="/raw.jpg" and preview.after_path=="/after.png")
    assert(preview:select("before")); assert(preview:select("after"))
    assert(reader.position==11 and reader.turns==0 and saves()==before,
        "previewing must not save settings or navigate")
    adapter.input_container.paintTo=function()error("native preview decode failed")end
    function manager:nextTick(callback)callback();return true end
    local painted=pcall(preview.paintTo,preview,{},0,0)
    assert(painted and preview.status:find("预览显示失败",1,true),
        "a preview drawing error must show a message instead of crashing KOReader")
    assert(preview:close())
    assert(cancelled and not adapter.filter_preview)
    callbacks.on_ready{before_path="/late.jpg",after_path="/late.png"}
    assert(not adapter.filter_preview,"late preview completion must not reopen a window")
end

-- The real reader must lend its raw source to the existing processing queue.
local request, callbacks, cancelled, released
local reader=Reader:new{store={},ui={content_width=1272,content_height=1696},loader={
    request=function(_,generation,spec,handlers)request=spec;callbacks=handlers;return{cancel=function()cancelled=true end}end,
    release=function(_,generation)released=generation end,
}}
reader.closed=false;reader.position=1;reader.loader_generation=9
reader.context={site_id="zero",comic_id="x",pages={{url="https://image.test/1.jpg"}}}
reader.entries[1]={path="/processed.png",raw_path="/original.jpg",metadata={width=1192,height=1696}}
reader.page_metadata[1]={width=1400,height=1991}
local result
local handle=assert(reader:preview_filter("gray",{id="clear",builtin=true}, {on_ready=function(value)result=value end}))
assert(request.source_path=="/original.jpg" and request.profile.target_height==1696)
callbacks.on_ready{path="/new.png",metadata={}}
assert(result.before_path=="/original.jpg" and result.after_path=="/new.png")
reader.loader_generation=10
handle:cancel()
assert(cancelled and released==9,"closing a preview must release its original session's derivative")
result=nil;callbacks.on_ready{path="/late.png",metadata={}}
assert(not result)
print("filter_ui_spec: passed")
