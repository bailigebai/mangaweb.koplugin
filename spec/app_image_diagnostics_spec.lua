-- Default App startup used to discard the discovered production logger before loader construction.
local logs={}
local logger={warn=function(...)
    local parts={}
    for _,value in ipairs{...}do parts[#parts+1]=type(value)=='table' and (value.code or 'table') or tostring(value)end
    logs[#logs+1]=table.concat(parts,' ')
end}
package.preload['logger']=function()return logger end
package.preload['datastorage']=function()return{
    getSettingsDir=function()return '/settings'end,getDataDir=function()return '/data'end}
end
package.preload['luasettings']=function()return{}end
package.preload['mangaweb.transport']=function()return{new=function()return{
    request=function(_,request,done)done(nil,{},nil,'failure');return{}end}
end}end
local App=require('mangaweb.app')
local options={settings={reader_settings=function()return{}end},
    site_definitions={zero_origin=function()return'https://zero.example'end,list=function()return{}end},
    sources={},store={},auth={},temp_files={},page_cache={},cover_cache={},catalogue_cache={},
    license={},license_dialog={},ui={show_fullscreen=function()end}}
local app=App:new(options)
app.cover_loader.loader:_log({stage='cover',site_id='zero'},'download_start')
app.loader:_log({stage='image',site_id='zero'},'file_ready')
assert(#logs==2,'default runtime must emit both cover and reading image diagnostics without injected logger')
assert(logs[1]:find('stage cover',1,true) and logs[2]:find('stage image',1,true))
app.http:get('https://private.example/image.jpg',{site_id='zero',stage='image'},
    {on_error=function()error('a UI callback failed')end})
assert(#logs==3 and logs[3]=='callback_error',
    'default HTTP callbacks must log failures rather than silently leave a blank/loading UI')
print('app_image_diagnostics_spec: passed')
