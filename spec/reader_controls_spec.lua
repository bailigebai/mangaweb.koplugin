local LicenseDialog = require("mangaweb.license_dialog")
local fixture = require("spec.helpers.reader_ui")

local function find_action(panel, text)
    for _, row in ipairs(panel.model.rows or {}) do
        for _, item in ipairs(row.items or {}) do
            if item.text == text then return item end
        end
    end
end

local function settings_gestures()
    local adapter, reader = fixture()
    assert(adapter:_show_reader_controls())
    local page = adapter.reader_widget
    local ok, reason = pcall(page.onGesture, page, { ges = "multiswipe" })
    assert(ok, "settings must accept an unhandled gesture without crashing: " .. tostring(reason))
    assert(page:onTap(nil, { pos = { x = 590 } }) and reader.turns == 0,
        "taps while settings are open must not turn the underlying manga page")
    for _, section in ipairs({ "reading", "preload", "display", "split", "gray", "tone", "cache" }) do
        assert(adapter:_show_reader_controls(section))
        assert(pcall(page.onGesture, page, { ges = "multiswipe" }),
            "every settings section must retain the native input contract")
    end
    assert(page:close_controls())
    assert(page:onGesture{ ges = "tap", pos = { x = 590 } })
    assert(reader.turns == 1, "returning to reading must restore edge navigation")
    assert(adapter:show_page("/raw.jpg",11,178,{processing_error="image_processing_failed"}))
    assert(page.processing_notice,"failed enhancement must explain the original-image fallback")
    assert(adapter:show_page("/raw.jpg",11,178,{}))
    assert(not page.processing_notice,"a successful page must clear the old processing notice")
end

local function license_management(fallback)
    local adapter, reader, manager = fixture()
    local license = { authorized = true, removed = 0 }
    function license:status() return self.authorized and "authorized" or "not_activated" end
    function license:is_authorized() return self.authorized end
    function license:cancel() end
    function license:activate(_, callbacks)
        self.pending = callbacks
        return { cancel = function() end }
    end
    function license:remove_local()
        if self.removal_fails then return false end
        self.authorized = false
        self.removed = self.removed + 1
        return true
    end
    local dialog = LicenseDialog:new{ license = license, ui = adapter }
    adapter.shell = { license = license, license_dialog = dialog }
    assert(adapter:_show_reader_controls())
    -- Keep the real reader/settings panel, but force the manager's Menu fallback.
    if fallback then adapter.button = nil end
    local entry = find_action(adapter.reader_controls, "授权密钥管理")
    assert(entry, "reading settings must expose license key management")
    assert(entry.callback())
    local top = manager.stack[#manager.stack]
    assert(top == adapter.license_manager_widget,
        "license management must appear above the modal manga reader")
    assert(reader.position == 11 and not reader.closed,
        "opening license management must retain the current reading session")
    local function choose(text, action)
        if not fallback then return adapter.license_manager_model.actions[action]() end
        local widget = adapter.license_manager_widget
        assert(widget, "fallback manager must remain visible")
        for _, item in ipairs(widget.item_table) do
            if item.text == text then return widget:onMenuSelect(item) end
        end
        error("missing fallback action: " .. text)
    end
    assert(choose("输入/更换密钥", "activate"))
    assert(dialog.activation_model, "selecting a key action must leave the new input window open")
    assert(dialog.activation_model.on_submit("test key"))
    license.pending.on_error("invalid_key")
    assert(dialog.activation_model.error == "invalid_key" and not reader.closed,
        "a rejected replacement key must leave the current reader open")
    assert(dialog.activation_model.on_submit("replacement key"))
    license.pending.on_success()
    assert(not reader.closed and reader.position == 11 and not adapter.license_manager_widget,
        "successful activation must return to the same reading settings")
    assert(entry.callback())
    choose("移除本机授权", "remove")
    assert(license.removed == 0, "removing authorization must first ask for confirmation")
    choose("取消", "cancel_remove")
    assert(license.removed == 0 and not reader.closed)
    choose("移除本机授权", "remove")
    license.removal_fails = true
    choose("确认移除", "confirm_remove")
    assert(not reader.closed and adapter.license_manager_model.confirming_remove,
        "failed removal must keep the reader and confirmation open")
    assert(adapter.license_manager_model.error == "移除本机授权失败，请重试。",
        "failed removal must explain why the confirmation remains open")
    license.removal_fails = false
    choose("确认移除", "confirm_remove")
    assert(license.removed == 1 and reader.closed,
        "confirmed removal must close the reading session that lost authorization")
end

local failures = {}
for _, test in ipairs({ settings_gestures, license_management,
    function() license_management(true) end }) do
    local ok, reason = pcall(test)
    if not ok then failures[#failures + 1] = tostring(reason) end
end
assert(#failures == 0, table.concat(failures, "\n"))
print("reader_controls_spec: passed")
