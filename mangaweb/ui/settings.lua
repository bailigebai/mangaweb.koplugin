local Settings = {}
Settings.__index = Settings
local Models = require("mangaweb.models")

local STATE_MESSAGES = {
    ready = "尚未验证",
    logging_in = "正在登录",
    testing = "正在测试连接",
    connected = "连接成功",
    ["credentials_required"] = "请输入账号和密码",
    auth_unavailable = "此站点不支持账号登录",
    ["invalid_credentials"] = "账号或密码错误",
    login_required = "登录未成功或登录已失效",
    login_unverified = "会话已保存，尚未验证",
    ["invalid_cookie"] = "Cookie 格式无效",
    network_error = "网络连接失败",
    transport_error = "HTTPS 连接失败，请检查时间和网络",
    http_error = "站点返回错误",
    http_unavailable = "网络功能不可用",
    verification_required = "需要先在浏览器完成验证",
    parse_error = "站点页面已变化，无法识别",
    empty_result = "站点返回空内容",
    response_too_large = "站点响应过大",
    request_timeout = "章节请求超时，请重试",
}

local function safe_error(value, site_id, stage, fallback)
    value = type(value) == "table" and value or {}
    local status = tonumber(value.status)
    if not status and type(value.detail) == "number" then status = value.detail end
    local code = tostring(value.code or fallback or "network_error")
    if not STATE_MESSAGES[code] then code = fallback or "network_error" end
    return Models.error({ code = code, status = status }, site_id, stage)
end

function Settings:new(options)
    options = options or {}
    return setmetatable({
        shell = options.shell,
        source = options.source,
        auth = options.auth,
        http = options.http,
        site_manager = options.site_manager,
        model_value = {},
        view_token = options.view_token,
        request_token = 0,
        busy = false,
        request_handle = nil,
        closed = false,
    }, self)
end

function Settings:site_id()
    return self.source and self.source.id or "zero"
end

function Settings:cookie()
    if self.auth and type(self.auth.active_cookie) == "function" then
        return self.auth:active_cookie(self:site_id())
    end
    if self.auth and type(self.auth.cookie) == "function" then return self.auth:cookie(self:site_id()) end
    return ""
end

function Settings:credentials()
    if self.auth and type(self.auth.credentials) == "function" then
        return self.auth:credentials(self:site_id()) or {}
    end
    return {}
end

function Settings:capabilities()
    if self.source and type(self.source.capabilities) == "function" then
        return self.source:capabilities() or {}
    end
    return {}
end

function Settings:_next_request()
    self.request_token = self.request_token + 1
    return self.request_token
end

function Settings:_is_current(request_token)
    return not self.closed and (not request_token or request_token == self.request_token)
        and (not self.view_token or type(self.shell and self.shell.is_view) ~= "function"
            or self.shell:is_view(self.view_token))
end

function Settings:_cancel_request()
    local handle = self.request_handle
    self.request_handle = nil
    if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
end

function Settings:close()
    if self.closed then return true end
    self.closed = true
    self:_next_request()
    self.busy = false
    self:_cancel_request()
    return true
end

function Settings:publish(model, request_token)
    if not self:_is_current(request_token) then return false end
    self.model_value = model or {}
    if self.shell and type(self.shell.set_model) == "function" then
        self.shell:set_model(self.model_value, self.view_token)
    end
    return self.model_value
end

function Settings:_model(state, extra)
    local cookie = self:cookie()
    local credentials = self:credentials()
    local capabilities = self:capabilities()
    local meta = self.source and type(self.source.meta) == "function" and self.source:meta() or {}
    local cookie_only = capabilities.cookie == true and capabilities.login ~= true
    local user_message = STATE_MESSAGES[state or "ready"] or tostring(state or "ready")
    local status = tonumber(extra and extra.error and extra.error.status)
    if status == 429 or status == 503 then
        user_message = "站点暂时限流，请稍后再试 (HTTP " .. status .. ")"
    end
    local actions = {
        back = function() return self.shell and self.shell:show("site_center") end,
        close = function() return self.shell and self.shell:close() end,
    }
    if self:site_id() == "zero" and self.site_manager then
        actions.set_origin = function(value) return self:set_origin(value) end
    end
    if not self.busy then
        actions.save_cookie = function(value) return self:save_cookie(value) end
        actions.clear_cookie = function() return self:clear_cookie() end
        actions.test_connection = function(callback) return self:test_connection(callback) end
        actions.reimport_cookie = function() return self:show() end
    end
    local model = {
        page = "settings",
        state = state or "ready",
        user_message = user_message,
        site_id = self:site_id(),
        site_name = meta.name or self:site_id(),
        origin = meta.origin,
        cookie = cookie,
        username = tostring(credentials.username or ""),
        password = tostring(credentials.password or ""),
        busy = self.busy,
        cookie_only = cookie_only,
        cookie_input = { value = cookie, multiline = true },
        actions = actions,
    }
    if not self.busy and not cookie_only and type(self.source and self.source.login) == "function" then
        model.actions.login = function(credentials) return self:login(credentials) end
    end
    for key, value in pairs(extra or {}) do model[key] = value end
    return model
end

function Settings:login(credentials)
    if self.busy then return false, "request_in_progress" end
    local request_token = self:_next_request()
    self:_cancel_request()
    if not self.source or type(self.source.login) ~= "function" then
        return self:_state("auth_unavailable", {
            error = { code = "auth_unavailable", site_id = self:site_id(), stage = "login" },
        }, request_token)
    end
    credentials = credentials or {}
    if tostring(credentials.username or "") == "" or tostring(credentials.password or "") == "" then
        return self:_state("credentials_required", {
            error = { code = "credentials_required", site_id = self:site_id(), stage = "login" },
        }, request_token)
    end
    self.busy = true
    self:_state("logging_in", nil, request_token)
    local handle = self.source:login({ username = credentials.username, password = credentials.password,
        question_id = credentials.question_id, answer = credentials.answer }, {
        on_success = function(result)
            if not self:_is_current(request_token) then return false end
            self.request_handle = nil
            if type(result) == "table" and result.verified == true then
                self.busy = false
                self.source.session_verified = true
                if self.auth and type(self.auth.set_credentials) == "function" then
                    self.auth:set_credentials(self:site_id(), credentials.username, credentials.password)
                end
                return self:_state("connected", { result = { verified = true } }, request_token)
            end
            if self.auth and type(self.auth.set_credentials) == "function" then
                self.auth:set_credentials(self:site_id(), credentials.username, credentials.password)
            end
            return self:_test_connection(request_token)
        end,
        on_error = function(error_result)
            if not self:_is_current(request_token) then return false end
            self.request_handle = nil
            self.busy, self.source.session_verified = false, false
            error_result = safe_error(error_result, self:site_id(), "login", "invalid_credentials")
            return self:_state(error_result.code, { error = error_result }, request_token)
        end,
    })
    if self:_is_current(request_token) and self.busy and not self.request_handle then
        self.request_handle = handle
    end
    return handle
end

function Settings:_state(state, extra, request_token)
    return self:publish(self:_model(state, extra), request_token)
end

function Settings:show()
    local request_token = self:_next_request()
    self.closed = false
    self:_cancel_request()
    self.busy = false
    return self:_state("ready", nil, request_token)
end

function Settings:set_origin(value)
    if self:site_id() ~= "zero" or not self.site_manager then
        return false, "unknown_site"
    end
    local saved, reason = self.site_manager:set_zero_origin(value)
    if not saved then return false, reason end
    self:show()
    return true
end

function Settings:model()
    return self.model_value
end

function Settings:save_cookie(cookie)
    if self.busy then return false, "request_in_progress" end
    local request_token = self:_next_request()
    if not self.source or type(self.source.set_cookie) ~= "function" then
        return self:_state("auth_unavailable", { error = { code = "auth_unavailable", site_id = self:site_id(), stage = "save_cookie" } }, request_token)
    end
    local ok, reason = self.source:set_cookie(cookie)
    self.source.session_verified = false
    if not ok then
        return self:_state(reason or "invalid_cookie", {
            error = { code = reason or "invalid_cookie", site_id = self:site_id(), stage = "save_cookie" },
        }, request_token)
    end
    return self:_state("ready", nil, request_token)
end

function Settings:clear_cookie()
    if self.busy then return false, "request_in_progress" end
    local request_token = self:_next_request()
    if self.source and type(self.source.clear_session) == "function" then self.source:clear_session()
    elseif self.auth and type(self.auth.clear) == "function" then self.auth:clear(self:site_id()) end
    if self.source then self.source.session_verified = false end
    return self:_state("ready", nil, request_token)
end

function Settings:test_connection(callback)
    if self.busy then return false, "request_in_progress" end
    local request_token = self:_next_request()
    self:_cancel_request()
    self.busy = true
    self:_state("testing", nil, request_token)
    return self:_test_connection(request_token, callback)
end

function Settings:_test_connection(request_token, callback)
    local test = self.source and (self.source.test_connection or self.source.list)
    if type(test) ~= "function" then
        local error_result = { code = "http_unavailable", site_id = self:site_id(), stage = "connection_test" }
        self.busy = false
        self:_state(error_result.code, { error = error_result }, request_token)
        if callback then callback(false, error_result) end
        return { cancel = function() end }
    end
    local callbacks = {
        on_success = function(value)
            if not self:_is_current(request_token) then return false end
            self.request_handle = nil
            self.busy, self.source.session_verified = false, true
            local result = { verified = true }
            self:_state("connected", { result = result }, request_token)
            if callback then callback(true, result) end
        end,
        on_error = function(error_result)
            if not self:_is_current(request_token) then return false end
            self.request_handle = nil
            self.busy, self.source.session_verified = false, false
            error_result = safe_error(error_result, self:site_id(), "connection_test", "network_error")
            self:_state(error_result.code, { error = error_result }, request_token)
            if callback then callback(false, error_result) end
        end,
    }
    local handle
    if test == self.source.test_connection then handle = test(self.source, callbacks)
    else handle = test(self.source, { page = 1 }, callbacks) end
    if self:_is_current(request_token) and self.busy then self.request_handle = handle end
    return handle
end

return Settings
