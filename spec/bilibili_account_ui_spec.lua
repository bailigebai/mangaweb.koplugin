local fixture=require('spec.helpers.reader_ui')
local UI=require('mangaweb.ui.bilibili_account')
local adapter,reader,manager=fixture()
local states,starts,cancels,logout,qr_text=nil,0,0,0,nil
local model={state='idle',status='未登录'}
local auth={model=function() return model end,
    start=function(_,callback) starts=starts+1;states=callback;callback({state='generating',status='正在生成'}) end,
    cancel=function() cancels=cancels+1 end,
    logout=function(_,cb) logout=logout+1;model={state='idle',status='未登录'};cb(model);return true end}
local QR=adapter.image_widget:extend{}
function QR:init() qr_text=self.text;self.image={};end
local ui=UI:new{adapter=adapter,auth=auth,qr_widget=QR}
assert(ui:show())
assert(manager.stack[#manager.stack].modal)
local function choose(text)
    for _,row in ipairs(ui.widget.model.rows) do
        if row.text==text and row.callback then return row.callback() end
        for _,item in ipairs(row.items or {}) do if item.text==text then return item.callback() end end
    end
    error('missing '..text)
end
choose('扫码登录');assert(starts==1)
states({state='waiting_scan',status='请扫码',qr_url='https://passport.bilibili.com/h5-app/passport/login/scan?test=1'})
assert(qr_text=='https://passport.bilibili.com/h5-app/passport/login/scan?test=1' and #manager.stack==2)
local before=ui.widget
states({state='waiting_scan',status='请扫码',qr_url='https://passport.bilibili.com/h5-app/passport/login/scan?test=1'})
assert(ui.widget==before,'unchanged poll status must not rebuild the QR every two seconds')
assert(before:onGesture{ges='unknown'})
ui:close();assert(cancels==1 and #manager.stack==1)
states({state='connected',status='已登录',account={uid='123',name='昵称'}})
assert(ui.widget==nil,'late state must not reopen a closed window')
local old_states=states
assert(ui:show())
local reopened=ui.widget
old_states({state='connected',status='旧回调',account={uid='999',name='旧账号'}})
assert(ui.widget==reopened and not ui.widget.model.status:find('旧回调',1,true),
    'a previous open must not update a new window of the same controller')
ui.widget:onCloseWidget()
assert(ui.closed and ui.widget==nil and #manager.stack==1,
    'external window removal must cancel authentication and release the panel')
local broken_adapter=fixture()
local broken=UI:new{adapter=broken_adapter,auth=auth,qr_widget=QR}
local original_face=broken_adapter.font.getFace
broken_adapter.font.getFace=function() return nil end
local safe,shown=pcall(broken.show,broken)
assert(safe and shown==false and broken.closed,
    'a missing native face must close the controller without leaving authentication active')
broken_adapter.font.getFace=original_face
broken_adapter.vertical_group.new=function() error('layout failed') end
safe,shown=pcall(broken.show,broken)
assert(safe and shown==false and broken.closed,
    'a native layout exception must not escape into KOReader')
local no_qr=UI:new{adapter=adapter,auth=auth,qr_widget=false}
assert(no_qr:show());local panel=no_qr.widget
for _,row in ipairs(panel.model.rows) do if row.callback then row.callback();break end end
assert(starts==1 and no_qr.widget.model.status:find('二维码控件不可用',1,true))
no_qr:close()
local settings=require('mangaweb.ui.settings'):new{source={id='bilibili',
    meta=function() return {name='哔哩哔哩漫画',origin='https://manga.bilibili.com'} end,
    capabilities=function() return {qr_login=true,login=false} end,account_auth=auth},
    shell={ui=adapter,set_model=function() return true end}}
settings:show()
assert(settings:model().actions.bilibili_account and not settings:model().actions.login
    and not settings:model().password and not settings:model().cookie)
print('bilibili_account_ui_spec: local QR rendering, modal ownership, missing widget and late state guards passed')
