-- Returning from a chapter switch must not let an old detail selection
-- overwrite the chapter already saved by the real reader.
local fixture = require('spec.helpers.history_reopen')
local f = fixture()
local reader, shell, store = f.reader, f.shell, f.store
assert(shell.detail:start_reading() and reader.context.chapter_id=='c1')
assert(reader:switch_chapter(1) and reader.context.chapter_id=='c2')
local saved = store:get_history('zero','a')
assert(saved.chapter_id=='c2' and saved.page_index==1,
    'switching must save the new chapter before leaving its first page')
reader:close('back')
assert(shell.detail:start_reading())
assert(reader.context.chapter_id=='c2' and reader:current_page()==1,
    'reopening from the same detail must resume the switched chapter without extra taps')
assert(store:get_history('zero','a').chapter_id=='c2',
    'reopening must not replace saved progress with an old selection')
assert(reader:switch_chapter(1) and reader:go_to(2))
reader:close('back')
assert(shell.detail:start_reading() and reader.context.chapter_id=='c3' and reader:current_page()==2,
    'the latest chapter page must be used even when it is the same detail controller')
reader:close('back')
assert(shell.detail:select_chapter(f.chapters[1]))
assert(shell.detail:start_reading() and reader.context.chapter_id=='c1' and reader:current_page()==1,
    'explicit manual selection must not be replaced by the latest resume chapter')
assert(reader:switch_chapter(1))
local restarted = fixture(store)
assert(restarted.shell.detail:start_reading()
    and restarted.reader.context.chapter_id=='c2' and restarted.reader:current_page()==1,
    'a new controller must resume a switch without calling close or turning another page')
restarted.loader.request=function(_,_,_,cb)cb.on_error{code='transport_error'};return{}end
assert(restarted.reader:switch_chapter(1))
assert(restarted.reader.context.chapter_id=='c2' and store:get_history('zero','a').chapter_id=='c2',
    'failed first-image loading must not advance the saved chapter')
-- A fresh manual choice after a switch must supersede the new saved chapter,
-- even if the detail still has its earlier history snapshot.
local manual=fixture()
assert(manual.shell.detail:start_reading() and manual.reader:switch_chapter(1))
manual.reader:close('back')
assert(manual.shell.detail:select_chapter(manual.chapters[3]))
assert(manual.shell.detail:start_reading() and manual.reader.context.chapter_id=='c3',
    'syncing stale history must preserve a later explicit choice')
local bounce=fixture()
assert(bounce.shell.detail:start_reading())
bounce.reader:close('back')
assert(bounce.shell.detail:select_chapter(bounce.chapters[2]))
assert(bounce.shell.detail:start_reading() and bounce.reader:switch_chapter(-1))
assert(bounce.store:get_history('zero','a').chapter_id=='c1')
bounce.reader:close('back')
assert(bounce.shell.detail:start_reading() and bounce.reader.context.chapter_id=='c1',
    'a round trip to the exact old chapter/page must not restore a consumed manual choice')
local retry=fixture()
assert(retry.shell.detail:start_reading())
retry.reader:close('back')
assert(retry.shell.detail:select_chapter(retry.chapters[3]))
local request=retry.loader.request
retry.loader.request=function(_,_,_,cb)cb.on_error{code='transport_error'};return{}end
assert(retry.shell.detail:start_reading())
assert(retry.store:get_history('zero','a').chapter_id=='c1')
retry.reader:close('back')
retry.loader.request=request
assert(retry.shell.detail:start_reading() and retry.reader.context.chapter_id=='c3',
    'a manual chapter whose first image failed must remain selected for a later retry')
local failure=fixture()
assert(failure.shell.detail:start_reading())
local notified=false
failure.reader.context.on_history_saved=function()notified=true end
failure.store.save_history=function()return false end
assert(failure.reader:go_to(2) and not notified,
    'a refused history write must not publish a successful save')
failure.store.save_history=function()end
assert(failure.reader:go_to(1) and not notified,
    'a history write without success acknowledgement must not publish a save')
local throwing=fixture()
assert(throwing.shell.detail:start_reading())
throwing.reader.context.on_history_saved=function()error('observer failure')end
assert(throwing.reader:go_to(2) and throwing.store:get_history('zero','a').page_index==2,
    'an observer error must not fail a displayed page or its persisted history')
local stale=fixture()
assert(stale.shell.detail:start_reading())
local callback=stale.reader.context.on_history_saved
assert(stale.shell:show('detail',{card={site_id='zero',comic_id='b'}}))
callback{chapter_id='c3',page_index=2}
assert(stale.shell:model().detail.card.comic_id=='b' and stale.shell:model().selected_chapter_id=='c1',
    'a disposed detail history callback must not change another view')
print('reader_history_reopen_spec: passed')
