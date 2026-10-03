local Presets = require("mangaweb.filter_presets")
local Preview = require("mangaweb.ui.filter_preview")
local Filters = {}
Filters.__index = Filters
local TITLES = {gray="漫画去灰增强",tone="亮度与对比度"}
local FIELDS = {
    gray={{key="black",label="black 黑点",range="0–254，整数"},
        {key="white",label="white 白点",range="1–255，整数；必须大于黑点"},
        {key="gamma",label="gamma 伽马",range="0.1–5.0"}},
    tone={{key="brightness",label="亮度",range="−100–100，整数"},
        {key="contrast",label="对比度",range="0–200，整数"}},
}
local function command(text, callback)
    return {text=text,callback=callback,vsync=true,no_invert=true}
end
local function row(...) return {kind="actions",items={...}} end
local function error_text(kind, reason)
    if reason=="invalid_filter_name" then return "名称不能为空或过长，请缩短名称" end
    if reason=="settings_save_failed" or reason=="settings_flush_failed" then return "保存失败，请重试" end
    return kind=="gray" and "请输入合法黑点、白点和伽马；黑点必须小于白点"
        or "亮度需为−100到100的整数，对比度需为0到200的整数"
end
function Filters:new(options)
    return setmetatable({adapter=options.adapter,reader=options.reader,
        reader_session=options.reader.loader_generation,token=0,panel_generation=0},self)
end
function Filters:active()
    return self.adapter.reader==self.reader and not self.reader.closed
        and self.reader.loader_generation==self.reader_session
end
function Filters:_panel(kind, rows, back, status, actions)
    if not self:active() then return false end
    self.panel_generation=self.panel_generation+1
    local generation=self.panel_generation
    local function guard(callback)
        return function(...)
            if not self:active() or self.panel_generation~=generation then return true end
            return callback(...)
        end
    end
    local model={
        modal=true,title=TITLES[kind],rows=rows,status=status,actions=actions,
        navigation={command("← 返回",back),command("返回阅读",function()return self.adapter:_close_reader_controls()end)},
        on_back=back,on_close=function()return self.adapter:_close_reader_controls()end,
    }
    for _,current in ipairs(model.rows or {})do
        for _,item in ipairs(current.items or {})do item.callback=guard(item.callback) end
    end
    for _,items in ipairs({model.actions or {},model.navigation})do
        for _,item in ipairs(items)do item.callback=guard(item.callback) end
    end
    model.on_back,model.on_close=guard(model.on_back),guard(model.on_close)
    return self.adapter:_show_reader_panel(model)
end
function Filters:_save(changes)
    if not self:active() then return false,"reader_closed" end
    local ok,saved,reason=pcall(self.reader.update_settings,self.reader,changes)
    return ok and saved==true,ok and reason or "settings_save_failed"
end
function Filters:show(kind, status)
    if not TITLES[kind] or not self:active() then return false end
    local values=self.reader:settings_snapshot()
    local selected=Presets.find(kind,values[kind.."_preset"],values[kind.."_custom_presets"])
        or Presets.find(kind,"original")
    local rows={row(command("总开关："..(values[kind.."_enabled"] and "开启" or "关闭"),function()
        local ok,reason=self:_save{[kind.."_enabled"]=not values[kind.."_enabled"]}
        return self:show(kind,not ok and error_text(kind,reason) or nil)
    end))}
    for _,preset in ipairs(Presets.all(kind,values[kind.."_custom_presets"]))do
        local current=preset
        rows[#rows+1]=row(command((selected.id==current.id and "● " or "○ ")..current.name,function()
            local ok,reason=self:_save{[kind.."_preset"]=current.id}
            return self:show(kind,not ok and error_text(kind,reason) or nil)
        end))
    end
    local summary={}
    for _,field in ipairs(FIELDS[kind])do summary[#summary+1]=field.label.." "..tostring(selected[field.key]) end
    rows[#rows+1]={kind="info",text=table.concat(summary,"  ")}
    rows[#rows+1]=row(command("调整参数 / 另存预设",function()return self:edit(kind,selected)end),
        command("管理自定义预设",function()return self:manage(kind)end))
    rows[#rows+1]=row(command("预览前后（当前页）",function()return self:preview(kind,selected)end))
    return self:_panel(kind,rows,function()return self.adapter:_show_reader_controls("root")end,status)
end
function Filters:manage(kind, status)
    local values=self.reader:settings_snapshot()
    local rows={row(command("新增预设",function()
        local selected=Presets.find(kind,values[kind.."_preset"],values[kind.."_custom_presets"])
        return self:edit(kind,selected,true)
    end))}
    for _,preset in ipairs(values[kind.."_custom_presets"] or {})do
        local current=preset
        rows[#rows+1]=row(command("编辑："..current.name,function()return self:edit(kind,current)end),
            command("删除："..current.name,function()return self:confirm_delete(kind,current)end))
    end
    return self:_panel(kind,rows,function()return self:show(kind)end,status or "内置预设保留，可另存为自定义预设")
end
function Filters:confirm_delete(kind, preset)
    return self:_panel(kind,{},function()return self:manage(kind)end,"删除自定义预设“"..preset.name.."”？",{
        command("取消",function()return self:manage(kind)end),
        command("确认删除",function()
            local values=self.reader:settings_snapshot()
            local list={}
            for _,value in ipairs(values[kind.."_custom_presets"])do if value.id~=preset.id then list[#list+1]=value end end
            local changes={[kind.."_custom_presets"]=list}
            if values[kind.."_preset"]==preset.id then changes[kind.."_preset"]="original" end
            local ok,reason=self:_save(changes)
            return self:manage(kind,not ok and error_text(kind,reason) or nil)
        end),
    })
end
function Filters:edit(kind, preset, is_new)
    preset=preset or Presets.find(kind,"clear")
    local values=self.reader:settings_snapshot()
    local draft=Presets.copy(preset)
    if is_new or draft.builtin then
        draft.id=Presets.next_id(values[kind.."_custom_presets"])
        draft.name=preset.name.."（副本）"
    end
    draft.builtin=false
    local render
    render=function(status)
        local rows={row(command("名称："..draft.name,function()
            return self:_input(kind,draft,{key="name",label="名称",range="简短名称"},render)
        end))}
        for _,field in ipairs(FIELDS[kind])do
            local current=field
            rows[#rows+1]=row(command(current.label.."："..tostring(draft[current.key]),function()
                return self:_input(kind,draft,current,render)
            end))
        end
        rows[#rows+1]=row(command("预览前后（草稿）",function()return self:preview(kind,draft)end))
        return self:_panel(kind,rows,function()return self:show(kind)end,status or "预览不保存；保存后选中此自定义预设",{
            command("取消编辑",function()return self:show(kind)end),
            command("保存预设",function()
                local normalized,reason=Presets.normalize(kind,draft)
                if not normalized then return render(error_text(kind,reason)) end
                local current=self.reader:settings_snapshot()
                local list,replaced={},false
                for _,value in ipairs(current[kind.."_custom_presets"])do
                    if value.id==normalized.id then list[#list+1]=normalized;replaced=true
                    else list[#list+1]=value end
                end
                if not replaced then list[#list+1]=normalized end
                local ok,save_reason=self:_save{[kind.."_custom_presets"]=list,[kind.."_preset"]=normalized.id}
                if not ok then return render(error_text(kind,save_reason)) end
                return self:show(kind)
            end),
        })
    end
    return render()
end
function Filters:_input(kind,draft,field,reopen)
    local adapter=self.adapter
    local Dialog=adapter.single_input_dialog
    if not Dialog then return reopen("当前 KOReader 不支持数值输入") end
    local dialog
    local function close()
        adapter:_close_input_dialog(dialog)
        if self.editor_dialog==dialog then self.editor_dialog=nil end
        return true
    end
    local cancel=command("取消",function()close();return reopen()end)
    cancel.id="close"
    dialog=Dialog:new(adapter:_input_dialog_options({
        title=field.label.." · "..field.range,fullscreen=false,input=tostring(draft[field.key]),
        input_type=field.key~="name" and "number" or nil,
        buttons={{cancel,command("确定",function()
            if not self:active() or self.editor_dialog~=dialog then return true end
            local candidate=Presets.copy(draft)
            local text=dialog:getInputText()
            candidate[field.key]=field.key=="name" and text or tonumber(text)
            local normalized,reason=Presets.normalize(kind,candidate)
            if not normalized then
                local message=error_text(kind,reason)
                if dialog.title_bar and dialog.title_bar.setTitle then dialog.title_bar:setTitle(message) end
                if adapter.ui_manager.setDirty then adapter.ui_manager:setDirty(dialog,"ui") end
                return true
            end
            draft[field.key]=normalized[field.key]
            close();return reopen()
        end)}},
        mangaweb_close_callback=function()close();return reopen()end,
    },function()return dialog end))
    self.editor_dialog=dialog
    return adapter:_show_input_dialog(dialog)
end
function Filters:preview(kind,preset)
    if not self:active() then return false end
    self:_close_preview()
    local token=self.token
    local preview=Preview.show(self.adapter,{title=TITLES[kind].." · "..preset.name,
        on_close=function()self:_close_preview()end})
    if not preview then return self:show(kind,"当前 KOReader 不支持图像预览") end
    self.adapter.filter_preview=preview
    local request=self.reader:preview_filter(kind,preset,{
        on_ready=function(result)
            if self.token~=token or not self:active() or self.adapter.filter_preview~=preview then return end
            preview:set_paths(result.before_path,result.after_path)
        end,
        on_error=function(reason)
            if self.token==token and self.adapter.filter_preview==preview then
                preview:set_error("预览处理失败，原图未修改；请返回重试")
            end
        end,
    })
    if not request then preview:set_error("当前页未加载完成或预设无效，请返回重试") end
    if self.token==token then self.preview_request=request
    elseif request and request.cancel then request:cancel() end
    return request~=nil
end
function Filters:_close_preview()
    self.token=self.token+1
    local request=self.preview_request
    self.preview_request=nil
    if request and request.cancel then request:cancel() end
    local preview=self.adapter.filter_preview
    self.adapter.filter_preview=nil
    if preview then preview:close() end
    return true
end
function Filters:close()
    self:_close_preview()
    if self.editor_dialog then self.adapter:_close_input_dialog(self.editor_dialog);self.editor_dialog=nil end
end
return Filters
