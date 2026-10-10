local Source = require('mangaweb.panel_source')
local Session = require('mangaweb.panel_session')
local live, peak, created, queued = 0, 0, {}, {}
local function allocation(w,h)
    live=live+1; peak=math.max(peak,live)
    local b={getWidth=function() return w end,getHeight=function() return h end}
    function b:free() assert(not self.freed,'double free'); self.freed=true;live=live-1 end
    created[#created+1]=b
    return b
end
local borrowed={getWidth=function() return 1200 end,getHeight=function() return 1600 end,
    free=function() error('reader buffer is borrowed') end}
function borrowed:viewport(_,_,w,h)
    local view={free=function() end}
    function view:scale(tw,th) return allocation(tw,th) end
    return view
end
local source=Source:new{mupdf=false,draw_context=false}
local session=Session:new{source=source,screen_width=600,screen_height=800,
    detector={detect=function() return {
        {id='one',x=0,y=0,w=1,h=0.5},{id='two',x=0,y=0.5,w=1,h=0.5},
    } end},schedule=function(fn) queued[#queued+1]=fn end}
assert(session:start({generation=1,page_buffer=borrowed}, {on_panel=function(b)
    assert(b:getWidth()*b:getHeight()<=720000);return true
end}))
queued[1]()
assert(live==2,'only current and next panel remain allocated')
assert(session:move(1));session:close();session:close()
for _,fn in ipairs(queued) do fn() end
assert(live==0 and peak<=2,'late pre-render cannot retain any allocation after close')
for _,b in ipairs(created) do assert(b.freed) end
print('panel_memory_spec: borrowed source, bounded buffers and cancellation passed')
