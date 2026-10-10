local Library = require('mangaweb.ui.library')
local Shell = require('mangaweb.ui.shell')
local source = { id = 'zero', origin = 'https://zero.example',
    capabilities = function() return { official_favorites = true } end }
local calls, cancels = {}, 0
function source:favorites(options, callbacks)
    calls[#calls + 1] = { options = options, callbacks = callbacks }
    return { cancel = function() cancels = cancels + 1 end }
end
local removals = {}
function source:remove_favorite(id, callbacks)
    removals[#removals + 1] = { id = id, callbacks = callbacks }
    return { cancel = function() cancels = cancels + 1 end }
end
local registry = { current_id = function() return source.id end, current = function() return source end }
local writes = 0
local store = {
    list_categories = function() return {{ id = 7, name = '官方收藏' }, {id = 8, name = '待读'}} end,
    list_favorites = function() return {{comic_id='local',title='本地漫画',site_id='zero'}} end,
    list_category_items = function() return {} end,
    list_history = function() return {} end,
    assign_category = function() writes = writes + 1; return true end,
}
local model, detail_card, detail_options, current = nil, nil, nil, true
local shell = { set_model = function(_, value) model = value; return true end,
    is_view = function() return current end,
    show_detail = function(_, card, options) detail_card, detail_options = card, options end,
    show = function() return true end }
local library = Library:new{source_registry=registry,store=store,shell=shell,view_token=1}
library:show()
assert(#calls == 1, 'opening the collection must automatically read official favorites')
assert(model.tabs[1].name == '默认' and model.tabs[2].id == 'official:zero'
    and model.tabs[2].name == '官方收藏' and model.tabs[3].id == 7,
    'official tab must coexist with user categories of the same name')
assert(model.items[1].comic_id == 'local' and model.official == false)
model.actions.select_category('official:zero')
assert(model.official and model.state == 'loading' and #calls == 1)
calls[1].callbacks.on_success{cards={{site_id='zero',comic_id='12',title='网页漫画'}},page=1,total_pages=2,total_count=21}
assert(model.state == 'ready' and #model.items == 1 and model.page_number == 1)
assert(model.actions.begin_selection == nil and model.actions.assign_selected == nil,
    'official tab is not a local category assignment target')
model.items[1].on_tap()
assert(detail_card.comic_id == '12' and detail_options.return_page == 'library'
    and detail_options.return_options.category_id == 'official:zero')
model.actions.next_page()
assert(#calls == 3 and calls[3].options.page == 2)
calls[3].callbacks.on_success{cards={{site_id='zero',comic_id='13',title='第二页'}},page=2,total_pages=2,total_count=21}
model.items[1].on_tap()
assert(detail_options.return_options.official_page == 2)
assert(model.actions.remove_official{comic_id='999'} == false, 'unknown records cannot be removed')
local remove = model.actions.remove_official
assert(remove(model.items[1]) and #removals == 1 and removals[1].id == '13')
assert(remove(model.items[1]) == false and #removals == 1, 'duplicate removal must be blocked')
assert(model.actions.refresh() == false, 'GET must not race with pending removal')
removals[1].callbacks.on_error{code='favorite_remove_uncertain'}
assert(model.error.code == 'favorite_remove_uncertain')
model.actions.retry()
assert(#calls == 5 and #removals == 1, 'retry only re-reads, never repeats a destructive toggle')
calls[5].callbacks.on_success{cards={{site_id='zero',comic_id='13',title='第二页'}},page=1,total_pages=1,total_count=1}
model.actions.remove_official(model.items[1])
removals[2].callbacks.on_success{removed=true,comic_id='13'}
assert(#calls == 6 and writes == 0)
calls[6].callbacks.on_success{cards={},page=1,total_pages=1,total_count=0}
assert(model.state == 'empty' and not model.error)
model.actions.select_category(nil)
assert(#model.items == 1 and model.items[1].comic_id == 'local')
model.actions.begin_selection()
library:toggle_selected('local')
assert(model.actions.assign_selected({id='official:zero',kind='official'}) == false and writes == 0)
assert(model.actions.assign_selected({id=8}) and writes == 1)
assert(model.category_id == 8)
model.actions.select_category('official:zero')
model.actions.refresh()
local late = calls[#calls].callbacks
local last_model = model
library:close()
late.on_success{cards={{comic_id='late'}},page=1,total_pages=1}
assert(model == last_model and cancels == 3)
assert(library:remove_official({comic_id='13'}) == false)

calls = {}; current = true
library = Library:new{source_registry=registry,store=store,shell=shell,view_token=2,
    category_id='official:zero',official_page=2}
library:show()
assert(model.official and calls[1].options.page == 2)
calls[1].callbacks.on_error{code='login_required'}
assert(model.error.code == 'login_required' and model.actions.relogin)
model.actions.select_category(nil)
assert(not model.error and #model.items == 1, 'login errors do not hide local favorites')
library:close()
local other = {id='other',capabilities=function() return {} end}
local other_registry = { current_id = function() return other.id end,current=function() return other end }
Library:new{source_registry=other_registry,store=store,shell=shell}:show()
for _, tab in ipairs(model.tabs) do assert(tab.kind ~= 'official') end

-- Shell must cancel library requests before routing to details or closing the plugin.
local ui = {update_model=function() end}
local real_shell = Shell:new{source_registry=registry,store=store,ui=ui}
real_shell:show('library',{category_id='official:zero',official_page=2})
local pending = calls[#calls].callbacks
local previous_cancels = cancels
real_shell:show('history')
assert(cancels == previous_cancels + 1 and real_shell.library == nil)
local history_model = real_shell:model()
pending.on_error{code='network_error'}
assert(real_shell:model() == history_model)
print('official_library_spec: passed')
