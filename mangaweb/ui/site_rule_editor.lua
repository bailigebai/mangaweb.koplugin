local Editor = {}
Editor.__index = Editor

local GROUPS = {
    { title = "基础信息", fields = {
        { key = "name", label = "站点名称" },
        { key = "origin", label = "HTTPS 根域名（如 https://example.com）" },
        { key = "list_path", label = "列表路径（如 /list?page={page}）" },
        { key = "search_path", label = "搜索路径（可空，使用 {query}）" },
    } },
    { title = "列表规则", fields = {
        { key = "list_block", label = "每本漫画块（如 (<article.-</article>)）" },
        { key = "list_href", label = "详情链接捕获（如 href=\"(.-)\"）" },
        { key = "list_title", label = "标题捕获（如 title=\"(.-)\"）" },
        { key = "list_cover", label = "封面捕获（如 src=\"(.-)\"）" },
    } },
    { title = "详情与章节规则", fields = {
        { key = "detail_title", label = "详情标题捕获（如 <h1>(.-)</h1>）" },
        { key = "detail_cover", label = "详情封面捕获（如 src=\"(.-)\"）" },
        { key = "detail_description", label = "简介捕获（可空）" },
        { key = "chapter_block", label = "章节块（无章节可空）" },
        { key = "chapter_href", label = "章节链接捕获（无章节可空）" },
        { key = "chapter_title", label = "章节标题捕获（无章节可空）" },
    } },
    { title = "阅读图片规则", fields = {
        { key = "comic_id_pattern", label = "漫画 ID 捕获（另有阅读路径时填写）" },
        { key = "reader_path", label = "阅读路径（可空，如 /read/{id}.html）" },
        { key = "page_block", label = "图片数组范围（可空）" },
        { key = "page_image", label = "图片地址捕获（如 src=\"(.-)\"）" },
    } },
}

local FIELD_NAMES = {
    name = "站点名称", origin = "域名", list_path = "列表路径",
    search_path = "搜索路径", list_block = "漫画块", list_href = "详情链接",
    list_title = "列表标题", list_cover = "列表封面",
    detail_title = "详情标题", detail_cover = "详情封面",
    detail_description = "简介", chapter_block = "章节块",
    chapter_href = "章节链接", chapter_title = "章节标题",
    comic_id_pattern = "漫画 ID", reader_path = "阅读路径",
    page_block = "图片数组范围", page_image = "图片地址",
}

local function failure_text(reason)
    reason = tostring(reason or "settings_save_failed")
    if reason == "https_required" then return "域名必须以 https:// 开头" end
    if reason == "invalid_origin" then return "域名格式有误" end
    if reason == "incomplete_chapter_rules" then return "章节块、链接和标题需同时填写" end
    if reason == "missing_query_placeholder" then return "搜索路径需要 {query}" end
    if reason == "missing_id_placeholder" then return "阅读路径需要 {id}" end
    local capture_field = reason:match("^missing_capture_([%w_]+)$")
    if FIELD_NAMES[capture_field] then
        return FIELD_NAMES[capture_field] .. "需要一组捕获括号"
    end
    if reason == "settings_save_failed" or reason == "settings_flush_failed" then
        return "保存失败，请重试"
    end
    local prefix, field = reason:match("^(%a+)_([%w_]+)$")
    local label = FIELD_NAMES[field]
    if label then
        if prefix == "missing" then return "请填写" .. label end
        if prefix == "empty" then return label .. "不能匹配空内容" end
        if prefix == "invalid" then return label .. "规则有误" end
    end
    return "规则保存失败，请检查输入"
end

Editor.error_text = failure_text

function Editor:new(options)
    options = options or {}
    return setmetatable({ adapter = assert(options.adapter, "adapter is required") }, self)
end

function Editor:show(definition, on_save)
    local adapter = self.adapter
    local Dialog = adapter.multi_input_dialog
    if not Dialog or type(on_save) ~= "function" then return false end
    local draft = { name = (definition or {}).name or "",
        origin = (definition or {}).origin or "", rules = {} }
    for _, group in ipairs(GROUPS) do
        for _, field in ipairs(group.fields) do
            if field.key ~= "name" and field.key ~= "origin" then
                draft.rules[field.key] = ((definition or {}).rules or {})[field.key] or ""
            end
        end
    end
    local step, error_text = 1, nil
    local render
    render = function()
        local group = GROUPS[step]
        local dialog
        local fields = {}
        for _, field in ipairs(group.fields) do
            local value = (field.key == "name" or field.key == "origin")
                and draft[field.key] or draft.rules[field.key]
            fields[#fields + 1] = { description = field.label, text = value or "" }
        end
        local function capture()
            local values = dialog:getFields() or {}
            for index, field in ipairs(group.fields) do
                if field.key == "name" or field.key == "origin" then
                    draft[field.key] = values[index] or ""
                else
                    draft.rules[field.key] = values[index] or ""
                end
            end
        end
        local function close() return adapter:_close_input_dialog(dialog) end
        local buttons = {{
            { text = "取消", id = "close", callback = close },
            { text = step == 1 and "规则说明" or "上一步", callback = function()
                if step == 1 then
                    return adapter._show_site_rule_help and adapter:_show_site_rule_help() or true
                end
                capture(); close(); step, error_text = step - 1, nil
                return render()
            end },
            { text = step == #GROUPS and "保存站点" or "下一步", callback = function()
                capture()
                if step < #GROUPS then
                    close(); step, error_text = step + 1, nil
                    return render()
                end
                local called, saved, reason = pcall(on_save, draft)
                if called and saved then close(); return true end
                error_text = failure_text(called and reason or "settings_save_failed")
                close()
                return render()
            end },
        }}
        local title = (definition and "编辑站点" or "新增站点") .. " "
            .. tostring(step) .. "/" .. tostring(#GROUPS) .. " · " .. group.title
        if error_text then title = error_text .. " · " .. title end
        dialog = Dialog:new(adapter:_input_dialog_options({
            title = title, fields = fields, buttons = buttons,
        }, function() return dialog end))
        return adapter:_show_input_dialog(dialog)
    end
    return render()
end

return Editor
