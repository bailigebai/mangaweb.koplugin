local Api=require('mangaweb.bilibili_api')
local Bilibili=require('mangaweb.sources.bilibili')
local jobs={}
local http={request=function(_,spec,cb)
    local job={spec=spec,cb=cb};jobs[#jobs+1]=job
    return {cancel=function()job.cancelled=true end}
end}
-- Fields and ordering observed in the official mobile SSR on 2026-10-13.
local payload={data={detailCode=0,mangaError=3,seasonId=39700,seasonData={id=39700,
    title='测试漫画',author_name={'作者'},evaluate='简介',
    vertical_cover='https://i0.hdslb.com/bfs/manga-static/example.jpg',
    ep_list={{id=2146306,ord=68,short_title='68',title='最新',image_count=66,is_locked=true},
        {id=2097375,ord=1,short_title='01',title='第一话',image_count=83,is_locked=false}}}}}
local api=Api:new{http=http,json={decode=function(body)assert(body=='detail-fixture');return payload end}}
local scope='account-a'
local session={scope=function()return scope end,headers=function(_,url)
    assert(url=='https://manga.bilibili.com/m/detail/mc39700')
    return {Cookie='SESSDATA=test'}
end}
local source=Bilibili:new{api=api,session=session}
local detail,err
local function callbacks() return {on_success=function(v)detail=v end,on_error=function(e)err=e end}end
source:detail('39700',callbacks())
assert(#jobs==1 and jobs[1].spec.url=='https://manga.bilibili.com/m/detail/mc39700',
    'comic detail must load the verified mobile SSR, not homepage metadata')
assert(jobs[1].spec.headers.Cookie=='SESSDATA=test' and jobs[1].spec.follow_redirects==false)
local html='<script id="vike_pageContext" type="application/json">detail-fixture</script>'
jobs[1].cb.on_success(html,{status=200})
assert(detail and not err and #detail.chapters==2 and detail.chapters[1].id=='2097375')
assert(detail.chapters[1].page_count==83 and detail.chapters[2].title:find('未解锁',1,true),
    'chapters must preserve observed page counts, reading order and permission labels')
assert(source.pages==nil and not source:capabilities().pages,
    'a directory must not claim that unverified body images are readable')
assert(not source:image_headers().Cookie,'CDN requests must never inherit the account cookie')
detail=nil;source:detail('39700',callbacks());scope='account-b'
jobs[#jobs].cb.on_success(html,{status=200})
assert(not detail and err.code=='auth_required','an old account response must not publish after switching accounts')
err=nil;local handle=source:detail('39700',callbacks());handle:cancel()
jobs[#jobs].cb.on_success(html,{status=200});assert(not detail and not err and jobs[#jobs].cancelled)
source:detail('39700',callbacks());payload.data.seasonData.ep_list[2].id=2146306
jobs[#jobs].cb.on_success(html,{status=200});assert(err.code=='parse_error','duplicate chapter IDs must be rejected')
payload.data.seasonData.ep_list[2].id=2097375
source:detail('39700',callbacks());payload.data.detailCode=1404
jobs[#jobs].cb.on_success(html,{status=200});assert(err.code=='api_error','a failed SSR must not become an empty successful detail')
local before=#jobs;source:detail('39700/evil',callbacks())
assert(#jobs==before and err.code=='parse_error','only numeric comic IDs may enter credentialed URLs')
print('bilibili_chapters_spec: passed')
