local SiteCenter = {}
SiteCenter.__index = SiteCenter

function SiteCenter:new(options)
    options = options or {}
    return setmetatable({
        shell = assert(options.shell, "shell is required"),
        registry = assert(options.source_registry, "source_registry is required"),
        auth = options.auth,
        license = options.license,
        license_dialog = options.license_dialog,
        site_manager = options.site_manager,
        view_token = options.view_token,
    }, self)
end

function SiteCenter:show()
    local sites = {}
    local definitions = {}
    if self.site_manager and type(self.site_manager.list) == "function" then
        for _, definition in ipairs(self.site_manager:list()) do
            definitions[definition.id] = definition
        end
    end
    for _, id in ipairs(self.registry:ids()) do
        local site_id = id
        local source = self.registry.sources[site_id]
        local meta = source and source.meta and source:meta() or {}
        local capabilities = source and source.capabilities and source:capabilities() or {}
        local cookie = self.auth and self.auth.active_cookie
            and self.auth:active_cookie(site_id)
            or self.auth and self.auth.cookie and self.auth:cookie(site_id) or ""
        local has_cookie = cookie ~= ""
        local connected = has_cookie and source and source.session_verified == true or false
        if capabilities.qr_login and source.account_auth then
            local account=source.account_auth:model()
            has_cookie=account.account~=nil
            connected=has_cookie and account.verified==true
        end
        local status_code = connected and "connected" or has_cookie and "session_unverified" or "not_configured"
        sites[#sites + 1] = {
            id = site_id,
            name = meta.name or site_id,
            origin = meta.origin,
            connected = connected,
            has_cookie = has_cookie,
            status_code = status_code,
            status = status_code == "connected" and "已验证"
                or status_code == "session_unverified" and "会话已保存，尚未验证" or "未配置",
            cookie_only = capabilities.cookie == true and capabilities.login ~= true,
            custom = definitions[site_id] ~= nil,
            definition = definitions[site_id],
            on_open = function() return self.shell:show_site(site_id) end,
            on_config = function() return self.shell:show_settings(site_id) end,
        }
    end
    local license_status = "invalid"
    if self.license and type(self.license.status) == "function" then
        local called, value = pcall(self.license.status, self.license)
        if called and (value == "authorized" or value == "not_activated" or value == "invalid") then
            license_status = value
        end
    end
    local actions = {}
    if self.site_manager then
        actions.add_site = function(definition)
            local created, reason = self.site_manager:add(definition)
            if not created then return nil, reason end
            self:show()
            return created
        end
        actions.update_site = function(site_id, definition)
            local updated, reason = self.site_manager:update(site_id, definition)
            if not updated then return nil, reason end
            self:show()
            return updated
        end
        actions.remove_site = function(site_id)
            local removed, reason = self.site_manager:remove(site_id)
            if not removed then return false, reason end
            self:show()
            return true
        end
    end
    if self.license_dialog and type(self.license_dialog.show_manager) == "function" then
        actions.manage_license = function()
            return self.license_dialog:show_manager(function()
                if self.shell:is_view(self.view_token) then self:show() end
            end)
        end
    end
    return self.shell:set_model({
        page = "site_center", sites = sites, state = "ready",
        license_status = license_status, actions = actions,
    }, self.view_token)
end

return SiteCenter
