local Auth=require('mangaweb.bilibili_auth')
local Settings=require('mangaweb.settings')
local Session=require('mangaweb.bilibili_session')
local function fixture()
    local calls,timers,values,states={},{},{},{}
    local api={}
    for _,method in ipairs({'generate_qr','poll_qr','verify_account','verify_manga'}) do
        api[method]=function(_,...)
            local args={...};local cb=args[#args]
            local call={method=method,cb=cb,args=args,cancels=0}
            calls[#calls+1]=call
            return {cancel=function() call.cancels=call.cancels+1 end}
        end
    end
    local scheduler={after=function(delay,cb)
        local timer={delay=delay,cb=cb,cancelled=false};timers[#timers+1]=timer
        return {cancel=function() timer.cancelled=true end}
    end}
    local store={readSetting=function(_,key,d) return values[key] or d end,
        saveSetting=function(_,key,value) values[key]=value;return true end,flush=function()
            if values.on_flush then values.on_flush() end
            return not values.fail
        end}
    local session=Session:new{settings=Settings:new{store=store},sha256=function() return string.rep('a',64) end}
    assert(session:save({uid='1',name='旧账号'},'DedeUserID=1; SESSDATA=old_session'))
    local auth=Auth:new{api=api,session=session,scheduler=scheduler}
    local listener=function(model) states[#states+1]=model end
    local function fire(delay)
        for _,timer in ipairs(timers) do
            if timer.delay==delay and not timer.cancelled and not timer.fired then
                timer.fired=true;timer.cb();return
            end
        end
        error('no timer '..delay)
    end
    return auth,calls,timers,session,listener,fire,values
end
local auth,calls,timers,session,listen,fire=fixture()
auth:start(listen);assert(calls[1].method=='generate_qr')
calls[1].cb.on_success{url='https://passport.bilibili.com/scan',key='test_key'}
assert(#calls==1 and auth:model().state=='waiting_scan')
fire(2);assert(#calls==2 and calls[2].method=='poll_qr')
calls[2].cb.on_success{code=86101};calls[2].cb.on_success{code=86101}
fire(2);assert(#calls==3,'duplicate success cannot schedule a second polling chain')
calls[3].cb.on_success{code=86090};assert(auth:model().state=='waiting_confirm')
fire(300);assert(auth:model().state=='expired')
calls[3].cb.on_success{code=0,headers={['set-cookie']='DedeUserID=2; SESSDATA=new'}}
assert(session:account().uid=='1' and #calls==3)
local closed,pending,_,old,listener,advance=fixture()
closed:start(listener);pending[1].cb.on_success{url='https://passport.bilibili.com/scan',key='old_key'}
advance(2);closed:cancel();pending[2].cb.on_success{code=0,headers={}}
assert(#pending==2 and old:account().uid=='1' and pending[2].cancels==1)
local switch,requests,_,current,listener,advance,values=fixture()
switch:start(listener);requests[1].cb.on_success{url='https://passport.bilibili.com/scan',key='new_key'}
advance(2);requests[2].cb.on_success{code=0,headers={['set-cookie']='DedeUserID=2; Path=/, SESSDATA=new_session; Path=/'}}
assert(requests[3].method=='verify_account' and current:account().uid=='1')
requests[3].cb.on_success{uid='2',name='新账号'}
assert(requests[4].method=='verify_manga' and current:account().uid=='1')
values.fail=true;requests[4].cb.on_success{}
assert(switch:model().state=='error' and current:account().uid=='1')
values.fail=false;assert(switch:logout(listener));assert(current:account()==nil)
assert(switch:model().state=='idle' and not switch:model().key and not switch:model().cookie)
local race,race_calls,_,race_session,listener,advance,race_values=fixture()
race:start(listener);race_calls[1].cb.on_success{url='https://passport.bilibili.com/scan',key='race_key'}
advance(2);race_calls[2].cb.on_success{code=0,headers={['set-cookie']='DedeUserID=2; Path=/, SESSDATA=new_session; Path=/'}}
race_calls[3].cb.on_success{uid='2',name='新账号'}
race_values.on_flush=function() race_values.on_flush=nil;race:cancel() end
race_calls[4].cb.on_success{}
assert(race_session:account().uid=='1','close reentered during persistence must roll back candidate')
local verified,check_calls,_,saved,notify=fixture()
verified:verify_saved(notify)
check_calls[1].cb.on_success{uid='1',name='旧账号'}
check_calls[2].cb.on_success{}
assert(verified:model().verified and verified:model().state=='connected')
verified:verify_saved(notify)
check_calls[3].cb.on_error{code='auth_required'}
assert(verified:model().state=='error' and not verified:model().verified,
    'failed saved-account revalidation must invalidate the previous verification')
verified:cancel()
assert(verified:model().state=='idle' and not verified:model().verified and saved:account().uid=='1',
    'closing after failed revalidation keeps credentials but must not restore connected')
-- Switching to a candidate is a separate operation: its failure preserves the
-- previously verified account, including its valid connection state.
local candidate,candidate_calls,_,kept,notify,advance=fixture()
candidate:verify_saved(notify)
candidate_calls[1].cb.on_success{uid='1',name='旧账号'}
candidate_calls[2].cb.on_success{}
candidate:start(notify)
candidate_calls[3].cb.on_success{url='https://passport.bilibili.com/scan',key='switch_key'}
advance(2)
candidate_calls[4].cb.on_success{code=0,headers={['set-cookie']='DedeUserID=2; Path=/, SESSDATA=new_session; Path=/'}}
candidate_calls[5].cb.on_error{code='auth_required'}
assert(candidate:model().state=='error' and candidate:model().verified and kept:account().uid=='1')
candidate:cancel()
assert(candidate:model().state=='connected' and candidate:model().verified)
print('bilibili_auth_spec: serial polls, deadline, late callbacks and atomic switch/logout passed')
