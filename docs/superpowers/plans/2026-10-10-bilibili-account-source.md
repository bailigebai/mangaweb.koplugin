# MangaWeb 哔哩哔哩扫码与站点接入实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 增加内置哔哩哔哩漫画站点，以扫码登录和账号管理访问当前账号可读漫画。

**Architecture:** 站点 API、账号会话和扫码界面独立分责，复用 MangaWeb 的 HTTP、站点注册、阅读器和缓存。先证明官方访问流程，再实现账号和源适配；将站点特例限制在 Bilibili 模块和必要的图片解析接口。

**Tech Stack:** Lua 5.1、现有 MangaWeb HTTP/本地设置、KOReader QRWidget、既有JSON解码与缓存模块；无需中间服务。

**Spec:** `docs/temporary-panel-bilibili-plan-2026-10-10.md` 第1–2、5–7节，已获用户确认。

## Global Constraints

- 账号范围为扫码登录、显示昵称/UID、重新扫码切换、退出登录；保存一个当前账号。
- 使用本机二维码控件；官方2秒轮询，成功响应后再安排下一次；同一时刻最多一个轮询请求。
- 本地等待上限300秒；关闭、换站点、重新生成均取消旧请求/定时器，旧回调不能保存账号。
- 候选会话验证且保存成功后才切换账号；失败保留旧账号。CDN不携带账号Cookie。
- 内置站点不覆盖当前网站；不预置WNACG，不改变Zero和自定义站点缓存的原语义。
- 阅读按已有权限处理，购买/扣费不在本计划范围。
- 当前匿名漫画接口返回code99；完整站点阅读的实现和验收必须有实际可读响应依据。
- 从第一个计划的 MangaWeb 隔离工作区继续，避免两套工作区在 app/UI/reader 接入点同时写入。

## Review Focus

1. 二维码关闭后成功回调到达：T3验证不保存账号、不刷新旧界面。
2. Cookie重定向到CDN/相似恶意主机：T2验证严格主机边界与多Set-Cookie处理。
3. 文件保存失败或切换中失去网络：T3验证旧账号和旧状态保留。
4. 签名图片过期及账号切换后的旧缓存：T6验证有界更新一次、账号隔离和取消。
5. code99、风控页面、超大/畸形JSON被当成空列表：T1/T5验证明确错误且不覆盖成功缓存。

## 验证命令

在同一 MangaWeb 工作区运行：

```powershell
& 'E:\jiankong\webdav-manga-handoff\.venv\Scripts\python.exe' spec/run_lua_specs.py spec/<指定规格>.lua
```

每项要求明确 `PASS` 和 Lua 语法通过。外部访问与脱敏响应材料留在仓库外；测试中只使用虚构凭据、最小结构和必要的字段样例。

## Task 1：验证官方协议与 API 请求边界

**Files:** Create `mangaweb/bilibili_api.lua`；Test `spec/bilibili_api_spec.lua`；Create `docs/bilibili-protocol-2026-10-10.md` 及最小脱敏 `spec/fixtures/bilibili/*.json`。

**Interfaces:** `BiliApi:new{http,json,logger}`；`:generate_qr(callbacks)`、`:poll_qr(key,callbacks)`、`:verify_account(cookie,callbacks)`、`:verify_manga(cookie,callbacks)`；所有请求返回可取消handle。成功回调返回经过结构检查的业务数据；错误只含安全code/stage/status。

- [ ] 对已读官方网页和脚本核对实际方法、参数、服务登录衔接、账号验证接口，以及列表/详情/免费章节/图片索引的格式。仅做已授权的只读调用，查明code99的条件；记录最小可重现请求和匿名或账号依赖，不把猜测写成正常协议。
- [ ] 检查现场 KOReader 的 `qrwidget` 与 `ffi/qrencode` 可用性。无法提供现场控件时将该环境限制写入验收记录。
- [ ] 写 `business_error_and_malformed_data`：code99、JSON损坏、字段缺失、HTTP失败或超过现有响应上限均调用一次错误回调，不输出Cookie/键/签名URL，不返回空列表“成功”。
  断言：`assert(success_count==0 and error_count==1)`；`assert(not captured_log:find("test_cookie",1,true))`，后者使用虚构Cookie注入错误响应。
- [ ] Run `spec/bilibili_api_spec.lua`，确认缺失 BiliApi 时失败。
- [ ] 实现固定官方HTTPS请求与安全业务解析，复用既有HTTP取消/超时；扫码接口为已确认的generate/poll，服务账号验证按本任务实际证据固定。重定向不交给宽松的任意URL跳转。
- [ ] Run 新规格。账号接口或漫画接口仍不可访问时保留明确的失败证据，继续独立模块测试；T5/T6的完整读取验收不能用伪造成功响应代替。
- [ ] 提交：`feat: add verified Bilibili API request boundaries`。

## Task 2：账号会话、Cookie与主机隔离

**Files:** Create `mangaweb/bilibili_session.lua`；Test `spec/bilibili_session_spec.lua`。复用 `mangaweb/settings.lua` 的底层存储接口；不放宽通用 `auth.lua`。

**Interfaces:** `BiliSession:new{settings,sha256}`；`:candidate(headers)` 解析候选Cookie；`:headers(url,candidate)` 返回headers表和可选拒绝原因，非凭据目的地的表不含Cookie；`:save(account,cookie)`、`:clear()` 返回 `true` 或 `false,reason`；`:account()` 返回脱敏账号模型；`:scope()` 返回会话摘要或public。T1的API请求遇到拒绝原因须停止请求，不能跟随未知重定向。

- [ ] 写 `official_hosts_only`：仅 `passport.bilibili.com/api.bilibili.com/manga.bilibili.com` 中被T1证据要求的接口可收必要Cookie；`i0.hdslb.com`、`bilibili.com.evil.example`、非HTTPS和未知重定向均不携带凭据。
- [ ] 写 `cookie_headers_and_uid`：数组/多条Set-Cookie、Expires逗号、过期Cookie、控制字符、缺失会话和UID不匹配可区分；使用虚构字段，保留官方确认所需Cookie。
- [ ] 写 `save_and_clear_rollback`：write/flush异常或false保持原账号；读取损坏设置显示未登录。两个账号scope不同，原始凭据不出现在账号模型或缓存文件名。
  断言：`assert(session:headers("https://i0.hdslb.com/test").Cookie==nil)`；`assert(saved==false and session:account().uid=="old_uid")`；`assert(first_scope~=second_scope)`。
- [ ] Run `spec/bilibili_session_spec.lua`，确认新模块缺失时失败。
- [ ] 实现窄会话存储及候选解析，沿用现有保存/flush/回滚约定；登录与退出仅改变MangaWeb的Bilibili会话。
- [ ] Run 规格及既有 `site_settings_domain_spec.lua`，确认Zero的凭据边界保持原样。
- [ ] 提交：`feat: isolate and persist Bilibili account sessions`。

## Task 3：扫码状态机与账号操作

**Files:** Create `mangaweb/bilibili_auth.lua`；Test `spec/bilibili_auth_spec.lua`。

**Interfaces:** `BiliAuth:new{api,session,scheduler,logger}`；`:start(on_state)`、`:regenerate()`、`:cancel()`、`:logout(on_state)`；`:model()` 返回state、昵称/UID、可用操作。state为idle/generating/waiting_scan/waiting_confirm/verifying/connected/expired/error。注入 `scheduler.after(seconds,callback)` 返回可取消timer；状态推送中的二维码网址只交给当前二维码界面，不进入日志。

- [ ] 写 `polling_serial_and_deadline`：generate返回后等待2秒再poll，同一时刻一个请求；未扫描86101继续、已扫描86090等待手机确认、过期86038停止；300秒本地截止取消请求与timer，网络错误给重试。
- [ ] 写 `closed_qr_cannot_commit`：关闭/换站点/重新生成后旧poll成功不会验证或保存；重建不能启动两条轮询链。
- [ ] 写 `switch_is_atomic`：候选nav账号与漫画服务验证成功后才保存，保存失败/断网/UID不一致保留旧账号；成功后取消旧账号请求，更新scope；logout保存失败保留账号并提示错误。
  断言：`assert(max_active_polls==1)`；`assert(auth:model().state=="expired")`（300秒截止）；`assert(save_count==0)`（关闭后迟到成功）；`assert(session:account().uid=="old_uid")`（切换验证失败）。
- [ ] Run `spec/bilibili_auth_spec.lua`，确认新状态机缺失时失败。
- [ ] 实现明确状态与单链请求，取消幂等；调用T1和T2，不在模型中暴露原始凭据或密钥。
- [ ] Run 规格，要求一次操作最多一次完成回调、关闭后零持久化写入。
- [ ] 提交：`feat: manage cancellable QR login and account switching`。

## Task 4：扫码与账号界面

**Files:** Create `mangaweb/ui/bilibili_account.lua`；Modify `mangaweb/ui/koreader.lua`、`ui/settings.lua`、`ui/site_center.lua` 的Bilibili账号入口；Test `spec/bilibili_account_ui_spec.lua`。

**Interfaces:** `AccountUI:new{adapter,auth,qr_widget,scheduler}`；`:show()`、`:close()`。账号页使用T3模型；扫码页以QRWidget渲染官方网址，有状态、重新生成和返回操作。关闭调用T3 cancel；回到账号页保留已验证状态。

- [ ] 写 `qr_is_local_and_modal`：只将二维码URL传给本地QRWidget，窗口在当前modal根之上；关闭清除timer/request；控件缺失显示明确错误，不能触发KOReader退出。
- [ ] 写 `account_actions_and_gestures`：昵称/UID、扫码切换和退出正确；Bilibili不显示用户名密码输入框；多次打开、未知手势和旧回调均安全。
  断言：`assert(top_window.modal==true and qr_text==official_qr_url)`；`assert(active_timers==0 and active_requests==0)`（关闭后）；`assert(password_dialogs_opened==0)`。
- [ ] Run `spec/bilibili_account_ui_spec.lua`，确认新控制器缺失时失败。
- [ ] 实现独立UI控制器，按已有 native panel 模式封装；在站点设置只增加对应账号入口，不扩展通用密码登录规则。
- [ ] Run 新规格及既有站点中心/设置规格。实际登录需用户在手机确认，桌面mock不得当作已登录实机证明。
- [ ] 提交：`feat: add local QR login and account management screens`。

## Task 5：默认站点、列表与详情

**Files:** Create `mangaweb/sources/bilibili.lua`；Modify `mangaweb/app.lua`、`source_registry.lua`、`models.lua`；Test `spec/bilibili_source_spec.lua`、Modify `spec/app_sources_spec.lua`。

**Interfaces:** `Bilibili:new{api,session,account_auth}`；`:meta()` 返回 `id="bilibili"/name="哔哩哔哩漫画"/origin="https://manga.bilibili.com"`；`:capabilities()` 设置 `login=false,qr_login=true`，其余过滤能力只声明T1已验证项。`:list(options,callbacks)`、`:search(keyword,options,callbacks)`、`:detail(comic_id,callbacks)`、`:pages(comic_id,chapter_id,callbacks)` 按现有Models源契约返回可取消handle和结果，callbacks使用既有on_success/on_error表。

- [ ] 写 `built_in_site_and_persisted_selection`：站点列表增加bilibili，原active_site保持；内置zero/bilibili不可走自定义删除路径；WNACG仍仅用户手动添加。
- [ ] 写 `list_detail_validation_and_small_covers`：按T1真实最小fixture检查ID、封面缩图、页码、章节顺序；空合法结果和code99区分；失败不覆盖上次成功内容；章节锁定状态不被隐藏。
  断言：`assert(sources.bilibili and registry.active_id==previous_active_id)`；`assert(sources.wnacg==nil)`；`assert(error.code=="api_error")`（code99）；`assert(locked_error.code=="chapter_locked")`。
- [ ] Run `spec/bilibili_source_spec.lua` 与修改后的app_sources，确认内置站点/源缺失导致失败。
- [ ] 实现源适配，在app启动时组装独立API/session/account_auth；复用收藏/历史/详情UI。Models只新增api_error、chapter_locked、unsupported_index的固定提示，保留现有错误脱敏；Bilibili字段由源归一化，不改Zero解析和自定义HTML规则。
- [ ] Run 新规格及 `app_sources_spec/site_definitions_spec/site_center_custom_spec`，并实际检查列表→详情。T1未取得可访问漫画接口时，本项真实接入验收仍未完成，禁止标记可用。
- [ ] 提交：`feat: integrate Bilibili catalogue as a built-in source`。

## Task 6：章节图片、缓存与完整验收

**Files:** 新增源的 `:resolve_image(image,callbacks)`；仅必要时Modify `mangaweb/reader.lua`、`image_loader.lua`、`image_identity.lua` 的可选provider接入；Test `spec/bilibili_reading_spec.lua`；Modify `_meta.lua/README.md/INSTALL.md` 及 `scripts/build_package.py` 的明确产品清单；Create `docs/bilibili-acceptance-2026-10-10.md`。

**Interfaces:** `image` 包含稳定resource_id、comic_id、chapter_id、index和account_scope；`resolve_image` 返回可取消handle，成功提供临时下载URL和无账号Cookie的图片headers。原有源不提供resolver时使用原来的URL/headers路径。

- [ ] 在T1已验证的索引协议基础上写 `expired_url_retry_once`：缓存命中不请求新签名，缺失时解析，地址过期最多重新解析一次；取消后不得发布图片。
- [ ] 写 `account_scoped_originals_and_preview`：同账号的详情预览与正文复用原图，签名改变不重复缓存，另一账号不能命中前一账号的授权原图；Zero既有header隔离检查仍通过。
- [ ] 写 `locked_and_unsupported_response`：无权限章节提示未解锁；畸形索引、未知封装、签名失败均为明确安全错误，不绕过权限、不产生空白成功画面。
  断言：`assert(resolve_calls==0)`（缓存命中）；`assert(resolve_calls==2)`（一次过期后重新解析）；`assert(second_account_cache_hit==false)`；`assert(error.code=="chapter_locked")`。
- [ ] Run `spec/bilibili_reading_spec.lua`，确认可选resolver或身份边界缺失时失败。
- [ ] 以官方实际响应实现最小图片解析和稳定身份边界；复用后台文件下载、原图cache和原页预加载。无法验证的索引或授权形式保留为未完成项，不添加猜测的解密或购买逻辑。
- [ ] Run 全部规格、共享灰度契约和候选解包回归；核对包仅含MangaWeb程序、NOTICE和说明，无Cookie/日志/临时键/签名URL。
- [ ] 用户实机扫码确认后，检查昵称/UID、重启恢复、切换、退出；读取一部免费漫画测试封面→详情→预览→首图→后续预加载。已购内容需要用户账号对应章节另行实测。
- [ ] 根据该新版本安装/发布授权，备份、安装、回读核对SHA-256并记录验收；完成代码复核后再发布准确标注的版本。
- [ ] 提交：`feat: resolve authorized Bilibili pages with isolated caching`，如真实链路仍失败，汇报证据和缺口，不声称完整站点已完成。

## 执行建议

与独立分格计划使用同一执行方式，按任务顺序在同一隔离工作区继续，最后做一次完整独立复核。T1漫画协议实测与用户实际扫码均保留为验收证据，mock通过不能替代；接口受阻时可继续实现与验证独立账号模块，同时明确剩余阅读链路未完成。
