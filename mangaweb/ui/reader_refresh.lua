-- MangaWeb owns these panels; the optional service owns only final image
-- processing and refresh. No child dialogs or external menus are opened here.
local Controls = {}
Controls.__index = Controls

local TITLES = {
    graydither = "灰度与全刷", refresh = "墨水屏刷新",
    refresh_interval = "自动全刷间隔", refresh_hold = "黑白保持时长",
}
local UNAVAILABLE = "灰度与全刷服务不可用，请安装并启用 GrayDither 0.3.0 或以上版本。"
local function command(text, callback) return {text=text, callback=callback} end
local function row(...) return {kind="actions", items={...}} end
local function clamp(value, minimum, maximum) return math.max(minimum, math.min(maximum, value)) end

function Controls:new(options)
    return setmetatable({adapter=options.adapter, reader=options.reader,
        page=options.adapter.reader_widget, reader_session=options.reader.loader_generation}, self)
end

function Controls:active()
    return self.adapter.reader == self.reader and not self.reader.closed
        and self.reader.loader_generation == self.reader_session
        and self.adapter.reader_widget == self.page and self.page and not self.page.released
end

function Controls:_bridge()
    local bridge = self.page and self.page.graydither_bridge
    return bridge and bridge:isAvailable() and bridge or nil
end

function Controls:_log(section, stage)
    local logger = self.adapter.logger
    if logger and type(logger.warn) == "function" then
        pcall(logger.warn, "MangaWeb reader settings", section, stage)
    end
end

function Controls:_save(changes)
    local ok, saved = pcall(self.reader.update_settings, self.reader, changes)
    if not ok or saved ~= true then return "保存失败，请重试。" end
    local bridge = self:_bridge()
    if not bridge or not bridge:settingsChanged() then return UNAVAILABLE end
end

function Controls:_panel(section, rows, back, status)
    local adapter, panel = self.adapter, nil
    local function guard(callback)
        return function(...)
            if not self:active() or not panel or panel.closed or adapter.reader_controls ~= panel then return true end
            local ok, value = pcall(callback, ...)
            if not ok then
                self:_log(section, "callback_failed")
                return true
            end
            return value == nil and true or value
        end
    end
    local close = function() return adapter:_close_reader_controls() end
    local model = {modal=true, title=TITLES[section], rows=rows, status=status,
        navigation={command("← 返回", back), command("返回阅读", close)},
        on_back=back, on_close=close}
    for _, current in ipairs(rows) do
        for _, item in ipairs(current.items or {}) do item.callback=guard(item.callback) end
    end
    for _, item in ipairs(model.navigation) do item.callback=guard(item.callback) end
    model.on_back, model.on_close = guard(back), guard(close)
    local ok, shown = pcall(adapter._show_reader_panel, adapter, model)
    if not ok or not shown then self:_log(section, "show_failed"); return false end
    panel = adapter.reader_controls
    return true
end

function Controls:show(section, draft, status)
    if not TITLES[section] or not self:active() then return false end
    local ok, values = pcall(self.reader.settings_snapshot, self.reader)
    if not ok or type(values) ~= "table" then self:_log(section, "snapshot_failed"); return false end
    local rows, bridge = {}, self:_bridge()
    local back = function() return self:show("graydither") end
    if section == "graydither" then
        back = function() return self.adapter:_show_reader_controls("root") end
    elseif section ~= "refresh" then
        back = function() return self:show("refresh") end
    end
    if not bridge then
        return self:_panel(section, rows, back, UNAVAILABLE)
    end
    local function update(changes)
        return self:show(section, nil, self:_save(changes))
    end
    if section == "graydither" then
        rows = {
            row(command("灰度抖动：" .. (values.graydither_enabled and "开启" or "关闭"), function()
                return update{graydither_enabled=not values.graydither_enabled}
            end)),
            row(command("墨水屏刷新", function() return self:show("refresh") end)),
            {kind="info", text="软件模拟16级灰阶，仅处理最终缩放后的漫画正文；封面、预览和原图缓存保持原样。"},
        }
    elseif section == "refresh" then
        rows = {
            row(command("自动全刷：" .. (values.graydither_refresh_enabled and "开启" or "关闭"), function()
                return update{graydither_refresh_enabled=not values.graydither_refresh_enabled}
            end)),
            row(command(("自动间隔：每 %d 页"):format(values.graydither_refresh_interval), function()
                return self:show("refresh_interval")
            end)),
            row(command("刷新方式：" .. (values.graydither_refresh_mode == "flash" and "黑白辅助" or "原生全刷"), function()
                return update{graydither_refresh_mode=values.graydither_refresh_mode == "flash" and "native" or "flash"}
            end)),
        }
        if values.graydither_refresh_mode == "flash" then
            rows[#rows+1] = row(command(("黑白各保持：%.2f 秒"):format(values.graydither_refresh_hold), function()
                return self:show("refresh_hold")
            end))
        end
        rows[#rows+1] = row(command("立即全刷", function()
            self.adapter:_close_reader_controls()
            if not bridge:requestRefresh() then return self:show("refresh", nil, "刷新未完成，请重试。") end
            return true
        end))
        rows[#rows+1] = {kind="info", text="默认每5次成功显示的新页面全刷。初始页、同页重绘不计数；跳页算一次。设置、休眠及退出会取消未完成刷新。"}
    else
        local interval = section == "refresh_interval"
        local key = interval and "graydither_refresh_interval" or "graydither_refresh_hold"
        local value = draft or values[key]
        local function step(delta)
            local next_value = value + delta
            if not interval then next_value = math.floor(next_value * 100 + 0.5) / 100 end
            return self:show(section, clamp(next_value, interval and 1 or 0.10, interval and 50 or 1.00))
        end
        local function save()
            local error_text = self:_save{[key]=value}
            if error_text then return self:show(section, value, error_text) end
            return self:show("refresh")
        end
        rows = {
            {kind="info", text=interval and ("每 %d 页刷新一次（1～50）"):format(value)
                or ("黑白各保持 %.2f 秒（0.10～1.00）"):format(value)},
            row(command(interval and "−1" or "−0.05", function() return step(interval and -1 or -0.05) end),
                command(interval and "＋1" or "＋0.05", function() return step(interval and 1 or 0.05) end)),
            row(command(interval and "−5" or "−0.25", function() return step(interval and -5 or -0.25) end),
                command(interval and "＋5" or "＋0.25", function() return step(interval and 5 or 0.25) end)),
            row(command(interval and "默认 5" or "默认 0.30", function()
                return self:show(section, interval and 5 or 0.30)
            end), command("保存", save)),
        }
        status = status or "使用加减按钮调整，点击保存生效；返回会放弃本次调整。"
    end
    return self:_panel(section, rows, back, status)
end

return Controls
