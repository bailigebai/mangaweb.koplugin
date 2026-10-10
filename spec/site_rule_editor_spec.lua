local Editor = require("mangaweb.ui.site_rule_editor")
assert(Editor.error_text("missing_capture_page_image") == "图片地址需要一组捕获括号",
    "a missing capture must identify the field and corrective action")

local shown, closed = {}, {}
local Dialog = {}
function Dialog:new(options)
    local dialog = { options = options, values = {} }
    for index, field in ipairs(options.fields or {}) do dialog.values[index] = field.text end
    function dialog:getFields() return self.values end
    return dialog
end
local adapter = { multi_input_dialog = Dialog }
function adapter:_input_dialog_options(options) return options end
function adapter:_show_input_dialog(dialog)
    shown[#shown + 1] = dialog
    self.input_dialog = dialog
    return true
end
function adapter:_close_input_dialog(dialog)
    closed[#closed + 1] = dialog
    if self.input_dialog == dialog then self.input_dialog = nil end
    return true
end

local saved, attempts
local editor = Editor:new{ adapter = adapter }
assert(editor:show(nil, function(value)
    attempts = (attempts or 0) + 1
    if attempts == 1 then return nil, "invalid_page_image" end
    saved = value
    return true
end))
local dialog = shown[#shown]
assert(#dialog.options.fields == 4 and dialog.options.title:find("1/4", 1, true),
    "the editor must group site identity and URL paths")
dialog.values = { "我的站", "https://example.com", "/list?page={page}", "" }
dialog.options.buttons[1][3].callback()
dialog = shown[#shown]
assert(#dialog.options.fields == 4 and dialog.options.title:find("2/4", 1, true),
    "list rules must have their own form")
dialog.values = { "(<article.-</article>)", 'href="(.-)"',
    'title="(.-)"', 'src="(.-)"' }
dialog.options.buttons[1][3].callback()
dialog = shown[#shown]
assert(#dialog.options.fields == 6 and dialog.options.title:find("3/4", 1, true),
    "detail and chapter rules must have their own form")
dialog.values = { "<h1>(.-)</h1>", 'src="(.-)"', "", "", "", "" }
dialog.options.buttons[1][3].callback()
dialog = shown[#shown]
assert(#dialog.options.fields == 4 and dialog.options.title:find("4/4", 1, true),
    "reader-path and image-array rules must be editable")
dialog.values = { "", "", "", 'src="(.-)"' }
dialog.options.buttons[1][3].callback()
dialog = shown[#shown]
assert(attempts == 1 and dialog.options.title:find("图片", 1, true)
    and dialog.values[4] == 'src="(.-)"',
    "failed saves must keep all input and show a useful error")
dialog.options.buttons[1][3].callback()
assert(attempts == 2 and saved.name == "我的站"
    and saved.rules.list_block == "(<article.-</article>)"
    and saved.rules.page_image == 'src="(.-)"',
    "saving must return the complete editable rule set")
assert(#closed > 0)

print("site_rule_editor_spec: passed")
