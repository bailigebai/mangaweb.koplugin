local Reader=require('mangaweb.reader')
local Settings=require('mangaweb.settings')
local saved={}
local settings=Settings:new{store={readSetting=function(_,k,d)return saved[k] or d end,
    saveSetting=function(_,k,v)saved[k]=v;return true end,flush=function()return true end}}
local requests,canceled,shown,loading={}, {},0,0
local loader={begin_session=function()return 1 end,release=function()end,cancel_generation=function()end,
    request=function(_,_,spec,cb)
        requests[#requests+1]={spec=spec,cb=cb}
        return{cancel=function()canceled[spec.index]=true end}
    end}
local ui={show_page=function()shown=shown+1;return true end,
    show_page_loading=function()loading=loading+1;return true end,close_reader=function()end}
local reader=Reader:new{settings=settings,store={save_history=function()return true end},ui=ui,loader=loader}
local context={site_id='zero',comic_id='a',chapter_id='c',pages={}}
for i=1,9 do context.pages[i]={url='https://img/'..i..'.jpg'}end
assert(reader:open(context))
requests[1].cb.on_ready{path='/first.jpg',metadata={width=600,height=800}}
assert(#requests==4 and reader:current_page()==1)
local current,gen,epoch=reader.entries[1],reader.generation,reader.processing_epoch
assert(reader:update_settings{preload_pages=5})
assert(reader.entries[1]==current and reader.generation==gen and reader.processing_epoch==epoch,
    'changing preload alone must preserve the current image, generation and processing epoch')
assert(#requests==6 and shown==1 and loading==1, '3 to 5 must add only the two missing future pages')
assert(reader:update_settings{preload_pages=4})
assert(canceled[6] and not canceled[1] and not canceled[2] and #requests==6)
requests[2].cb.on_ready{path='/second.jpg',metadata={width=600,height=800}}
assert(reader:go_to(2))
assert(shown==2 and loading==1, 'a completed prefetched image must turn directly without showing loading')
assert(reader:update_settings{preload_pages=0})
assert(not reader.entries[3] and reader.entries[2] and reader.entries[1])
assert(reader:go_to(8));local target=reader.entries[8]
assert(reader:update_settings{preload_pages=5})
assert(reader.entries[8]==target and reader.target==8, 'changing preload during loading must retain the target transfer')
local count=#requests
requests[count].cb.on_ready{path='/eighth.jpg',metadata={width=600,height=800}}
assert(reader:current_page()==8 and reader.entries[9] and not reader.entries[10], 'chapter end must bound the window')
assert(settings:reader_settings().preload_pages==5)
local invalid,reason=reader:update_settings{preload_pages=11}
assert(not invalid and reason=='invalid_preload_pages' and settings:reader_settings().preload_pages==5)
reader:close()
local reopened=Reader:new{settings=settings,store={},ui=ui,loader=loader}
assert(reopened:settings_snapshot().preload_pages==5)

local fixture=require('spec.helpers.reader_ui')
local adapter,fake=fixture()
local function action(text)
    for _,row in ipairs(adapter.reader_controls.model.rows)do
        for _,item in ipairs(row.items or {})do if item.text==text then return item end end
    end
end
assert(adapter:_show_reader_controls())
assert(action('阅读预加载'), 'reading settings must have a dedicated preload entry')
assert(action('阅读预加载').callback())
assert(action('✓ 后续3页'))
assert(action('后续5页').callback() and fake:settings_snapshot().preload_pages==5)
assert(action('后续4页').callback() and fake:settings_snapshot().preload_pages==4)
assert(action('关闭预加载').callback() and fake:settings_snapshot().preload_pages==0)
assert(pcall(adapter.reader_widget.onGesture,adapter.reader_widget,{ges='multiswipe'}))
print('reader_preload_spec: passed')
