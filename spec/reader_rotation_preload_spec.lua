local Loader=require('mangaweb.image_loader')
local Reader=require('mangaweb.reader')
local work,files,shown,downloaded={},{},{},0
local width,height=600,800
local loader=Loader:new{max_active=2,max_processing=1,
    http={get_file=function(_,_,options,cb)
        downloaded=downloaded+1;files[options.path]=true
        cb.on_success(options.path,{bytes=4});cb.on_reaped();return{cancel=function()end}
    end},
    temp_files={new_session=function()return{}end,remove_session=function()end,
        path=function(_,_,name,ext)return '/temp/'..name..'.'..ext end,
        reserve=function(_,_,name)return '/temp/'..name..'.part'end,
        publish=function(_,_,path)return path end,discard=function(_,path)files[path]=nil end,
        write=function(_,_,name)files['/temp/'..name]=true;return '/temp/'..name end,
        track=function(_,_,path)files[path]=true;return path end,
        remove=function(_,path)files[path]=nil end},
    async={available=function()return true end,run=function(fn,done)
        work[#work+1]={fn=fn,done=done};return{cancel=function()end}
    end},
    page_processor={process=function(path,_,profile)
        assert(files[path],'the original must remain owned during viewport reprocessing')
        return{width=profile.target_width,height=profile.target_height,
            source_width=profile.source_width,source_height=profile.source_height}
    end}}
local ui={reader_viewport=function()return width,height end,show_page_loading=function()return true end,
    show_page=function(_,path)shown[#shown+1]=path;return true end,close_reader=function()end}
local reader=Reader:new{store={},loader=loader,ui=ui}
reader.reader_settings.gray_enabled=true;reader.reader_settings.gray_preset='clear'
reader.reader_settings.preload_pages=1
assert(reader:open{site_id='zero',comic_id='a',chapter_id='c',pages={
    {url='https://image/1.jpg',width=1200,height=1600},
    {url='https://image/2.jpg',width=1200,height=900}}})
assert(#work==1);work[1].done(true,work[1].fn())
assert(#work==2 and #shown==1,'page two is still processing in the old viewport')
width,height=800,600
assert(reader:go_to(2))
work[2].done(true,work[2].fn())
assert(#shown==1 and #work==3,'a late old-size preload must be reprocessed before display')
work[3].done(true,work[3].fn())
assert(#shown==2 and reader.entries[2].metadata.width==800 and reader.entries[2].metadata.height==600)
assert(downloaded==2,'new viewport must reuse the two downloaded originals')
reader:close()
print('reader_rotation_preload_spec: passed')
