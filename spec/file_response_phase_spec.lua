local Sink = require('mangaweb.file_sink')
local FileTransport = require('mangaweb.file_transport')

-- LuaSocket discards status/headers when socket.protect catches a body error.
-- Exercise the actual sink using the same connection-method contract.
local stage = 'body'
local function original_open()
    if stage == 'connect' then error('closed') end
    return {
        sendrequestline = function() if stage=='send' then error('closed') end;return 1 end,
        sendheaders = function() if stage=='send_headers' then error('closed') end;return 1 end,
        receivestatusline = function()
            if stage == 'status' then error('closed') end
            return 200, 'HTTP/1.1 200 OK'
        end,
        receiveheaders = function()
            if stage=='headers' then error('closed') end
            return {['content-type']='image/jpeg'}
        end,
        receivebody = function(_, headers, sink)
            assert(sink('partial JPEG'))
            sink(nil, 'closed')
            error('closed')
        end,
    }
end
local backend = { open = original_open }
local client = { request = function(request)
    local ok = pcall(function()
        local connection = backend.open('private.example', 443)
        connection:sendrequestline('GET', '/private?token=secret')
        connection:sendheaders(request.headers)
        connection:receivestatusline()
        local headers = connection:receiveheaders()
        connection:receivebody(headers, request.sink)
    end)
    assert(not ok)
    return nil, 'closed'
end }
local written = ''
local deps = {
    client_for = function() return client end,
    http_client = backend,
    open_file = function() return {
        write = function(_, data) written=written..data;return true end,
        close = function() return true end,
    } end,
}
local request = {url='https://private.example/private?token=secret',headers={Cookie='secret'}}
local result = Sink.download(request, '/temp/image.part', deps)
assert(result.error=='transport_error' and result.cause=='connection_closed')
assert(result.status==200, 'body failure must preserve already received status instead of reporting status=0')
assert(result.phase=='receive_body' and result.bytes==#written)
assert(result.headers['Content-Type']=='image/jpeg')
assert(backend.open==original_open, 'request-scoped observation must restore the backend')
for failed, phase in pairs{connect='connect',status='receive_status'} do
    stage=failed;written=''
    result=Sink.download(request, '/temp/image.part', deps)
    assert(result.error=='transport_error' and result.status==nil)
    assert(result.phase==phase and result.bytes==0)
    assert(backend.open==original_open)
end
for failed, phase in pairs{send='send_request',send_headers='send_headers',headers='receive_headers'} do
    stage=failed;written=''
    result=Sink.download(request, '/temp/image.part', deps)
    assert(result.error=='transport_error' and result.bytes==0 and result.phase==phase)
    assert(result.status==(failed=='headers' and 200 or nil))
    assert(backend.open==original_open)
end
local opaque = {request=function(request)
    assert(request.sink('opaque body'))
    return nil,'closed'
end}
result=Sink.download(request,'/temp/image.part',{
    client_for=function()return opaque end,open_file=deps.open_file})
assert(result.error=='transport_error' and result.status==nil and result.phase=='receive_body')
assert(result.bytes==#'opaque body')

-- The parent must keep the failure; partial data never becomes a cache path.
local logs, completed = {}, nil
local transport = {
    logger={warn=function(...)logs[#logs+1]=table.concat({...},' ')end},
    file_scheduler={scheduleIn=function()return true end},file_clock=function()return 0 end,
    async={available=function()return true end,run=function(work,done)
        done(true,{status=200,error='transport_error',cause='connection_closed',
            phase='receive_body',bytes=12});return{}end},
}
FileTransport.request(transport,request,'/private/image.part',{
    on_done=function(value)completed=value end})
assert(completed.error=='transport_error' and completed.path==nil)
assert(completed.phase=='receive_body' and completed.bytes==12)
local transcript=table.concat(logs,'\n')
assert(transcript:find('phase receive_body',1,true))
assert(transcript:find('bytes 12',1,true) and transcript:find('scheme https',1,true))
assert(not transcript:find('private',1,true) and not transcript:find('secret',1,true))
assert(not transcript:find('https://',1,true))
print('file_response_phase_spec: passed')
