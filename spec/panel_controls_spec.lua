local fixture=require('spec.helpers.reader_ui')
local Settings=require('mangaweb.settings')
local Preferences=require('mangaweb.panel_settings')
local Controls=require('mangaweb.ui.reader_panels')
local adapter,reader,manager=fixture()
local values={}
reader.settings=Settings:new{store={readSetting=function(_,key,d) return values[key] or d end,
    saveSetting=function(_,key,value) values[key]=value;return true end,flush=function() return true end}}
reader.context={site_id='zero',comic_id='current'}
reader.panel_preferences=Preferences:new{settings=reader.settings}
function reader:panel_settings_snapshot() return self.panel_preferences:for_comic('zero','current') end
function reader:exit_panel_mode() return true end
local controls=Controls:new{adapter=adapter,reader=reader,settings=reader.panel_preferences}
local page=adapter.reader_widget
local function find(text)
    for _,row in ipairs(adapter.reader_controls.model.rows) do
        for _,item in ipairs(row.items or {}) do if item.text==text then return item end end
    end
    error('missing action '..text)
end
assert(controls:show())
local old=find('智能分格：关闭')
assert(old.callback())
assert(reader:panel_settings_snapshot().enabled and not reader.panel_preferences:for_comic('zero','other').enabled)
assert(old.callback() and reader:panel_settings_snapshot().enabled,'stale controls cannot toggle again')
local button=find('保留周边')
assert(button.hold_callback())
assert(reader.panel_preferences:for_comic('zero','other').enabled)
assert(manager.stack[#manager.stack]==page and #manager.stack==1)
assert(page:onGesture{ges='unknown'})
adapter:_close_reader_controls()
assert(not page.embedded_controls and not reader.closed)
print('panel_controls_spec: single-window controls, stale callback, per-book and default save passed')
