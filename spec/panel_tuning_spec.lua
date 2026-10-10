local Detector=require('mangaweb.panel_detector')
local function canvas(w,h)
    local data={}
    local c={w=w,h=h,data=data}
    function c:fill(x,y,width,height,tone)
        for yy=y,y+height-1 do for xx=x,x+width-1 do data[yy*w+xx]=tone end end
    end
    function c:ring(x,y,width,height,tone)
        self:fill(x,y,width,1,tone);self:fill(x,y+height-1,width,1,tone)
        self:fill(x,y,1,height,tone);self:fill(x+width-1,y,1,height,tone)
    end
    c.raster={buffer={getWidth=function() return w end,getHeight=function() return h end,
        getPixel=function(_,x,y) return data[y*w+x] or 255 end}}
    return c
end
local function standard(tone)
    local c=canvas(200,200)
    c:ring(10,10,80,80,tone);c:ring(110,10,80,80,tone);c:ring(10,110,180,80,tone)
    return c
end
local normal=standard(0)
local previous=assert(Detector.detect(normal.raster))
assert(#previous==3 and previous[1].x==.05 and previous[1].y==.05
    and previous[1].w==.4 and previous[1].h==.4 and previous[1].protect.x==.04
    and previous[1].protect.w==.42, 'current golden geometry and protection must remain unchanged')
local explicit=assert(Detector.detect(normal.raster,{strength_percent=100,min_area_permille=2,
    frame_min=1,dialogue_distance_percent=12}))
for i,p in ipairs(previous) do
    local q=explicit[i]
    assert(p.id==q.id)
    for _,key in ipairs({'x','y','w','h'}) do assert(p[key]==q[key] and p.protect[key]==q.protect[key]) end
end
local faint=standard(225)
assert(Detector.detect(faint.raster)==nil, 'current threshold should not see this faint frame')
local stronger=assert(Detector.detect(faint.raster,{strength_percent=200}), 'higher strength must detect faint frames')
assert(#stronger==3 and stronger[1].id==previous[1].id)
assert(Detector.detect(faint.raster,{strength_percent=50})==nil)

local small=canvas(400,400)
small:ring(10,20,140,350,0);small:ring(230,20,140,350,0);small:ring(185,180,10,20,0)
local filtered=assert(Detector.detect(small.raster))
local included=assert(Detector.detect(small.raster,{min_area_permille=1}))
assert(#filtered==2 and #included==3, 'small-panel threshold must change candidates, not silently omit ink')

local uneven=canvas(200,200)
for y=10,89 do uneven:fill(10,y,50+(y%3)*8,1,0) end
uneven:ring(110,10,80,80,0)
assert(#assert(Detector.detect(uneven.raster))==2)
local strict,strict_reason=Detector.detect(uneven.raster,{frame_min=4})
assert(not strict and strict_reason=='panel_layout_uncertain', 'strict frame evidence must safely reject uncertain layout')

local dialogue=canvas(200,200)
dialogue:ring(10,10,80,120,0);dialogue:ring(145,10,45,120,0);dialogue:fill(115,70,5,5,0)
local unsafe,reason=Detector.detect(dialogue.raster)
assert(not unsafe and reason=='panel_content_uncovered')
local protected=assert(Detector.detect(dialogue.raster,{dialogue_distance_percent=20}))
assert(#protected==2 and protected[1].protect.x+protected[1].protect.w>=120/200
    and protected[2].protect.x<=115/200, 'ambiguous overflow dialogue must be retained in both adjacent panels')
local connected=standard(0);connected:ring(80,40,23,25,0)
local connected_panels=assert(Detector.detect(connected.raster))
assert(connected_panels[1].protect.x+connected_panels[1].protect.w>=103/200,
    'speech connected to the frame must be retained beyond the ordering rectangle')
local pale_dialogue=canvas(200,200)
pale_dialogue:ring(10,10,80,120,0);pale_dialogue:ring(110,10,80,120,0)
pale_dialogue:fill(96,70,5,5,195)
local function contains(rect,x,y)
    return rect.x<=x and rect.y<=y and rect.x+rect.w>=x and rect.y+rect.h>=y
end
for _,strength in ipairs({100,50}) do
    local panels=assert(Detector.detect(pale_dialogue.raster,{strength_percent=strength}))
    local covered=false
    for _,p in ipairs(panels) do covered=covered or contains(p.protect,98/200,72/200) end
    assert(#panels==2 and covered, 'lower recognition strength must not cut pale overflow dialogue')
end
for _,invalid in ipairs({{strength_percent=0},{strength_percent=0/0},{strength_percent=201},
    {min_area_permille=3},{frame_min=5},{dialogue_distance_percent=26}}) do
    assert(Detector.detect(normal.raster,invalid)==nil, 'invalid direct detector options must fail safely')
end
print('panel_tuning_spec: default golden output, real faint ink, small frames, strict boundaries and overflow protection passed')
