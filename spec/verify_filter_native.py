"""Exercise the pixel mapper with real LuaJIT FFI buffers on the desktop."""
from pathlib import Path
from lupa.luajit21 import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("package.path = %r .. package.path" % (f"{root.as_posix()}/?.lua;{root.as_posix()}/?/init.lua;"))
lua.execute(r'''
local ffi = require("ffi")
for _, name in ipairs({"BlitBuffer8","BlitBuffer8A","BlitBufferRGB24","BlitBufferRGB32"}) do
    ffi.cdef("typedef struct { int w,h,stride,type,inverse; unsigned char *data; } "..name..";")
    ffi.metatype(name,{__index={getType=function(self)return self.type end,
        getInverse=function(self)return self.inverse end}})
end
local BB={TYPE_BB8=1,TYPE_BB8A=2,TYPE_BBRGB24=3,TYPE_BBRGB32=4}
package.preload["ffi/blitbuffer"]=function()return BB end
local Gray=require("mangaweb.gray_enhance")
local Tone=require("mangaweb.tone_adjust")
local clear=Gray.build_lut(Gray.find("clear"))
assert(clear[0]==0 and clear[40]==0 and clear[238]==255 and clear[255]==255)
for input=1,255 do assert(clear[input]>=clear[input-1]) end
local types={{"BlitBuffer8",1},{"BlitBuffer8A",2},{"BlitBufferRGB24",3},{"BlitBufferRGB32",4}}
local layouts=0
for _,kind in ipairs(types)do
    local step=kind[2]
    for inverse=0,1 do
        local stride=3*step+3
        local data=ffi.new("unsigned char[?]",stride*2)
        ffi.fill(data,stride*2,77)
        for row=0,1 do
            for pixel,value in ipairs({40,128,238})do
                local offset=row*stride+(pixel-1)*step
                data[offset]=inverse==1 and 255-value or value
                if step>=3 then data[offset+1]=data[offset];data[offset+2]=data[offset] end
                if step==2 then data[offset+1]=123 end
                if step==4 then data[offset+3]=123 end
            end
        end
        local buffer=ffi.new(kind[1],{w=3,h=2,stride=stride,type=step,inverse=inverse,data=data})
        assert(Gray.apply_lut(buffer,clear))
        for row=0,1 do
            for pixel,value in ipairs({40,128,238})do
                local offset=row*stride+(pixel-1)*step
                local expected=inverse==1 and 255-clear[value] or clear[value]
                assert(data[offset]==expected)
                if step>=3 then assert(data[offset+1]==expected and data[offset+2]==expected) end
                if step==2 then assert(data[offset+1]==123) end
                if step==4 then assert(data[offset+3]==123) end
            end
            for offset=3*step,stride-1 do assert(data[row*stride+offset]==77,"row padding modified") end
        end
        layouts=layouts+1
    end
end
local tone=Tone.build_lut(Tone.find("clear"))
assert(tone[0]==0 and tone[255]==255 and tone[64]<64 and tone[192]>192)
local combined=Tone.combine_lut(clear,tone)
for value=0,255 do assert(combined[value]==tone[clear[value]]) end
print("FFI pixel layouts: "..layouts.." passed; stride, alpha, inverse and combined LUT passed")
''')
print("verify_filter_native: passed (pixel mapping; not a Kindle rendering test)")
