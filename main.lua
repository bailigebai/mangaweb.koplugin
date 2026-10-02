local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local App = require("mangaweb.app")
local Transport = require("mangaweb.transport")

local MangaWeb = WidgetContainer:extend{
    name = "mangaweb",
    is_doc_only = false,
}

function MangaWeb:init()
    if self.initialized then return end
    self.initialized = true
    Transport.ensure_native()
    Dispatcher.registerAction(Dispatcher, "show_manga_web", {
        category = "none",
        event = "ShowMangaWeb",
        title = "漫画网站",
        general = true,
    })
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu.registerToMainMenu(self.ui.menu, self)
    end
end

function MangaWeb:onShowMangaWeb()
    self.app = self.app or App:new{ ui = self.ui }
    return self.app:show()
end

function MangaWeb:addToMainMenu(menu_items)
    menu_items.mangaweb = {
        text = "漫画网站",
        callback = function() return self:onShowMangaWeb() end,
    }
end

function MangaWeb:stopPlugin()
    if self.app then self.app:close("plugin_stop") end
    return true
end

function MangaWeb:onExit()
    return self:stopPlugin(true)
end

return MangaWeb
