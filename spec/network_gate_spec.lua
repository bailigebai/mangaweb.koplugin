local Gate=require('mangaweb.network_gate')
local Http=require('mangaweb.http')
local function fixture()
    local now,ready,attempts=0,false,0
    local queue,connected={},nil
    local manager={isConnected=function()return ready end,
        runWhenConnected=function(_,cb)attempts=attempts+1;connected=cb end}
    local scheduler={scheduleIn=function(_,delay,cb)queue[cb]=now+delay end,
        unschedule=function(_,cb)queue[cb]=nil end}
    local gate=Gate:new{manager=manager,scheduler=scheduler,clock=function()return now end}
    return{gate=gate,connect=function()ready=true;if connected then connected()end end,
        advance=function(value)now=value;local due={};for cb,t in pairs(queue)do if t<=now then due[#due+1]=cb end end
            for _,cb in ipairs(due)do queue[cb]=nil;cb()end end,
        attempts=function()return attempts end,queue=queue}
end
local f=fixture()
local started,failed,canceled=0,0,0
local first=f.gate:run(function()started=started+1;return{cancel=function()canceled=canceled+1 end}end,
    function()failed=failed+1 end)
local second=f.gate:run(function()started=started+1 end,function()failed=failed+1 end)
assert(started==0 and f.attempts()==1,'coalesce offline requests and wait before sending')
second:cancel();f.connect()
assert(started==1 and failed==0 and not next(f.queue))
first:cancel();assert(canceled==1)
local t=fixture()
t.gate:run(function()error('must not send after timeout')end,function(e)assert(e.code=='network_unavailable');failed=failed+1 end)
t.advance(46);t.connect();assert(failed==1 and not next(t.queue))
local h=fixture()
local calls,results,reaped=0,0,0
local http=Http:new{network=h.gate,transport={request=function(_,spec,done)
    calls=calls+1;done(200,{},'ok');return{cancel=function()end}end,
    request_file=function()calls=calls+1;return{cancel=function()end}end}}
local waiting=http:get('https://example.com',{}, {on_success=function()results=results+1 end})
assert(calls==0,'HTTP must wait for an actual connection')
waiting:cancel();h.connect();assert(calls==0 and results==0)
local file=fixture();http.network=file.gate
local download=http:get_file('https://example.com/a.jpg',{path='/cache/a.part'},
    {on_reaped=function()reaped=reaped+1 end})
download:cancel();file.connect();assert(calls==0 and reaped==1,'waiting file requests must release their worker slot once')
local stop=fixture();http.network=stop.gate
http:get('https://example.com',{},{});http:cancel_all();stop.connect()
assert(calls==0,'app exit must cancel requests waiting for Wi-Fi')
print('network_gate_spec: passed')
