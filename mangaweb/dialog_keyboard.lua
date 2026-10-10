local M = {}

local TOP_ICON = "control.collapse"

local function preserve_fields(dialog)
    if type(dialog) ~= "table" or type(dialog.getFields) ~= "function"
        or type(dialog.fields) ~= "table" then
        return
    end
    local called, values = pcall(dialog.getFields, dialog)
    if not called or type(values) ~= "table" then return end
    for index, value in ipairs(values) do
        if type(dialog.fields[index]) == "table" then
            dialog.fields[index].text = value
        end
    end
end

function M.hide(dialog)
    if type(dialog) ~= "table" then return false end
    preserve_fields(dialog)
    if type(dialog.onCloseKeyboard) == "function" then
        local called, result = pcall(dialog.onCloseKeyboard, dialog)
        if called and result ~= false then return true end
    end
    local input = dialog._input_widget
    if input and type(input.onCloseKeyboard) == "function" then
        local called, result = pcall(input.onCloseKeyboard, input)
        return called and result ~= false
    end
    return false
end

function M.show(dialog)
    if type(dialog) ~= "table" then return false end
    if type(dialog.onShowKeyboard) == "function" then
        local called, result = pcall(dialog.onShowKeyboard, dialog)
        if called and result ~= false then return true end
    end
    local input = dialog._input_widget
    if input and type(input.onShowKeyboard) == "function" then
        local called, result = pcall(input.onShowKeyboard, input)
        return called and result ~= false
    end
    return false
end

function M.with_top_button(options, dialog_provider, close_callback)
    options = options or {}
    options.title_bar_left_icon = TOP_ICON
    options.title_bar_left_icon_tap_callback = function()
        local dialog = dialog_provider
        if type(dialog_provider) == "function" then
            local called, provided = pcall(dialog_provider)
            if not called then return false end
            dialog = provided
        end
        return M.hide(dialog)
    end
    if type(close_callback) == "function" then
        options.right_icon = "close"
        options.right_icon_allow_flash = false
        options.right_icon_tap_callback = function()
            local dialog = dialog_provider
            if type(dialog_provider) == "function" then
                local called, provided = pcall(dialog_provider)
                if not called then return false end
                dialog = provided
            end
            local called, result = pcall(close_callback, dialog)
            return called and result ~= false
        end
    end
    return options
end

return M
