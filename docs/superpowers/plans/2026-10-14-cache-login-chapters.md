# 全局缓存、Zero登录与章节续读实施计划

> 使用 superpowers:executing-plans 在当前会话逐项实施，先写失败测试再修改；最终整轮复核。用户已确认设计和当前会话执行，后续追加上一话/下一话与任意章节历史。

**Goal:** 统一缓存额度与定时清理，保护Zero旧会话并等联网后发请求，实现阅读内切章和任意章节续读。

**Architecture:** 复用现有缓存文件、保护标记与调度器；小型协调器负责全局计量和分批清理。登录使用隔离会话，网络入口接KOReader的连接接口。章节切换复用Reader.open与源pages接口，历史新增章节字段。

**Tech Stack:** Lua 5.1、KOReader现有网络/调度/SQLite、Lupa、现有Python打包检查；不新增依赖。

**Spec:** ../../temporary-global-cache-design-2026-10-14.md；本轮用户追加“直接上一话/下一话、任意章节记录”。

## Global Constraints

- 只改MangaWeb；原WebDAVManga和KOReader运行库不改。
- 总缓存超过上限清理到下限；默认256/192MB、10分钟，保护使用中/预加载/收藏封面。
- 离线缓存可打开；不更改证书验证、不更换域名、不发送明文密码、不扩大自动重试。
- 敏感原始日志、Cookie、账号、授权凭据不入仓库/安装包。
- Bilibili正文仍未实现，不作为本轮可读验收。

## Review Focus

- 取消/关闭后迟到登录回调不能写入会话；验证新密码时不能使用旧Cookie。
- Wi-Fi开关开启但未连接、联网提示取消、并行列表请求：等待有界、取消有效、只触发一次联网。
- 清理过程中图片被使用、只剩保护项、删除失败：不误删、不虚报已达下限。
- 修改策略保存失败、对话框叠层、退出后计时器：旧设置保留，输入可操作，不继续删除。
- 选择非首章、历史章节已移除、快速重复切章、章节加载失败：历史绑定章节，迟到结果不串章。

### Task 1: 登录隔离与准确错误类别

**Files:** mangaweb/auth.lua、sources/zero.lua、http.lua、models.lua、ui/settings.lua；spec/zero_login_session_spec.lua、network_errors_spec.lua。

**Interfaces:** Auth:staged(site_id)返回只在内存中保存Cookie的Auth；提交前比较原会话/域名未改变。Zero:login返回覆盖全流程的可取消handle，验证成功才提交。Models.transport_code(error)返回固定脱敏类别。

- [x] RED：失败GET/POST、错误密码、取消、域名/原Cookie变动、迟到回调均不覆盖旧会话；验证成功提交一次；HTTP错误分类不含敏感原文。
- [x] 运行上述规格确认旧实现失败；实现最小隔离与取消链。
- [x] GREEN：运行新规格及Zero/站点设置相关规格，记录结果并提交。

### Task 2: 联网就绪入口

**Files:** mangaweb/network_gate.lua、http.lua、app.lua；spec/network_gate_spec.lua。

**Interfaces:** Gate:run(start,on_error)返回cancel handle；实例合并等待者，使用isConnected/runWhenConnected和现有scheduleIn，等待最多45秒；start返回实际请求handle。HTTP HTML和文件入口统一接入，文件等待取消仍须on_reaped一次。

- [x] RED：未连接时零HTTP请求、并行只请求连接一次、连上后只执行有效等待者；取消/超时/离开后不发送；文件回收恰好一次。
- [x] 实现非阻塞门控；不在UI线程进行isOnline的同步DNS探测。
- [x] GREEN：新规格、HTTP/文件取消回归通过并提交。

### Task 3: 全局缓存后端与定时器

**Files:** mangaweb/cache_manager.lua、page_cache.lua、catalogue_cache.lua、settings.lua、app.lua；spec/global_cache_spec.lua、global_cache_lifecycle_spec.lua。

**Interfaces:** 后端maintenance_entries()/remove_entry(entry)负责合法文件与保护校验，CacheManager:check(force,done)/stats()/start()/stop()/configure(policy)负责跨类型清理和生命周期；使用reader设置容量与cache_check_minutes单一来源。

- [x] RED：跨类型总量、上限边界、下限目标、真实访问顺序、保护项变化、parts/链接/越界路径、失败删除、非法值、批量取消和周期退出。
- [x] 实现最近使用记录和受限删除；接入后跳过每页全局扫描；分批主线程删除，停止后迟到任务失效。
- [x] GREEN：新规格及全部封面/缓存/预加载相关回归通过并提交。

### Task 4: 我的缓存管理页面

**Files:** mangaweb/ui/cache_manager.lua、ui/site_center.lua、ui/shell.lua、ui/koreader.lua；spec/global_cache_ui_spec.lua；scripts/build_package.py。

**Interfaces:** cache_manager页面模型提供stats、policy、修改/检查/返回动作；三字段同一编辑窗口，保存成功才关闭；阅读设置缓存入口复用此页。

- [x] RED：站点列表之后出现入口、全局统计、三字段编辑同层且合法校验、保存失败不关闭/不覆盖、清理完成与保护限制提示。
- [x] 实现页面与回调所有权，登记新增运行文件白名单。
- [x] GREEN：新规格和原生窗口/阅读设置回归通过并提交。

### Task 5: 章节导航与任意章节历史

**Files:** mangaweb/store.lua、reader.lua、ui/detail.lua、ui/koreader.lua、app.lua及必要阅读控制模块；spec/reader_chapters_spec.lua、chapter_history_spec.lua。

**Interfaces:** 历史存chapter_id/chapter_title/page_index/total_pages；旧记录只在默认章节使用；Reader:switch_chapter(offset)通过context.chapters和可取消load_chapter取得新章，独立loader会话准备首图，显示成功才提交，章内页默认1，续读只匹配相同章节；阅读控制提供上一话/下一话，边界禁用。

- [x] RED：第二章保存/重开、历史恢复第二章、手动选别章不借用页码；上一话/下一话、边界、失败回退和迟到结果不串章。
- [x] 实现最小SQLite列迁移、详情章选择/恢复、阅读控制与请求取消。
- [x] GREEN：新规格、历史/详情/Reader生命周期回归通过并提交。

### Task 6: 完整验证与交付

- [x] 运行全部Lua规格与语法、Python打包检查；解包重新跑回归，核对敏感信息与运行清单。
- [x] 新上下文整轮审计；有必要修复的发现先RED再GREEN。
- [x] 更新版本、说明与交接记录，构建修复包；根据已有授权备份安装、回读、发布并校验下载。设备断开则保留包并明确未安装。
- [x] 实机联网登录、切章/续读和缓存压力验收由断USB后的设备测试确认，不把桌面/安装通过称为实机通过。

## 执行记录

- 起点9bd31bb，工作区干净。Ruling：用户指定的交接目录是独立开发副本，当前feature/graydither-integration而非main；继续在该目录实施，避免新增另一份易混淆源码。
- 已核对设备实际NetworkMgr接口：isOnline会同步解析域名；runWhenConnected仅保证已连接，失败/取消可能不回调，因此需要有界等待与取消。

- 最终审计两项重要发现均已修复并先复现失败：真实LuaSettings写盘失败被忽略；新章首图失败丢旧窗口。74组Lua、88语法、9项Python检查通过，真实设备数据库副本迁移保持原10条历史及收藏。

- v0.8.93安装并发布完成，设备92文件与包匹配，设置/数据库哈希不变，603非程序文件元数据不变。GitHub重新下载校验通过；实机操作验收待用户完成。见delivery-0.8.93.md。
