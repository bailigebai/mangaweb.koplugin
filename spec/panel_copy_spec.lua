-- Copied core must load without either plugin's reader, storage or network.
table.insert(package.loaders, 1, function(name)
    if name:match('^webdavmanga%.') then error('cross-plugin dependency: '..name) end
end)
local session = require('mangaweb.panel_session')
local source = require('mangaweb.panel_source')
assert(type(session.start) == 'function' and type(session.configure) == 'function')
assert(type(source.open) == 'function')
for _, name in ipairs({'analysis','arrays','components','detector','geometry','view'}) do
    assert(type(require('mangaweb.panel_'..name)) == 'table')
end
assert(package.loaded['webdavmanga.panel_session'] == nil)
print('panel_copy_spec: standalone modules passed')
