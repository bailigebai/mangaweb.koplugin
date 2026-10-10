-- Originals use a fresh namespace: legacy reader entries did not distinguish
-- authenticated downloads. Credentials never become file names or log fields.
local Crypto = require("mangaweb.license_crypto")
local Identity = {}

local function field(value)
    value = tostring(value or "")
    return tostring(#value) .. ":" .. value
end

function Identity.scope(headers, sha256)
    local credentials = {}
    for name, value in pairs(headers or {}) do
        local normalized = tostring(name):lower()
        if normalized == "cookie" or normalized == "authorization" then
            credentials[#credentials + 1] = field(normalized) .. field(value)
        end
    end
    table.sort(credentials)
    if #credentials == 0 then return "public" end
    local ok, digest = pcall(sha256 or Crypto.sha256, table.concat(credentials))
    if not ok or type(digest) ~= "string" or #digest ~= 64
        or not digest:match("^[0-9a-f]+$") then return nil end
    return digest
end

function Identity.page(spec, headers, sha256)
    local scope = Identity.scope(headers or spec.headers, sha256)
    if not scope then return nil end
    local chapter = spec.chapter_id or spec.default_chapter_id
    chapter = "page-v2:" .. field(chapter) .. ":" .. scope
    return { site_id = spec.site_id, comic_id = spec.comic_id, chapter_id = chapter,
        index = spec.index, url = spec.url }
end

-- A cover is independent of the selected chapter and display size. Keep its
-- bounded original separate from reader pages, while thumbnails retain their
-- existing per-size identities.
function Identity.cover(spec, headers, sha256)
    local scope = Identity.scope(headers or spec.headers, sha256)
    if not scope then return nil end
    return { site_id = spec.site_id, comic_id = spec.comic_id,
        chapter_id = "cover-original-v1:" .. scope, index = 1, url = spec.url }
end

return Identity
