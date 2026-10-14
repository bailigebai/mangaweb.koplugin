local fixture=require('spec.helpers.reader_ui')
local adapter,reader,manager=fixture()
local scheduled={}
function manager:scheduleIn(_,cb) scheduled[#scheduled+1]=cb;return true end
function manager:unschedule(cb)
    for i=#scheduled,1,-1 do if scheduled[i]==cb then table.remove(scheduled,i)end end
end
local function idle() local cb=table.remove(scheduled,1);if cb then cb()end end
local images,decoded={},0
local Image=adapter.image_widget:extend{}
function Image:getSize()
    if not self.decoded then
        self.decoded=true;decoded=decoded+1;images[self.file]=self
        if self.file=='/broken.jpg' then error('decode failure')end
    end
    return {w=600,h=800}
end
function Image:free() self.frees=(self.frees or 0)+1 end
adapter.image_widget=Image
assert(adapter:show_page('/one.jpg',1,20,{}))
assert(type(adapter.prepare_pages)=='function','reader must expose bounded idle decode preparation')
assert(adapter:prepare_pages{'/two.jpg','/three.jpg','/four.jpg','/two.jpg'})
assert(decoded==1,'preparation must defer decoding until idle')
idle();idle();idle()
assert(decoded==3 and not images['/four.jpg'],'only the next two pages may be decoded')
assert(adapter:show_page('/two.jpg',2,20,{}))
assert(decoded==3 and images['/one.jpg'].frees==1 and not images['/two.jpg'].frees,
    'a prepared page must transfer ownership without a second decode or early free')
assert(adapter:prepare_pages{'/three.jpg'})
idle();assert(decoded==3,'retained next pages must not decode repeatedly')
assert(adapter:prepare_pages{'/broken.jpg'})
assert(images['/three.jpg'].frees==1,'stale prepared widgets must be freed exactly once')
idle();assert(images['/broken.jpg'].frees==1,'failed preparation must release its widget')
assert(adapter:prepare_pages{'/four.jpg'})
local stale=scheduled[1]
assert(adapter:close_reader());stale()
assert(not images['/four.jpg'] and images['/two.jpg'].frees==1,
    'closing reader cancels preparation and releases active/prepared images')
print('reader_decode_cache_spec: passed')
