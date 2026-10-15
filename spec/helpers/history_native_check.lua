-- Run with KOReader's real LuaJIT/lua-ljsqlite3. Two separate invocations:
-- luajit history_native_check.lua /plugin /scratch/history.sqlite3 write
-- luajit history_native_check.lua /plugin /scratch/history.sqlite3 verify
local root, path, mode = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = root..'/?.lua;'..root..'/?/init.lua;frontend/?.lua;common/?.lua;'..package.path
package.cpath = 'libs/?.so;'..package.cpath
require('ffi/loadlib')
local Store = require('mangaweb.store')
local store = Store:new{path=path}
if mode == 'write' then
    local f = require('spec.helpers.history_reopen')(store)
    assert(f.shell.detail:start_reading() and f.reader:switch_chapter(1))
    assert(store:get_history('zero','a').chapter_id=='c2')
    f.reader:close('back')
    assert(f.shell.detail:start_reading() and f.reader.context.chapter_id=='c2')
    assert(f.reader:go_to(2))
    print('Native chapter switch/reopen saved c2/page2; exiting without reader or DB cleanup')
    io.stdout:flush()
    local ffi=require('ffi');ffi.cdef('void _exit(int status);');ffi.C._exit(0)
elseif mode == 'verify' then
    local saved=assert(store:get_history('zero','a'))
    assert(saved.chapter_id=='c2' and saved.page_index==2)
    local f = require('spec.helpers.history_reopen')(store)
    assert(f.shell.detail:start_reading() and f.reader.context.chapter_id=='c2'
        and f.reader:current_page()==2)
    store:close()
    print('Native SQLite/new process resume: c2/page2 verified after abrupt exit')
else error('Unknown check mode') end
