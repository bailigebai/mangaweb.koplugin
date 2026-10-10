local Auth = {}
Auth.__index = Auth

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function host(url)
    return trim(url):match("^https?://([^/%?#]+)")
end

local LEGACY_COOKIE_ORIGINS = { zero = "https://www.zerobyw33.com" }

local function valid_cookie(value)
    value = trim(value)
    if value == "" or value:find("[%c]", 1) then return false end
    for part in value:gmatch("[^;]+") do
        if not part:match("^%s*[%w_%-]+%s*=%s*[^=;%s][^;]*%s*$") then return false end
    end
    return true
end

function Auth:new(options)
    options = options or {}
    return setmetatable({
        settings = assert(options.settings, "settings is required"),
        http = options.http,
        origins = options.origins or {},
        login_paths = options.login_paths or {},
    }, self)
end

function Auth:cookie(site_id)
    return trim(self.settings:read("cookie:" .. tostring(site_id), ""))
end

function Auth:active_cookie(site_id)
    local origin = self.origins[site_id]
    local bound = self.settings:read("cookie_origin:" .. tostring(site_id),
        LEGACY_COOKIE_ORIGINS[site_id])
    if not origin or not bound or host(origin) ~= host(bound) then return "" end
    return self:cookie(site_id)
end

function Auth:credentials(site_id)
    site_id = tostring(site_id)
    return {
        username = trim(self.settings:read("credential:" .. site_id .. ":username", "")),
        password = trim(self.settings:read("credential:" .. site_id .. ":password", "")),
    }
end

function Auth:set_credentials(site_id, username, password)
    site_id = tostring(site_id)
    username, password = trim(username), trim(password)
    if username == "" or password == "" then return false, "credentials_required" end
    self.settings:write("credential:" .. site_id .. ":username", username)
    self.settings:write("credential:" .. site_id .. ":password", password)
    if self.settings.flush then self.settings:flush() end
    return true
end

function Auth:clear_credentials(site_id)
    site_id = tostring(site_id)
    self.settings:write("credential:" .. site_id .. ":username", "")
    self.settings:write("credential:" .. site_id .. ":password", "")
    if self.settings.flush then self.settings:flush() end
    return true
end

function Auth:set_cookie(site_id, cookie)
    cookie = trim(cookie)
    if not valid_cookie(cookie) then return false, "invalid_cookie" end
    self.settings:write("cookie:" .. tostring(site_id), cookie)
    self.settings:write("cookie_origin:" .. tostring(site_id), self.origins[site_id] or "")
    if self.settings.flush then self.settings:flush() end
    return true
end

function Auth:clear(site_id)
    self.settings:write("cookie:" .. tostring(site_id), "")
    self.settings:write("cookie_origin:" .. tostring(site_id), "")
    if self.settings.flush then self.settings:flush() end
    return true
end

function Auth:headers(site_id, url)
    local result = {}
    local origin = self.origins[site_id]
    if origin and host(origin) == host(url) then
        local cookie = self:active_cookie(site_id)
        if cookie ~= "" then result.Cookie = cookie end
        result.Referer = origin .. "/"
    end
    return result
end

function Auth:login_form(site_id, credentials, callback)
    if not self.http then
        if callback and callback.on_error then callback.on_error({ code = "http_unavailable", site_id = site_id }) end
        return { cancel = function() end }
    end
    local origin = assert(self.origins[site_id], "origin is required")
    local path = self.login_paths[site_id] or "/login"
    local fields = credentials and (credentials.fields or credentials) or {}
    return self.http:post_form(origin .. path, fields, {
        site_id = site_id, stage = "login", headers = { Referer = origin .. "/" },
    }, callback)
end

function Auth.redact(value)
    value = tostring(value or "")
    value = value:gsub("([Pp]assword%s*[:=]%s*)[^;,%s]+", "%1[redacted]")
    value = value:gsub("([Cc]ookie%s*[:=]%s*)[^;\r\n]+", "%1[redacted]")
    value = value:gsub("([Cc][Ff]_[Cc][Ll][Ee][Aa][Rr][Aa][Nn][Cc][Ee]%s*=%s*)[^;,%s]+", "%1[redacted]")
    return value
end

return Auth
