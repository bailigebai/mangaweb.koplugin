local Thumbnail=require('mangaweb.cover_thumbnail')
local profile=Thumbnail.profile(224,320)
local metadata,code=Thumbnail.process('/private/source.jpg','/private/target.jpg',profile,
    {renderImageFile=function()error('private codec detail')end})
assert(metadata==nil and code=='thumbnail_decode_failed',
    'worker decode errors need a safe stage code instead of an undiagnosable empty result')
local freed=0
metadata,code=Thumbnail.process('/private/source.jpg','/private/target.jpg',profile,
    {renderImageFile=function()return{free=function()freed=freed+1 end,
        writeToFile=function()return false,'private filesystem detail'end}end})
assert(metadata==nil and code=='thumbnail_encode_failed' and freed==1)
metadata,code=Thumbnail.process('/private/source.jpg','/does-not-exist/target.jpg',profile,
    {renderImageFile=function()return{free=function()freed=freed+1 end,
        writeToFile=function()return true end}end})
assert(metadata==nil and code=='thumbnail_validation_failed' and freed==2)
print('thumbnail_failure_diagnostics_spec: passed')
