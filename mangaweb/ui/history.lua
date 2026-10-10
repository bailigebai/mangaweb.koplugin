local History = {}
History.__index = History

function History:new(options) return setmetatable(options or {}, self) end
function History:show()
    local site_id = self.source_registry:current_id()
    local items = self.store and self.store:list_history(site_id) or {}
    return self.shell:set_model({ page = "history", items = items, state = #items == 0 and "empty" or "ready" },
        self.view_token)
end

return History
