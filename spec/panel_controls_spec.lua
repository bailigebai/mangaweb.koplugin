local fixture=require('spec.helpers.reader_ui')
local Settings=require('mangaweb.settings')
local Preferences=require('mangaweb.panel_settings')
local Controls=require('mangaweb.ui.reader_panels')
local adapter,reader,manager=fixture()
local values,fail_write={},false
reader.settings=Settings:new{store={readSetting=function(_,key,d) return values[key] or d end,
    saveSetting=function(_,key,value) if fail_write then return false end;values[key]=value;return true end,
    flush=function() return true end}}
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
local configurations=0
reader.panels={configure=function(_,changes,commit)
    configurations=configurations+1;return commit()
end}
assert(find('识别强度：100%').callback())
assert(adapter.reader_controls.model.title=='识别强度')
local stale=find('＋10%')
assert(stale.callback())
assert(reader:panel_settings_snapshot().strength_percent==100 and configurations==0,
    'editing draft must not save or re-identify on every tap')
assert(stale.callback() and reader:panel_settings_snapshot().strength_percent==100)
assert(adapter.reader_controls.model.navigation[1].callback())
assert(reader:panel_settings_snapshot().strength_percent==100,'back discards draft')
assert(find('识别强度：100%').callback())
assert(find('＋10%').callback() and find('保存').callback())
assert(reader:panel_settings_snapshot().strength_percent==110 and configurations==1)
assert(find('高级识别设置').callback())
assert(find('0.5%').callback() and find('3条').callback() and find('＋1%').callback())
assert(reader:panel_settings_snapshot().min_area_permille==2 and configurations==1)
fail_write=true;assert(find('保存').callback());fail_write=false
assert(adapter.reader_controls.model.title=='高级识别设置'
    and adapter.reader_controls.model.status:find('原设置保留',1,true))
assert(find('保存').hold_callback())
assert(reader:panel_settings_snapshot().min_area_permille==5
    and reader:panel_settings_snapshot().frame_min==3 and reader:panel_settings_snapshot().dialogue_distance_percent==13)
assert(reader.panel_preferences:for_comic('zero','new').frame_min==3)
local before=reader:panel_settings_snapshot()
assert(find('高级识别设置').callback() and find('恢复识别默认').callback())
assert(reader:panel_settings_snapshot().strength_percent==110,'reset is a draft until save')
assert(find('保存').callback())
local after=reader:panel_settings_snapshot()
assert(after.strength_percent==100 and after.min_area_permille==2 and after.frame_min==1
    and after.dialogue_distance_percent==12 and after.enabled==before.enabled
    and after.view==before.view and after.rotation==before.rotation)
assert(manager.stack[#manager.stack]==page and #manager.stack==1,'numeric and advanced pages share reader window')
assert(page:onGesture{ges='unknown'})
adapter:_close_reader_controls()
assert(not page.embedded_controls and not reader.closed)
print('panel_controls_spec: single-window controls, stale callback, per-book and default save passed')
