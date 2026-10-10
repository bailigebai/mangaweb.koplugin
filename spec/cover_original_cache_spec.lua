-- Regression: a differently sized detail cover downloaded the homepage original again.
-- Real cache/loader/temp-file state; HTTP and native rendering are external boundaries.
local Cache = require('mangaweb.page_cache')
local TempFiles = require('mangaweb.temp_files')
local CoverLoader = require('mangaweb.cover_loader')
local files, hashes, serial = {}, {}, 0
local function sha(value)
    if not hashes[value] then serial = serial + 1; hashes[value] = string.format('%064x', serial) end
    return hashes[value]
end
local jpeg = '\255\216\255' .. string.rep('x', 40)
local fs = {mkdir=function()return true end,
    read=function(_,p,n)return files[p] and files[p]:sub(1,n)end,
    size=function(_,p)return files[p] and #files[p]end,
    write=function(_,p,b)files[p]=b;return true end,
    rename=function(_,a,b)files[b]=files[a];files[a]=nil;return true end,
    remove=function(_,p)files[p]=nil;return true end,rmdir=function()return true end,
    list=function(_,root)
        local result={}
        for p,b in pairs(files)do if p:sub(1,#root+1)==root..'/'then
            result[#result+1]={name=p:sub(#root+2),mode='file',mtime=1,size=#b}
        end end
        return result
    end}
local originals=Cache:new{root='/pages',fs=fs,sha256=sha}
local small=Cache:new{root='/covers',fs=fs,sha256=sha}
local downloads,inline,processed,painted=0,0,0,0
local logs={}
local logger={warn=function(...)logs[#logs+1]=table.concat({...},' ')end}
local http={get=function(_,url,options,cb)
    downloads,inline=downloads+1,inline+1;cb.on_success(jpeg);return{cancel=function()end}
end,get_file=function(_,url,options,cb)
    downloads=downloads+1;files[options.path]=jpeg
    cb.on_success(options.path,{bytes=#jpeg});cb.on_reaped();return{cancel=function()end}
end}
local loader=CoverLoader:new{cache=small,page_cache=originals,http=http,logger=logger,
    temp_files=TempFiles:new{root='/temp',fs=fs},
    render_image={renderImageFile=function(_,p)assert(files[p]);return{free=function()end}end},
    page_processor={process=function(source,output)
        assert(files[source]);processed=processed+1;files[output]=jpeg
        return{thumbnail=true,width=128,height=192}
    end},async={available=function()return true end,run=function(work,done)
        done(true,work());return{cancel=function()end}
    end}}
local function show(width,height,headers,chapter)
    local gen=loader:begin_session('cover')
    local ready=false
    loader:request(gen,{key='visible',url='https://img.example/cover.jpg',stage='cover',
        site_id='zero',comic_id='book',chapter_id=chapter,width=width,height=height,headers=headers},
        {on_ready=function(result)assert(result.buffer);ready=true;painted=painted+1;return true end,
         on_error=function()error('cover must display')end})
    assert(ready)
    loader:cancel_generation(gen)
    assert(not next(originals.pins) and not next(small.pins))
end
show(320,448,{},'chapter1')
show(224,320,{},'chapter2')
assert(downloads==1,'homepage to detail must reuse one persistent original despite size/chapter changes')
assert(inline==0,'cover download must use the background file channel, not the UI inline transport')
assert(processed==2 and painted==2,'both display sizes need their own small derivatives')
show(320,448,{},'chapter3')
assert(downloads==1 and processed==2 and painted==3,'reopening the homepage must read the cached thumbnail')
show(224,320,{Cookie='account-a'},'chapter1')
show(320,448,{cookie='account-a'},'chapter9')
assert(downloads==2,'one account must reuse its original across display sizes')
show(224,320,{Cookie='account-b'},'chapter1')
assert(downloads==3,'different accounts must never reuse a private original')
local transcript=table.concat(logs,'\n')
assert(transcript:find('thumbnail_display_ready',1,true),
    'diagnostics must distinguish a downloaded file from a thumbnail accepted by the UI')
assert(not transcript:find('https://',1,true) and not transcript:find('account-',1,true))
print('cover_original_cache_spec: passed')
