local LicenseDialog = {}
LicenseDialog.__index = LicenseDialog

local TITLE = "阅读授权"
local MESSAGE = "插件售价：30元。\n咸鱼搜 koreader推箱子 找到购买。"

function LicenseDialog:new(options)
    options = options or {}
    return setmetatable({
        license = assert(options.license, "license is required"),
        ui = assert(options.ui, "ui is required"),
        shell = options.shell,
        token = 0,
    }, self)
end

function LicenseDialog:_activation_model(token, resume, on_change)
    local controller = self
    local model = {
        title = TITLE,
        message = MESSAGE,
        busy = false,
    }

    local function current()
        return controller.active_token == token and controller.token == token
    end

    function model.on_submit(value)
        if not current() or model.busy then return false end
        model.busy = true
        local callbacks = {
            on_success = function()
                if not current() then return end
                controller.active_token = nil
                controller.activation_handle = nil
                model.busy = false
                pcall(controller.ui.close_license_overlay, controller.ui)
                if type(on_change) == "function" then pcall(on_change) end
                if type(resume) == "function" then
                    local once = resume
                    resume = nil
                    pcall(once)
                end
            end,
            on_error = function(code)
                if not current() then return end
                controller.activation_handle = nil
                model.busy = false
                model.error = code
                if type(controller.ui.update_license_activation) == "function" then
                    pcall(controller.ui.update_license_activation, controller.ui, model)
                end
            end,
        }
        local called, handle = pcall(controller.license.activate,
            controller.license, value, callbacks)
        if not called then
            callbacks.on_error("network_error")
            return false
        end
        if current() and model.busy then
            controller.activation_handle = handle
        elseif handle and type(handle.cancel) == "function" then
            pcall(handle.cancel, handle)
        end
        return true
    end

    function model.on_cancel()
        return controller:close("cancel")
    end
    return model
end

function LicenseDialog:_show_activation(resume, on_change)
    self:close("replace")
    self.token = self.token + 1
    local token = self.token
    self.active_token = token
    local model = self:_activation_model(token, resume, on_change)
    self.activation_model = model
    local shown, result = pcall(self.ui.show_license_activation, self.ui, model)
    if not shown or result == false then
        self.active_token = nil
        return false, "license_dialog_failed"
    end
    return true
end

function LicenseDialog:request_read(resume)
    if type(resume) ~= "function" then return false, "invalid_resume" end
    return self:_show_activation(resume)
end

function LicenseDialog:show_manager(on_change)
    self:close("manager")
    self.token = self.token + 1
    local token = self.token
    self.active_token = token
    local status = "invalid"
    local called, value = pcall(self.license.status, self.license)
    if called and (value == "authorized" or value == "not_activated" or value == "invalid") then
        status = value
    end
    local controller = self
    local model = { status = status, title = TITLE, message = MESSAGE }
    function model.on_activate()
        if controller.active_token ~= token then return false end
        return controller:_show_activation(nil, on_change)
    end
    function model.on_remove()
        if controller.active_token ~= token then return false end
        local success, removed = pcall(controller.license.remove_local, controller.license)
        if not success or removed ~= true then return false end
        if type(on_change) == "function" then pcall(on_change) end
        controller:close("removed")
        return true
    end
    function model.on_close()
        return controller:close("manager_close")
    end
    self.manager_model = model
    local shown, result = pcall(self.ui.show_license_manager, self.ui, model)
    if not shown or result == false then
        self.active_token = nil
        return false, "license_dialog_failed"
    end
    return true
end

function LicenseDialog:close()
    self.token = self.token + 1
    self.active_token = nil
    self.activation_model = nil
    self.manager_model = nil
    local handle = self.activation_handle
    self.activation_handle = nil
    if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
    if self.license and type(self.license.cancel) == "function" then
        pcall(self.license.cancel, self.license)
    end
    if self.ui and type(self.ui.close_license_overlay) == "function" then
        pcall(self.ui.close_license_overlay, self.ui)
    end
    return true
end

return LicenseDialog
