-- Exercise the real HTTP/file/loader boundary; only the remote socket and
-- subprocess scheduler are substituted. FileSink still writes a real file.
local Transport = require('mangaweb.transport')
local Http = require('mangaweb.http')
local Loader = require('mangaweb.image_loader')
local Zero = require('mangaweb.sources.zero')
local original = 'http://tupa.zerobyw33.com/sample/page.jpg'
local secure = 'https://tupa.zerobyw33.com/sample/page.jpg'
local jpeg = '\255\216\255\192\0\17\8\7\199\5\120\3\1\17\0\2\17\0\3\17\0\255\217'
local files = {}
local function fixture(options)
    options = options or {}
    local calls, publications, cache, progress = {}, 0, nil, 0
    local part = os.tmpname() .. '.part'
    files[#files + 1] = part
    local client = {request = function(request)
        calls[#calls + 1] = {url=request.url,headers=request.headers}
        if request.url == secure and not options.fail_secure then
            assert(request.sink(jpeg) == 1)
            assert(request.sink(nil) == 1)
            return 1,200,{['content-length']=tostring(#jpeg)}
        end
        if options.http_status then return 1,options.http_status,{} end
        return nil,'closed'
    end}
    local transport = Transport:new{http=client,https=client,ltn12={},socket={},socketutil={},
        native_http=false,
        async={available=function()return true end,run=function(work,done)
            done(true,work());return {cancel=function()end}
        end}}
    transport.file_scheduler={scheduleIn=function()return true end}
    local loader = Loader:new{http=Http:new{transport=transport},
        temp_files={new_session=function()return {} end,remove_session=function()end,
            remove=function(_,path)os.remove(path)end},
        page_cache={pin=function()return true end,unpin=function()end,
            get=function()return cache end,reserve=function()return part end,
            discard=function(_,path)os.remove(path)end,
            publish=function(_,identity,path,bytes)
                assert(identity.url == (options.url or original), 'cache identity must use the original resource')
                local file=assert(io.open(path,'rb'));local body=file:read('*a');file:close()
                assert(body==jpeg and bytes==#jpeg, 'only the completed secure transfer can be published')
                cache=path;publications=publications+1;return path
            end}}
    local spec={key='first',site_id=options.site or 'zero',stage='image',
        url=options.url or original,headers=options.headers or {},
        cache_identity={site_id='zero',comic_id='test',chapter_id='chapter',index=1,
            url=options.url or original}}
    local ready, failure, errors
    errors=0
    local generation=loader:begin_session('reader')
    local callbacks={on_ready=function(result)ready=result;return true end,
        on_error=function(error)failure=error;errors=errors+1 end,
        on_progress=function()progress=progress+1 end}
    loader:request(generation,spec,callbacks)
    return {loader=loader,spec=spec,callbacks=callbacks,generation=generation,calls=calls,
        result=function()return ready,failure,errors,publications end}
end

local recovered=fixture()
local ready, failure, errors, publications = recovered.result()
assert(ready and not failure and errors==0 and ready.metadata.width==1400,
    'Zero first page must recover through HTTPS when its HTTP image connection closes')
assert(#recovered.calls==2 and recovered.calls[1].url==original and recovered.calls[2].url==secure)
assert(publications==1 and recovered.spec.url==original)
recovered.loader:release(recovered.generation,'first')
recovered.loader:request(recovered.generation,recovered.spec,recovered.callbacks)
assert(#recovered.calls==2, 'reopening must reuse the recovered image under the existing cache identity')
recovered.loader:cancel_generation(recovered.generation)
assert(recovered.loader.active_count==0 and not next(recovered.loader.sessions))

local broken=fixture{fail_secure=true}
ready,failure,errors=broken.result()
assert(not ready and failure.code=='transport_error' and errors==1 and #broken.calls==2,
    'both protocols failing must stop once, with no endless retries')
broken.loader:cancel_generation(broken.generation)
for _,options in ipairs{
    {site='custom'}, {url='http://tupa.zerobyw33.com.evil.example/page.jpg'},
    {url='http://other.example/page.jpg'}, {url='http://tupa.zerobyw33.com:80/page.jpg'},
    {headers={Cookie='private_cookie'}}, {headers={authorization='private_auth'}},
    {http_status=403},
} do
    local unchanged=fixture(options)
    ready,failure,errors=unchanged.result()
    assert(not ready and failure and errors==1 and #unchanged.calls==2)
    assert(unchanged.calls[2].url==(options.url or original),
        'recovery must not rewrite another site, an untrusted URL, credentials, or an HTTP permission rejection')
    unchanged.loader:cancel_generation(unchanged.generation)
end
local source=Zero:new{}
local pages=source:parse_pages('<img class="comic-page" src="//tupa.zerobyw33.com/sample/page.jpg">','test')
assert(pages.pages[1].url==original, 'keep the source and existing cache URL unchanged')
for _,path in ipairs(files)do os.remove(path)end
print('zero_network_recovery_spec: real file download recovery, bounded failures and cache identity passed')
