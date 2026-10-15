-- Real Reader/Shell/Detail wiring; replace only network, display and storage.
return function(store)
    local Reader = require('mangaweb.reader')
    local Shell = require('mangaweb.ui.shell')
    local saved
    store = store or {
        get_history = function() return saved end,
        save_history = function(_, record) saved = record; return true end,
    }
    local chapters = {{id='c1',title='First'},{id='c2',title='Second'},{id='c3',title='Third'}}
    local source = {id='zero', detail=function(_,id,cb)
        cb.on_success{card={site_id='zero',comic_id=id,title='Comic'},chapters=chapters}
        return {}
    end, pages=function(_,_,chapter,cb)
        cb.on_success{pages={{url='https://image/'..chapter..'/1'},
            {url='https://image/'..chapter..'/2'}}}
        return {}
    end}
    local registry = {current=function()return source end,current_id=function()return 'zero' end}
    local loader = {begin_session=function()return 1 end,cancel_generation=function()end,
        request=function(_,_,spec,cb)
            cb.on_ready{path='/image/'..spec.index,metadata={width=600,height=800}}
            return {}
        end}
    local ui = {show_page_loading=function()return true end,show_page=function()return true end,
        close_reader=function()return true end}
    local reader = Reader:new{store=store,loader=loader,ui=ui}
    local shell = Shell:new{source_registry=registry,store=store,reader=reader,
        license={is_authorized=function()return true end},license_dialog={},
        on_start_reading=function(card,context)
            context.site_id,context.comic_id,context.title=card.site_id,card.comic_id,card.title
            return reader:open(context)
        end}
    assert(shell:show('detail',{card={site_id='zero',comic_id='a'}}))
    return {reader=reader,shell=shell,source=source,loader=loader,store=store,chapters=chapters}
end
