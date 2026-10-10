-- KOReader supplies native RapidJSON; desktop Lua uses its response-shaped substitute.
package.preload.rapidjson = function()
    return { decode = function(body)
        local replies = {
            ['{"status":0}'] = { status = 0 }, ['{"status":1}'] = { status = 1 },
            ['{"status":-1}'] = { status = -1 }, ['{"status":"0"}'] = { status = "0" },
        }
        if not replies[body] then error("invalid JSON") end
        return replies[body]
    end }
end
local Zero = require("mangaweb.sources.zero")
assert(Zero:capabilities().official_favorites == true,
    "Zero must declare official favorites support")
local cookie = "zero_auth=test-session"
local auth = { active_cookie = function() return cookie end,
    headers = function(_, _, url)
        return url:match("^https://zero.example/") and { Cookie = cookie } or {}
    end }
local source = Zero:new{ origin = "https://zero.example", auth = auth }
local function page(items, count, pager)
    return '<html><head><title>我的收藏</title></head><body><main class="my-page">'
        .. '<section class="list-summary"><span>' .. count .. ' 条记录</span></section>'
        .. '<section class="my-list">' .. (items or '') .. '</section>' .. (pager or '')
        .. '</main></body></html>'
end
local function item(id, title)
    return '<a class="list-item" href="/Android/details/?kuid=' .. id .. '">'
        .. '<img src="http://cdn.example/' .. id .. '.jpg"><div class="item-info">'
        .. '<div class="item-title">' .. title .. '</div><div class="item-meta">作者：测试作者</div></div></a>'
end
local fixture = page(item('12', '测试 &amp; 漫画'), 1)
local parsed = source:parse_favorites(fixture)
assert(not parsed.code and #parsed.cards == 1 and parsed.cards[1].comic_id == '12')
assert(parsed.cards[1].title == '测试 & 漫画' and parsed.cards[1].author == '测试作者')
assert(parsed.cards[1].cover_headers.Cookie == nil, "CDN cannot receive account cookie")
assert(source:parse_favorites(page('', 0)).total_count == 0)
assert(source:parse_favorites(page('', 9)).code == 'parse_error', "broken list is not empty")
assert(source:parse_favorites('<html><title>网站首页</title></html>').code == 'parse_error')
assert(source:parse_favorites('<form><input type="password"></form>').code == 'login_required')
assert(source:parse_favorites('<html>Just a moment...<script src="/cdn-cgi/challenge-platform/x"></script></html>').code == 'verification_required')
parsed = source:parse_favorites(page(item('12', 'A'), 40,
    '<a href="/Android/my/?type=fav&amp;page=2">2</a><a href="/Android/my/?type=history&amp;page=99">99</a>'))
assert(parsed.total_pages == 2 and parsed.total_count == 40)
assert(source:parse_favorites(page(item('bad', 'A'), 1)).code == 'parse_error')

local requests = {}
local canceled = 0
local function queue(method, url, fields, options, callbacks)
    local r = { method = method, url = url, fields = fields, options = options, callbacks = callbacks }
    requests[#requests + 1] = r
    assert(options.ui_nonblocking == true, "official requests must not block UI")
    if method == 'POST' then assert(options.no_replay == true) end
    assert(url:match('^https://zero.example/') and options.headers.Cookie == cookie)
    return { cancel = function() canceled = canceled + 1 end }
end
source.http = {
    get = function(_, url, options, callbacks) return queue('GET', url, nil, options, callbacks) end,
    post_form = function(_, url, fields, options, callbacks) return queue('POST', url, fields, options, callbacks) end,
}
local success, failure
local callbacks = { on_success = function(result) success = result end,
    on_error = function(err) failure = err end }
local function reset() requests, success, failure = {}, nil, nil end
local function reply(body)
    return requests[#requests].callbacks.on_success(body, { status = 200, headers = {} })
end
local active = '<html><a id="btn-fav" class="btn-act btn-fav active">已收藏</a>'
    .. '<script>data: { action: "toggle_fav", formhash: "abc12345" }</script></html>'
local inactive = active:gsub('btn%-fav active', 'btn-fav'):gsub('已收藏', '收藏')
source:favorites({page = 2}, callbacks)
assert(requests[1].url == 'https://zero.example/Android/my/?type=fav&page=2')
reply(fixture)
assert(success.page == 1 and #success.cards == 1)
source:favorites({page = 2}, callbacks)
reply(page(item('13','最后一页'), 21,
    '<a href="/Android/my/?type=fav&amp;page=1">上一页</a><span class="current">2</span>'))
assert(success.page == 2 and success.total_pages == 2, 'last page cannot be clamped to its previous-page link')

reset()
source:remove_favorite('12', callbacks)
assert(#requests == 1 and requests[1].method == 'GET')
reply(active)
assert(#requests == 2 and requests[2].method == 'POST')
assert(requests[2].fields.action == 'toggle_fav' and requests[2].fields.formhash == 'abc12345')
assert(requests[2].options.headers.Origin == source.origin)
reply('{"status":0}')
assert(success.removed and success.comic_id == '12' and not failure)

reset()
source:remove_favorite('12', callbacks)
reply(inactive)
assert(success.removed and #requests == 1, "already absent must not toggle into a favorite")
for _, body in ipairs({'{"status":1}', '{"status":"0"}', 'broken'}) do
    reset(); source:remove_favorite('12', callbacks); reply(active); reply(body)
    assert(failure.code == 'favorite_remove_uncertain' and not success and #requests == 2,
        "ambiguous replies must never retry toggle")
end
reset(); source:remove_favorite('12', callbacks); reply(active); reply('{"status":-1}')
assert(failure.code == 'login_required')
reset(); source:remove_favorite('12', callbacks); reply(active)
requests[2].callbacks.on_error{ code = 'request_timeout' }
assert(failure.code == 'favorite_remove_uncertain' and #requests == 2)
reset(); source:remove_favorite('12', callbacks); reply(active:gsub('formhash', 'unknown'))
assert(failure.code == 'parse_error' and #requests == 1)
reset(); source:remove_favorite('12', callbacks)
cookie = 'zero_auth=other-account'; reply(active)
assert(failure.code == 'login_required' and #requests == 1, "account switch cannot continue old removal")
reset(); local handle = source:remove_favorite('12', callbacks); reply(active)
handle:cancel(); reply('{"status":0}')
assert(canceled == 1 and success == nil and failure == nil, "cancel must cover the current POST")
reset(); local old_origin = source.origin
source:remove_favorite('12', callbacks); source.origin = 'https://another.example'; reply(active)
assert(#requests == 1 and failure.code == 'login_required')
source.origin = old_origin
reset(); source:remove_favorite('12&action=clear_all', callbacks)
assert(failure.code == 'parse_error' and #requests == 0)
source.origin = 'http://zero.example'; reset(); source:favorites({}, callbacks)
assert(failure.code == 'parse_error' and #requests == 0, "account operations require HTTPS")
source.origin = old_origin; cookie = ''; reset(); source:favorites({}, callbacks)
assert(failure.code == 'login_required' and #requests == 0)

-- A synchronous transport callback must not replace the active POST handle with the finished GET.
cookie = 'zero_auth=sync'; reset(); canceled = 0
source.http.get = function(_, url, options, cb)
    cb.on_success(active, {status = 200})
    return { cancel = function() error('finished GET cannot be the active handle') end }
end
handle = source:remove_favorite('12', callbacks)
handle:cancel()
assert(canceled == 1)
print('zero_favorites_spec: passed')
