local ButtonStyle = {}

function ButtonStyle.extend(base, screen, blitbuffer)
    if not base or type(base.extend) ~= "function" then return base end
    local scale = screen and type(screen.scaleBySize) == "function"
        and function(value) return screen:scaleBySize(value) end
        or function(value) return value end
    local Button = base:extend{
        no_focus = true,
        bordersize = scale(1),
        radius = 0,
        padding_h = scale(5),
        padding_v = scale(1),
        text_font_size = scale(16),
        text_font_bold = false,
        background = blitbuffer
            and (blitbuffer.COLOR_LIGHT_GRAY or blitbuffer.COLOR_WHITE)
            or nil,
    }
    function Button:onTapSelectButton()
        if (self.enabled ~= false or self.allow_tap_when_disabled) and self.callback then
            pcall(self.callback)
        end
        return true
    end
    return Button
end

return ButtonStyle
