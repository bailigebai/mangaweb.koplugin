local Settings=require('mangaweb.settings')
local Preferences=require('mangaweb.panel_settings')
local data,fail_write,fail_flush={},false,false
local store={readSetting=function(_,key,default) return data[key] or default end,
    saveSetting=function(_,key,value) if fail_write then return false end;data[key]=value;return true end,
    flush=function() if fail_flush=='throw' then error('disk') end;return not fail_flush end}
local settings=Settings:new{store=store}
local prefs=Preferences:new{settings=settings}
assert(prefs:for_comic('zero','1').enabled==false)
local defaults=prefs:for_comic('zero','1')
assert(defaults.strength_percent==100 and defaults.min_area_permille==2
    and defaults.frame_min==1 and defaults.dialogue_distance_percent==12,
    'recognition defaults must match current algorithm')
assert(prefs:save('zero','tuning',{strength_percent=150,min_area_permille=5,
    frame_min=3,dialogue_distance_percent=20},false))
assert(prefs:for_comic('zero','other').strength_percent==100)
for _,invalid in ipairs({{strength_percent=49},{strength_percent=201},{strength_percent=100.5},
    {strength_percent=0/0},{strength_percent=math.huge},{min_area_permille=3},
    {frame_min=0},{frame_min=5},{dialogue_distance_percent=4},{dialogue_distance_percent=26}}) do
    assert(not prefs:save('zero','tuning',invalid,true), 'invalid detection settings must be rejected')
end
assert(prefs:save('zero','tuning',{view='cut',rotation=90,enabled=true},false))
assert(prefs:save('zero','tuning',Preferences.detection_defaults(),false))
local reset=prefs:for_comic('zero','tuning')
assert(reset.strength_percent==100 and reset.min_area_permille==2 and reset.frame_min==1
    and reset.dialogue_distance_percent==12 and reset.view=='cut' and reset.rotation==90 and reset.enabled)
assert(prefs:save('zero','1',{enabled=true,view='cut',rotation=90},false))
assert(prefs:for_comic('bilibili','1').enabled==false)
assert(prefs:save('zero','2',{enabled=true,view='free'},true))
assert(prefs:for_comic('bilibili','1').view=='free')
local old=prefs:for_comic('zero','1')
for _,values in ipairs({{rotation=45},{view='bad'},{margin_percent=3},{enabled=1},{order='bad'}}) do
    assert(not prefs:save('zero','1',values,true))
end
for _,failure in ipairs({'write','flush','throw'}) do
    fail_write=failure=='write';fail_flush=failure=='throw' and 'throw' or failure=='flush'
    assert(not prefs:save('zero','1',{view='context',enabled=false},true))
    assert(prefs:for_comic('zero','1').view==old.view and prefs:for_comic('new','new').view=='free')
    fail_write,fail_flush=false,false
end
prefs=Preferences:new{settings=settings}
for i=1,64 do assert(prefs:save('zero',tostring(i),{view='context'})) end
prefs:for_comic('zero','1')
assert(prefs:save('zero','65',{view='cut'}))
assert(prefs:for_comic('zero','1').view=='context')
assert(prefs:for_comic('zero','2').view=='free','oldest untouched record evicted; defaults retained')
print('panel_settings_spec: validation, site isolation, LRU and atomic rollback passed')
