local Detail=require('mangaweb.ui.detail')
local Shell=require('mangaweb.ui.shell')
local chapters={{id='c1',title='第一话'},{id='c2',title='第二话'}}
local history={chapter_id='c2',page_index=9}
local source={id='zero',detail=function(_,id,cb)
    cb.on_success{card={site_id='zero',comic_id=id,title='Comic'},chapters=chapters};return{}
end,pages=function(_,_,chapter,cb)cb.on_success{pages={{url='https://image/'..chapter}}};return{}end}
local captured
local shell=Shell:new{source_registry={},license={is_authorized=function()return true end},license_dialog={},
    on_start_reading=function(_,ctx)captured=ctx;return true end}
local detail=Detail:new{source=source,shell=shell,store={get_history=function()return history end}}
assert(detail:show{site_id='zero',comic_id='a'})
assert(shell:model().selected_chapter_id=='c2' and shell:model().resume_page==9,
    'details must select and resume the saved non-default chapter')
assert(detail:start_reading() and captured.chapter_id=='c2' and captured.chapter_title=='第二话')
assert(#captured.chapters==2 and type(captured.load_chapter)=='function')
detail:close();local loaded
captured.load_chapter('c1',{on_success=function(result)loaded=result.pages end})
assert(loaded and #loaded==1,'reader chapter loading must survive the detail controller closing')
local next_detail=Detail:new{source=source,shell=shell,store={get_history=function()return history end}}
assert(next_detail:show{site_id='zero',comic_id='a'})
assert(next_detail:select_chapter(chapters[1]) and not shell:model().resume_page,
    'manual chapter selection cannot borrow a page from another chapter')
assert(next_detail:select_chapter(chapters[2]) and shell:model().resume_page==9)
history={chapter_id='removed',page_index=9};next_detail:close()
local missing=Detail:new{source=source,shell=shell,store={get_history=function()return history end}}
assert(missing:show{site_id='zero',comic_id='a'})
assert(shell:model().selected_chapter_id=='c1' and not shell:model().resume_page)
print('chapter_history_spec: passed')
