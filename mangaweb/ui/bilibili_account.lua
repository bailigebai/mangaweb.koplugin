local NativePanel = require("mangaweb.ui.native_panel")
local AccountUI = {}
AccountUI.__index = AccountUI

function AccountUI:new(options)
    local qr = options.qr_widget
    if qr == nil then
        local ok, value = pcall(require, "ui/widget/qrwidget")
        qr = ok and value or false
    end
    return setmetatable({
        adapter = assert(options.adapter), auth = assert(options.auth), qr_widget = qr,
        return_to = options.return_to, closed = true, generation = 0,
    }, self)
end

function AccountUI:_retire()
    local widget = self.widget
    self.widget = nil
    if widget then
        pcall(self.adapter.ui_manager.close, self.adapter.ui_manager, widget)
        if widget.free then pcall(widget.free, widget) end
    end
end

function AccountUI:close()
    if self.closed then return true end
    self.closed = true
    self.generation = self.generation + 1
    self.auth:cancel()
    self:_retire()
    return true
end

function AccountUI:_draw(model, message)
    if self.closed then return false end
    local old = self.last_model
    if not message and self.widget and old and old.state == model.state
        and old.qr_url == model.qr_url and old.verified == model.verified
        and (old.account and old.account.uid) == (model.account and model.account.uid) then
        return true
    end
    self.last_model = model
    local panel, prepared_qr
    local generation = self.generation
    local function guard(callback)
        return function(...)
            if self.closed or not panel or panel.closed or self.widget ~= panel then return true end
            pcall(callback, ...)
            return true
        end
    end
    local function back()
        self:close()
        if self.return_to then self.return_to() end
        return true
    end
    local function states(value)
        if not self.closed and self.generation == generation then self:_draw(value) end
    end
    local function start()
        if not self.qr_widget then
            return self:_draw(self.auth:model(), "二维码控件不可用，请检查 KOReader 安装。")
        end
        return self.auth:start(states)
    end
    -- A failed native layout must cancel polling and release a QR that has not
    -- yet been transferred to a window. Keep the previous window until build succeeds.
    local built, widget = pcall(function()
        local rows = {}
        if model.account then
            rows[#rows + 1] = {kind = "info", text = "昵称：" .. model.account.name .. "\nUID：" .. model.account.uid}
        end
        if model.qr_url then
            local side = math.floor(math.min(self.adapter.screen:getWidth() * 0.7, self.adapter.screen:getHeight() * 0.4))
            local ok, qr = pcall(function()
                return self.qr_widget:new{text = model.qr_url, width = side, height = side, image_disposable = true}
            end)
            if ok and qr and qr.image then
                prepared_qr = qr
                rows[#rows + 1] = {kind = "widget", widget = self.adapter.frame_container:new{
                    padding = 16, bordersize = 0, background = self.adapter.blitbuffer.COLOR_WHITE, qr,
                }}
            else
                if qr and qr.free then pcall(qr.free, qr) end
                self.auth:cancel()
                message = "二维码控件不可用，请检查 KOReader 安装。"
            end
        end
        rows[#rows + 1] = {kind = "action", text = model.account and "重新扫码切换账号" or "扫码登录", callback = guard(start)}
        if model.state ~= "idle" and model.state ~= "connected" then
            rows[#rows + 1] = {kind = "action", text = "重新生成二维码", callback = guard(start)}
        end
        if model.account then
            rows[#rows + 1] = {kind = "action", text = "验证已保存账号", callback = guard(function() return self.auth:verify_saved(states) end)}
            rows[#rows + 1] = {kind = "action", text = "退出登录", callback = guard(function() return self.auth:logout(states) end)}
        end
        return NativePanel:new(self.adapter):show{
            title = "哔哩哔哩账号", modal = true, rows = rows, status = message or model.status,
            navigation = {{text = "返回", callback = guard(back)}}, on_back = guard(back), on_close = guard(back),
        }
    end)
    if not built or not widget then
        if prepared_qr and prepared_qr.free then pcall(prepared_qr.free, prepared_qr) end
        self:close()
        return false
    end
    self:_retire()
    panel, self.widget = widget, widget
    local closed = widget.onCloseWidget
    widget.onCloseWidget = function(w)
        if closed then closed(w) end
        if self.widget == w then self:close() end
        return true
    end
    local ok, shown = pcall(self.adapter.ui_manager.show, self.adapter.ui_manager, widget)
    if not ok or shown == false then self:close(); return false end
    return true
end

function AccountUI:show()
    if not self.closed then self:close() end
    self.generation = self.generation + 1
    self.closed, self.last_model = false, nil
    return self:_draw(self.auth:model())
end

return AccountUI
