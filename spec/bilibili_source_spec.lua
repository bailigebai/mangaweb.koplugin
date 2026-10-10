local Api = require("mangaweb.bilibili_api")
local Bilibili = require("mangaweb.sources.bilibili")
local requests = {}
local http = {request=function(_, spec, callbacks)
    local job={spec=spec,callbacks=callbacks}; requests[#requests+1]=job
    return {cancel=function()job.cancelled=true end}
end}
-- Minimal public homepage fields observed on 2026-10-10. No account data.
local response={data={latestWorks={list={
    {comic_id=39919,title="请允许我自豪",author={"作者: hands2","电驴"},
        vertical_cover="https://i0.hdslb.com/bfs/manga-static/50a8fda9ed14f17e7f70ae840fc411b15c000e33.png",
        comic_introduction="嘉豪与子涵？？？？\n第二段简介",last_short_title="X+II",total=13},
    {comic_id=39869,title="第二部",author={"测试作者"},
        vertical_cover="https://i1.hdslb.com/bfs/manga-static/example.jpg",comic_introduction="简介"},
}}}}
local html='<html><script type="application/json" id="vike_pageContext">fixture-public-context</script></html>'
local api=Api:new{http=http,json={decode=function(text)
    assert(text=="fixture-public-context", "extract the JSON script, not the full HTML")
    return response
end}}
local source=Bilibili:new{api=api,clock=function()return 0 end,page_size=1}
local listing,err
local callbacks={on_success=function(value)listing=value end,on_error=function(value)err=value end}
source:list({page=1},callbacks)
assert(#requests==1 and requests[1].spec.url=="https://manga.bilibili.com/")
assert(not requests[1].spec.headers.Cookie and requests[1].spec.follow_redirects==false)
requests[1].callbacks.on_success(html,{status=200,headers={}})
assert(not err and listing.page==1 and listing.total_pages==2 and #listing.cards==1)
local card=listing.cards[1]
assert(card.site_id=="bilibili" and card.comic_id=="39919" and card.title=="请允许我自豪")
assert(card.cover_url:match("@240w_360h_1c%.jpg$") and not card.cover_headers.Cookie)
source:list({page=2},callbacks)
assert(#requests==1 and listing.cards[1].comic_id=="39869",
    "local paging must not redownload the same homepage")
local detail
source:detail("39919",{on_success=function(value)detail=value end})
assert(detail.card.comic_id=="39919" and detail.description:find("嘉豪",1,true)
    and detail.description:find("\n第二段简介",1,true))
assert(#detail.chapters==0 and source:capabilities().pages==false and source.pages==nil,
    "public metadata must not invent readable chapters")
local model
local shell={set_model=function(_,value)model=value;return true end,model=function()return model end}
require("mangaweb.ui.detail"):new{source=source,shell=shell}:show(card)
assert(model.can_read==false and model.preview_state=="empty" and #requests==1,
    "opening metadata must not start unverified chapter requests")
source:list({page=1,refresh=true},callbacks)
response.data.latestWorks.list.unexpected="not an array"
requests[#requests].callbacks.on_success(html,{status=200,headers={}})
assert(err and err.code=="parse_error", "a malformed object must not replace the catalogue as an empty array")
response.data.latestWorks.list.unexpected=nil
source:list({page=1,refresh=true},callbacks)
local refresh=requests[#requests]
response={data={latestWorks={list={{comic_id=1,title="broken",vertical_cover="https://evil.example/x"}}}}}
refresh.callbacks.on_success(html,{status=200,headers={}})
assert(err and err.code=="parse_error", "malformed catalogue must remain an error")
source:list({page=2},callbacks)
assert(listing.cards[1].comic_id=="39869", "failed refresh must preserve the last good catalogue")
source:list({page=1,refresh=true},callbacks)
local handle=source:list({page=1,refresh=true},{on_success=function()error("late publication")end})
handle:cancel()
requests[#requests].callbacks.on_success(html,{status=200,headers={}})
assert(requests[#requests].cancelled)
source:list({page=1,query="unsupported"},callbacks)
assert(err.code=="unsupported_filter", "unsupported filters must not silently show unrelated comics")
local state={page=2,query=""}
local browse_model
local browse=require("mangaweb.ui.browse"):new{source=source,shell={
    registry_state=function()return state end,
    set_model=function(_,value)browse_model=value;return true end}}
local count=#requests
browse:load{page=2}
assert(#requests==count and browse_model.page_number==2, "ordinary paging must reuse the public homepage")
browse_model.actions.refresh()
assert(#requests==count+1 and state.page==2,
    "the actual refresh action must fetch the homepage even on a cached later page")
print("bilibili_source_spec: public catalogue, local pagination, metadata-only reading boundary and cancellation passed")
