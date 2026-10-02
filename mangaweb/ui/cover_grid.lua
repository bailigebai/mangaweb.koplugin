local CoverGrid = {}
CoverGrid.__index = CoverGrid

function CoverGrid:new(options)
    options = options or {}
    return setmetatable({
        columns = 4,
        width = math.max(200, math.floor(tonumber(options.width) or 600)),
        gap = math.max(0, math.floor(tonumber(options.gap) or 8)),
    }, self)
end

function CoverGrid:build(cards, actions)
    cards, actions = cards or {}, actions or {}
    local cover_width = math.floor((self.width - (self.columns - 1) * self.gap) / self.columns)
    local cover_height = math.floor(cover_width * 1.5)
    local cells = {}
    for index, card in ipairs(cards) do
        cells[#cells + 1] = {
            index = index,
            site_id = card.site_id,
            comic_id = card.comic_id,
            title = card.title,
            cover_url = card.cover_url,
            cover_headers = card.cover_headers,
            cover_width = cover_width,
            cover_height = cover_height,
            tags = card.tags or {},
            favorite = card.favorite == true,
            progress = card.progress,
            on_tap = function() return actions.on_card and actions.on_card(card) end,
            on_tag = function(tag) return actions.on_tag and actions.on_tag(tag) end,
        }
    end
    return {
        columns = self.columns,
        cover_width = cover_width,
        cover_height = cover_height,
        cells = cells,
    }
end

return CoverGrid
