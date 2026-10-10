local Adapter = require('mangaweb.ui.koreader')
local displayed, panel, removed = nil, nil, 0
local adapter = Adapter:new{ ui_manager = { show=function() end,close=function() end } }
adapter.shell = { model=function() return displayed end }
function adapter:_category_panel()
    return {show=function(_, value) panel = value; return value end}
end
local record = {comic_id='12',title='测试漫画'}
displayed = {page='library',official=true,items={record},state='ready',
    tabs={{name='默认'},{name='官方收藏',id='official:zero',kind='official'},{id=7,name='待读'}},
    actions={can_remove_official=function() return true end,
        remove_official=function(item) assert(item==record);removed=removed+1;return true end,
        refresh=function() return true end,select_category=function() end}}
assert(adapter:_show_official_removal_picker(displayed))
assert(panel.rows[1].text == record.title and removed == 0)
panel.rows[1].callback()
assert(panel.page == 'official_remove_confirm' and panel.status:find('Zero 网页端',1,true))
assert(removed == 0, 'opening a confirmation cannot delete')
panel.actions[1].callback()
assert(removed == 0, 'cancel cannot delete')
assert(adapter:_show_official_removal_picker(displayed))
panel.rows[1].callback()
local confirmation = panel
confirmation.actions[2].callback()
confirmation.actions[2].callback()
assert(removed == 1, 'confirm may invoke removal only once')
assert(adapter:_show_official_removal_picker(displayed))
panel.rows[1].callback()
local stale = panel
displayed = {page='history'}
stale.actions[2].callback()
assert(removed == 1, 'stale confirmation must not modify website')

local categories
function adapter:_show_local_category_picker(options) categories=options.categories; return true end
adapter:_show_batch_category_picker{tabs={{name='默认'},{name='官方收藏',id='official:zero',kind='official'},
    {id=7,name='待读'}},actions={assign_selected=function() end}}
assert(#categories == 1 and categories[1].id == 7, 'official tab cannot be a batch category')

local model = {page='library',official=true,state='empty',items={},tabs={},subtitle='Zero 网页收藏 · 0 本',
    actions={refresh=function() end}}
function adapter:_build_native_grid(current) return current end
adapter:_build_collection_grid(model)
assert(model.title == '收藏' and model.subtitle == 'Zero 网页收藏 · 0 本'
    and model.show_pagination and model.actions.choose_official_removal)
local entries = adapter:_items_for(model)
local refresh_found, remove_found, local_found = false,false,false
for _, entry in ipairs(entries) do
    if entry.text == '刷新官方收藏' then refresh_found=true end
    if entry.text == '取消官方收藏' then remove_found=true end
    if entry.text == '多选' or entry.text == '管理分类' then local_found=true end
end
assert(refresh_found and remove_found and not local_found, 'menu fallback must offer remote actions')
-- Exercise the real NativePanel readiness check, not only the panel substitute above.
local shown = {}
local Menu = {new=function(_, options) return options end}
local fallback = Adapter:new{menu=Menu,ui_manager={
    show=function(_,widget) shown[#shown+1]=widget end,close=function() end}}
displayed = {page='library',official=true,state='ready',items={record},actions={
    can_remove_official=function() return true end,
    remove_official=function() removed=removed+1;return true end}}
fallback.shell={model=function() return displayed end}
assert(fallback:_show_official_removal_picker(displayed), 'unavailable native UI must have a real menu fallback')
local menu = shown[#shown]
assert(menu.item_table[2].text == record.title)
menu.item_table[2].callback()
menu = shown[#shown]
assert(menu.item_table[1].text:find('Zero 网页端',1,true))
assert(menu.item_table[3].text == '确定取消收藏')
menu.item_table[3].callback()
menu.item_table[3].callback()
assert(removed==2)
fallback:_show_official_removal_picker(displayed)
shown[#shown].item_table[2].callback()
menu=shown[#shown]
menu.item_table[2].callback()
menu.item_table[3].callback()
assert(removed==2, 'closing a fallback confirmation blocks later confirmation callbacks')
fallback:_show_official_removal_picker(displayed)
shown[#shown].item_table[2].callback()
menu=shown[#shown]
displayed={page='history'}
menu.item_table[3].callback()
assert(removed==2)
print('official_collection_ui_spec: passed')
