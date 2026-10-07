local M = {}

local ERROR_MESSAGES = {
    network_error = "网络连接失败，请检查网络后重试",
    transport_error = "HTTPS 连接失败，请检查时间和网络",
    http_error = "站点请求失败，请稍后重试",
    http_unavailable = "网络功能不可用",
    invalid_credentials = "账号或密码错误",
    login_required = "登录已失效，请重新登录",
    login_unverified = "无法确认登录状态，请重新登录",
    verification_required = "站点需要浏览器验证，请重新导入 Cookie",
    invalid_cookie = "Cookie 格式无效",
    empty_result = "站点没有返回漫画，请重试",
    parse_error = "站点页面已变化，暂时无法解析",
    response_too_large = "站点响应过大，已停止加载",
    storage_error = "图片存储失败，请检查剩余空间后重试",
    image_error = "图片加载失败，请重试",
    render_error = "界面显示失败，请返回重试",
    request_timeout = "章节请求超时，请重试",
    favorite_remove_uncertain = "无法确认网页收藏是否已取消，请刷新官方收藏核对；不会自动重复取消",
}

function M.error(raw, site_id, stage, fallback)
    raw = type(raw) == "table" and raw or {}
    local function token(value, default)
        return type(value) == "string" and #value <= 64
            and value:match("^[%w_%-]+$") and value or default
    end
    local code = token(raw.code, fallback or "network_error")
    local safe_stage = token(stage or raw.stage, "request")
    local message = ERROR_MESSAGES[code] or "请求失败，请重试"
    if code == "request_timeout" and (safe_stage == "image" or safe_stage == "page") then
        message = "图片加载超时，请重试"
    elseif code == "request_timeout" and (safe_stage == "favorites" or safe_stage == "favorite_remove") then
        message = "收藏请求超时，请刷新后重试"
    elseif code == "response_too_large" and (safe_stage == "image" or safe_stage == "page") then
        message = "图片超过 64 MiB，已停止下载"
    elseif code == "http_unavailable" and (safe_stage == "image" or safe_stage == "page") then
        message = "图片下载组件不可用，请重试或更新插件"
    end
    return { site_id = token(site_id or raw.site_id), stage = safe_stage,
        code = code, status = tonumber(raw.status)
            or (type(raw.detail) == "number" and raw.detail or nil),
        user_message = message }
end

local function text(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function number(value, fallback)
    value = tonumber(value)
    if not value or value < 0 then return fallback or 0 end
    return math.floor(value)
end

local function tags(values)
    local result, seen = {}, {}
    for _, value in ipairs(values or {}) do
        value = text(value)
        if value ~= "" and not seen[value] then
            seen[value] = true
            result[#result + 1] = value
        end
    end
    return result
end

local function headers(values)
    local result = {}
    for key, value in pairs(type(values) == "table" and values or {}) do
        if type(key) == "string" and type(value) == "string" and value ~= "" then
            result[key] = value
        end
    end
    return result
end

function M.card(raw)
    raw = raw or {}
    return {
        site_id = text(raw.site_id),
        comic_id = text(raw.comic_id or raw.id),
        title = text(raw.title or raw.name),
        author = text(raw.author),
        cover_url = text(raw.cover_url),
        cover_headers = headers(raw.cover_headers),
        detail_url = text(raw.detail_url),
        tags = tags(raw.tags),
        page_count = number(raw.page_count, 0),
        updated_at = text(raw.updated_at),
    }
end

function M.detail(raw)
    raw = raw or {}
    local chapters = {}
    for _, chapter in ipairs(raw.chapters or {}) do
        chapters[#chapters + 1] = {
            id = text(chapter.id),
            title = text(chapter.title or chapter.name),
            page_count = number(chapter.page_count, 0),
        }
    end
    return {
        card = raw.card or M.card(raw),
        description = text(raw.description),
        chapters = chapters,
    }
end

function M.pages(raw)
    raw = raw or {}
    local result = {
        site_id = text(raw.site_id),
        comic_id = text(raw.comic_id or raw.id),
        pages = {},
    }
    for index, page in ipairs(raw.pages or {}) do
        result.pages[#result.pages + 1] = {
            index = number(page.index, index),
            url = text(page.url),
            headers = type(page.headers) == "table" and page.headers or {},
        }
    end
    return result
end

return M
