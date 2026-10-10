local Sink=require('mangaweb.file_sink')
local FileTransport=require('mangaweb.file_transport')
local Models=require('mangaweb.models')
local failure='host or service not provided, or not known'
local client={request=function()return nil,failure end}
local result=Sink.download({url='https://private.example/image.jpg'},'/temp/image.part',{
    client_for=function()return client end,
    open_file=function()return{close=function()return true end}end})
assert(result.error=='transport_error' and result.cause=='dns_error',
    'file downloads must retain a safe DNS cause instead of discarding it as generic HTTPS failure')
for text,cause in pairs{['timeout']='timeout',['SSL handshake failed']='tls_error',
    ['closed']='connection_closed',['unknown private URL failure']='transport_failure'}do
    failure=text
    result=Sink.download({url='https://private.example/image.jpg'},'/temp/image.part',{
        client_for=function()return client end,
        open_file=function()return{close=function()return true end}end})
    assert(result.cause==cause)
end
local logs={}
local transport={logger={warn=function(...)logs[#logs+1]=table.concat({...},' ')end},
    file_scheduler={scheduleIn=function()return true end},file_clock=function()return 0 end,
    async={available=function()return true end,run=function(work,done)
        done(true,{error='transport_error',cause='tls_error',bytes=0});return{}end}}
FileTransport.request(transport,{url='https://private.example/image.jpg',site_id='zero',stage='image'},
    '/private/image.part',{})
local transcript=table.concat(logs,'\n')
assert(transcript:find('tls_error',1,true) and transcript:find('stage image',1,true),
    'the parent process must log the worker failure cause')
assert(not transcript:find('private',1,true) and not transcript:find('https://',1,true))
assert(not Models.error({code='transport_error'},'zero','image').user_message:find('HTTPS',1,true),
    'a generic transport error also covers HTTP and worker failures; do not diagnose it as TLS')
print('file_failure_diagnostics_spec: passed')
