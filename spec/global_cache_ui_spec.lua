local Ui=require('mangaweb.ui.cache_manager')
local Settings=require('mangaweb.settings')
local saved={}
local settings=Settings:new{store={readSetting=function(_,k,d)return saved[k]or d end,
    saveSetting=function(_,k,v)saved[k]=v;return true end,flush=function()return true end}}
local manager={policy=function()return settings:cache_policy()end,
    stats=function()return{total_bytes=100,protected_bytes=20,pages_bytes=60,covers_bytes=30,catalogues_bytes=10}end,
    configure=function(_,p)return settings:save_cache_policy(p)end,
    check=function(_,force,done)done{total_bytes=20,protected_bytes=20,freed_bytes=80,reason='cleaned'};return true end}
local current,route
local shell={is_view=function()return true end,set_model=function(_,m)current=m;return true end,
    show=function(_,p)route=p;return true end}
local controller=Ui:new{manager=manager,shell=shell,view_token=1}
assert(controller:show() and current.page=='global_cache' and current.stats.total_bytes==100)
assert(current.actions.save{upper_mb=128,lower_mb=96,interval_minutes=2})
assert(settings:cache_policy().interval_minutes==2)
current.actions.check();assert(current.stats.total_bytes==20 and current.stats.freed_bytes==80)
current.actions.back();assert(route=='site_center')
local SiteCenter=require('mangaweb.ui.site_center')
shell.cache_manager=manager
SiteCenter:new{shell=shell,source_registry={sources={},ids=function()return{}end}}:show()
assert(type(current.actions.manage_cache)=='function')
current.actions.manage_cache();assert(route=='global_cache')
local adapter,reader,stack=require('spec.helpers.reader_ui')()
adapter.multi_input_dialog=adapter.single_input_dialog
local draft={'128','96','2'}
local function action(p)return manager:configure(p)end
assert(Ui.edit(adapter,manager:policy(),action))
local input=adapter.input_dialog
assert(input.modal==true and #input.fields==3 and stack.stack[#stack.stack]==input,
    'all numeric inputs must be in one modal window above the reader')
input.getFields=function()return draft end
draft={'64','100','2'};input.buttons[1][2].callback()
assert(adapter.input_dialog==input,'invalid settings must keep the editable dialog open')
draft={'256','192','10'};input.buttons[1][2].callback()
assert(not adapter.input_dialog and not reader.closed and settings:cache_policy().upper_mb==256)
assert(Ui.edit(adapter,manager:policy(),function()return false end))
input=adapter.input_dialog;input.getFields=function()return draft end;input.buttons[1][2].callback()
assert(adapter.input_dialog==input,'save failure must not close the window')
adapter:_close_input_dialog()
input.buttons[1][2].callback();assert(settings:cache_policy().upper_mb==256,'stale dialog callbacks must do nothing')
print('global_cache_ui_spec: passed')
