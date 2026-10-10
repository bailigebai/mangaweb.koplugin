local Thumbnail = require('mangaweb.cover_thumbnail')
local profile = Thumbnail.profile(227, 321)
assert(profile.target_width == 256 and profile.target_height == 384 and profile.extension == 'jpg')
assert(Thumbnail.profile(9999, 9999).target_width == 640)
assert(Thumbnail.profile(0, 0).target_height == 512)
local serial, hashes = 0, {}
local function sha(value)
    if not hashes[value] then serial=serial+1; hashes[value]=string.format('%064x',serial) end
    return hashes[value]
end
local spec = {site_id='zero',comic_id='a',url='https://img/1.jpg',headers={Cookie='secret'}}
local first = Thumbnail.identity(spec, profile, sha)
spec.headers={cookie='secret'}
assert(Thumbnail.identity(spec,profile,sha).chapter_id == first.chapter_id)
spec.headers.Cookie='another-account'
assert(Thumbnail.identity(spec,profile,sha).chapter_id ~= first.chapter_id)
assert(not first.chapter_id:find('secret',1,true), 'cache identity must not contain credentials')
spec.url='https://img/2.jpg'
assert(Thumbnail.identity(spec,profile,sha).url ~= first.url)
assert(Thumbnail.identity(spec,Thumbnail.profile(320,480),sha).chapter_id ~= first.chapter_id)
local freed, writes = 0, 0
local renderer={renderImageFile=function(_,path,animated,w,h)
    assert(path=='/original.jpg' and animated==false and w==256 and h==384)
    return {free=function()freed=freed+1 end,writeToFile=function(_,path,format,quality)
        assert(path=='/small.jpg' and format=='jpg' and quality==75);writes=writes+1;return true
    end}
end}
require('mangaweb.image_dimensions').from_file=function()return 256,360 end
assert(Thumbnail.process('/original.jpg','/small.jpg',profile,renderer).width==256)
assert(freed==1 and writes==1)
renderer.renderImageFile=function()return{free=function()freed=freed+1 end,
    writeToFile=function()return false end}end
assert(not Thumbnail.process('/original.jpg','/small.jpg',profile,renderer))
assert(freed==2, 'encoding failures must free their buffer')
print('cover_thumbnail_spec: passed')
