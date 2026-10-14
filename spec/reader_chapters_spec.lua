local Reader=require('mangaweb.reader')
local history, requests, notices, timers={}, {}, {}, {}
local store={get_history=function(_,site,id)return history[id]end,
    save_history=function(_,record)history[record.comic_id]=record;return true end}
local loader={begin_session=function()return 1 end,cancel_generation=function()end,
    request=function(_,_,spec,cb)cb.on_ready{path='/image/'..spec.index,metadata={width=600,height=800}};return{}end}
local ui={show_page_loading=function()return true end,show_page=function()return true end,
    close_reader=function()return true end,show_chapter_status=function(_,state,error)notices[#notices+1]={state,error}end}
local scheduler={scheduleIn=function(_,_,cb)timers[#timers+1]=cb;return true end,unschedule=function()end}
local reader=Reader:new{store=store,loader=loader,ui=ui,scheduler=scheduler}
local chapters={{id='c1',title='第一话'},{id='c2',title='第二话'},{id='c3',title='第三话'}}
local pages={{url='https://image/1'},{url='https://image/2'},{url='https://image/3'}}
local function context(chapter)
    return {site_id='zero',comic_id='a',title='comic',chapter_id=chapter,default_chapter_id='c1',
        chapter_title=chapter,chapters=chapters,pages=pages,load_chapter=function(id,cb)
            local job={id=id,cb=cb}; requests[#requests+1]=job
            return{cancel=function()job.canceled=true end}
        end}
end
assert(reader:open(context('c2')) and reader:go_to(2))
assert(history.a and history.a.chapter_id=='c2' and history.a.page_index==2,
    'every chapter, including the second, must save its chapter and page')
reader:close()
assert(reader:open(context('c2')) and reader:current_page()==2,'same chapter resumes its own page')
assert(reader:open(context('c3')) and reader:current_page()==1,'another chapter must start on page one')
assert(reader:chapter_state().next==false and reader:chapter_state().previous)
assert(reader:switch_chapter(-1))
assert(reader.context.chapter_id=='c3' and reader:chapter_state().busy,'keep old chapter until new pages arrive')
assert(not reader:switch_chapter(-1) and #requests==1,'duplicate taps cannot start parallel switches')
requests[1].cb.on_error{code='transport_error'}
assert(reader.context.chapter_id=='c3' and reader:current_page()==1 and not reader:chapter_state().busy)
assert(reader:switch_chapter(-1)); local successful=requests[2]
successful.cb.on_success{pages=pages}
assert(reader.context.chapter_id=='c2' and reader:current_page()==1 and history.a.chapter_id=='c2')
assert(reader.context.chapter_title=='第二话' and history.a.chapter_title=='第二话')
assert(reader:switch_chapter(-1));local late=requests[3]
reader:close();assert(late.canceled,'closing must cancel a chapter request')
assert(late.cb.on_success{pages=pages}==false and reader.closed,'late completion cannot reopen reading')
assert(reader:open(context('c1')));assert(not reader:switch_chapter(-1),'first chapter boundary is disabled')
assert(reader:switch_chapter(1)); local timed=requests[4];timers[#timers]()
assert(timed.canceled and not reader:chapter_state().busy and reader.context.chapter_id=='c1')
assert(timed.cb.on_success{pages=pages}==false,'timed-out request must not replace current chapter')
local first_image
local prior_request=loader.request
loader.request=function(_,_,spec,cb)first_image=cb;return{}end
assert(reader:switch_chapter(1));requests[#requests].cb.on_success{pages=pages}
assert(reader.context.chapter_id=='c1' and reader.current_path,
    'new chapter must not replace old context before its first image is ready')
first_image.on_error{code='transport_error'}
assert(reader.context.chapter_id=='c1' and reader.current_path and not reader:chapter_state().busy,
    'first-image download failure must preserve the old displayed page')
loader.request=prior_request
history.a={page_index=3}
assert(reader:open(context('c2')) and reader:current_page()==1,'legacy history belongs only to default chapter')
history.a={page_index=3}
assert(reader:open(context('c1')) and reader:current_page()==3)
local enumeration, canceled
local pending=context('c1');pending.pages={};pending.load_pages=function(cb)
    enumeration=cb;return{cancel=function()canceled=true end}
end
assert(reader:open(pending));reader:close()
assert(canceled,'closing while enumerating must cancel the owned image-list request')
assert(reader:open(context('c2')))
local timer=reader.watchdogs.image
enumeration.on_success{pages=pages}
assert(reader.context.chapter_id=='c2' and reader.watchdogs.image==timer,'stale lists cannot cancel new watchdogs')
local fixture=require('spec.helpers.reader_ui')
local adapter,fake=fixture();local switched
function fake:chapter_state()return{previous=false,next=true,busy=false,title='第一话'}end
function fake:switch_chapter(delta)switched=delta;return true end
assert(adapter:_show_reader_controls())
local buttons={}
for _,row in ipairs(adapter.reader_controls.model.rows)do for _,b in ipairs(row.items or{})do buttons[b.text]=b end end
assert(buttons['上一话'] and buttons['上一话'].enabled==false and buttons['下一话'])
assert(buttons['下一话'].callback() and switched==1,'switch directly from reading controls')
-- Real Reader + Adapter + native window: keep both old page and loader alive.
local native=fixture()
local image_job,chapter_job,session= nil,nil,0
local retired={}
local native_loader={begin_session=function()session=session+1;return session end,
    cancel_generation=function(_,id)retired[id]=true end,
    request=function(_,_,spec,cb)
        if session==1 then cb.on_ready{path='/old.jpg',metadata={width=600,height=800}}
        else image_job=cb end
        return{cancel=function()end}
    end}
local real=Reader:new{store=store,ui=native,loader=native_loader}
native.reader=real
assert(real:open{site_id='zero',comic_id='native',chapter_id='c1',default_chapter_id='c1',
    chapters=chapters,pages={{url='https://image/old'}},load_chapter=function(_,cb)chapter_job=cb;return{}end})
local old_widget,old_session=native.reader_widget,real.loader_generation
assert(real:switch_chapter(1));chapter_job.on_success{pages=pages}
image_job.on_error{code='transport_error'}
assert(native.reader_widget==old_widget and not old_widget.released and real.current_path=='/old.jpg'
    and not retired[old_session],'network failure must retain the native page and its ownership')
assert(real:switch_chapter(1));chapter_job.on_success{pages=pages}
local Image=native.image_widget
native.image_widget={new=function(_,options)if options.file=='/bad.jpg' then error('decode failure')end;return Image:new(options)end}
image_job.on_ready{path='/bad.jpg'}
assert(real.context.chapter_id=='c1' and real.current_path=='/old.jpg' and native.reader_widget==old_widget)
native.image_widget=Image
assert(real:switch_chapter(1));chapter_job.on_success{pages=pages}
image_job.on_ready{path='/new.jpg',metadata={width=600,height=800}}
assert(real.context.chapter_id=='c2' and real.current_path=='/new.jpg' and retired[old_session],
    'commit the chapter only after the first image successfully displays')
print('reader_chapters_spec: passed')
