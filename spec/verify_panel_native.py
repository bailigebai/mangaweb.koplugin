"""Verify panel LUT application on real LuaJIT FFI allocations (not Kindle)."""
from pathlib import Path
from lupa.luajit21 import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('package.path = ... .. package.path', f'{root.as_posix()}/?.lua;')
lua.execute(r'''
local ffi=require('ffi')
ffi.cdef('typedef struct { int w,h,stride,type,inverse; unsigned char *data; } BlitBuffer8;')
local freed=0
ffi.metatype('BlitBuffer8',{__index={getType=function(self) return self.type end,
    getInverse=function(self) return self.inverse end,
    getWidth=function(self) return self.w end,getHeight=function(self) return self.h end,
    free=function() freed=freed+1 end}})
package.preload['ffi/blitbuffer']=function() return {TYPE_BB8=1} end
local pixels=ffi.new('unsigned char[6]',{40,128,238,40,128,238})
local raw=ffi.new('BlitBuffer8',{w=3,h=2,stride=3,type=1,inverse=0,data=pixels})
local opened
local source={open=function(_,_,request,cb)
    opened=request.page_path
    cb.on_ready({render=function() return raw end,close=function() end,
        detection_raster=function() return {width=3,height=2} end})
    return {cancel=function() end}
end}
local Rendering=require('mangaweb.panel_rendering')
local result
Rendering:new{source=source,settings={gray_enabled=true,gray_preset='clear',
    tone_enabled=true,tone_preset='clear'}}:open(1,
    {page_path='/cached/original.jpg',screen_width=600,screen_height=800},
    {on_ready=function(handle) result=assert(handle:render({x=0,y=0,w=1,h=1},{}));handle:close() end})
assert(opened=='/cached/original.jpg' and result.w==3 and result.h==2 and freed==0)
-- Hand-derived: clear maps black 40 -> 0, white 238 -> 255;
-- middle: round(255*(88/198)^1.2) = 96; contrast 120% -> 90.
assert(pixels[0]==0 and pixels[1]==90 and pixels[2]==255)
result:free();assert(freed==1)
print('verify_panel_native: passed; real FFI LUT pixels and caller-owned release')
''')
