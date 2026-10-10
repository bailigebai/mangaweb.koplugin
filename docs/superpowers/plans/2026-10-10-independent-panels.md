# MangaWeb 独立分格副本实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 MangaWeb 内独立提供 WebDAVManga 的智能分格体验，保持原图清晰和阅读设置稳定。

**Architecture:** 从已发布的 WebDAVManga v0.4.21 复制八个核心模块，只修改内部模块命名空间。新增源图处理、阅读会话及设置控制的小适配模块，复用现有下载、原图缓存、滤镜与灰度刷新；分格关闭时不启动检测或额外解码。

**Tech Stack:** Lua 5.1、KOReader 自带 MuPDF/BlitBuffer/ImageWidget、现有 MangaWeb 本地存储；桌面检查使用已有 Python/Lupa 运行器。

**Spec:** `docs/temporary-panel-bilibili-plan-2026-10-10.md` 第1–4、6–7节，已获用户确认。

## Global Constraints

- 原 WebDAVManga 的代码、安装、设置和发布保持原样；MangaWeb 独立运行。
- 分格默认关闭；三个视图为 `context/cut/free`，旋转为 `0/90/180/270`。
- 检测采样最长边480像素、最多64格；只预渲染下一格。显示裁切使用原图，滤镜在屏幕大小的分格图上应用。
- 本漫画配置按站点＋漫画ID隔离，最多64份，超过限额清理最久未使用配置。
- 周边显示默认开启、边距默认0，可选0/2/5/10%；本漫画点按保存，长按同时设为新漫画默认。
- 配置字段为 `enabled=false, view="context", rotation=0, navigation="horizontal", reverse_navigation=false, order="follow", show_adjacent=true, margin_percent=0`；navigation可选horizontal/vertical，order可选follow/normal/manga。
- 复用现有依赖、原页预加载和同窗口设置模式；异常不得产生重复释放或旧回调覆盖新画面。
- 工作从 MangaWeb `6292dbe` 及已批准设计开始，执行时先使用 `using-git-worktrees` 检查并选择隔离工作区；只合入 MangaWeb 的明确文件。

## Review Focus

1. 增强开启后的整页缩图不是分格源图：T2验证使用 `entry.raw_path`，T6检查文字清晰度。
2. 快速进入、跳页、退出时旧检测回调到达：T3验证令牌失效与一次释放。
3. 设置页吞掉手势或被下一层覆盖：T5验证顶层操作、未知手势和回到阅读。
4. 原图缓存清理与分格持有同时发生：T3验证原页引用有效、释放后才结束下载会话。
5. 保存失败或灰度刷新重入：T5验证回滚，T4验证刷新令牌与暂停恢复。

## 验证命令

令 `$mwRoot` 为执行时选择的隔离工作区，下文每项的 `Run` 均在该目录执行：

```powershell
& 'E:\jiankong\webdav-manga-handoff\.venv\Scripts\python.exe' spec/run_lua_specs.py spec/<指定规格>.lua
```

规格执行器支持明确文件名。成功必须输出该规格的 `PASS`，并通过产品 Lua 语法检查。复制原项目尚未跟踪的必要规格和运行器到工作区时，保留来源记录，不能从其他目录隐式加载产品模块。

## Task 1：复制核心与来源契约

**Files:** Create `mangaweb/panel_{analysis,arrays,components,detector,geometry,session,source,view}.lua`；Create `docs/provenance/webdav-panels.json`；Modify `NOTICE`；Test `spec/panel_copy_spec.lua`、`spec/panel_detector_spec.lua`、`spec/panel_session_spec.lua`、`spec/panel_memory_spec.lua`。

**Interfaces:** 复制后的 `PanelSession:new(options)`、`:start(request,callbacks)`、`:move(delta)`、`:configure(values,commit,rollback)`、`:close()`；`PanelSource:new(options)`、`:open(generation,request,callbacks)`，保持原参数和返回语义。

- [ ] 写 `panel_copy_spec`，断言八模块可以在禁止加载 `webdavmanga.*` 的运行器下独立加载；声明复制来源及原 SHA-256，允许的文本变换仅为内部 `require("webdavmanga.panel_...")` 改为 `mangaweb`。
  核心断言：`assert(type(require("mangaweb.panel_session").start)=="function")`；`assert(package.loaded["webdavmanga.panel_session"]==nil)`。
- [ ] Run `spec/panel_copy_spec.lua`，确认缺少 MangaWeb 分格模块时失败。
- [ ] 从仓库外已核验的 v0.4.21 包回读复制八模块；移入相关核心规格并仅适配命名空间/测试夹具。保留 PanelsPlus MIT 版权；来源目标为 `567002ce1d53e45f35020c849125fe7ef0fd2f20`。
- [ ] Run 四项核心规格，要求无 WebDAVManga 运行时加载，几何、保护框、取消和缓冲上限断言通过。
- [ ] 只提交本任务文件：`feat: copy standalone panel core into MangaWeb`。

## Task 2：原图裁切与滤镜适配

**Files:** Create `mangaweb/panel_rendering.lua`；Test `spec/panel_rendering_spec.lua`、`spec/verify_panel_native.py`。复用 `gray_enhance.lua`、`tone_adjust.lua`，不另写滤镜算法。

**Interfaces:** `PanelRendering:new{source,settings,deps}`；`:open(generation,request,callbacks)` 实现 T1 的 source 协议。返回 handle 的 `detection_raster/ render/close` 保持原语义；`render` 返回由会话持有的缓冲或 `nil,reason`。

- [ ] 写 `original_path_and_lut`：输入 `page_path="/cache/raw.jpg"`、借用整页缓冲，断言底层打开原图，返回分格图上调用组合 LUT；借用整页图与缓存原图没有被修改。
- [ ] 写 `bounded_render_and_failed_processing`：NaN尺寸、非法像素预算、处理失败返回安全错误；新建的分格缓冲仅释放一次，借用图不释放。
  测试spy记录路径、释放和像素后断言：`assert(opened_path=="/cache/raw.jpg")`；`assert(borrowed_frees==0 and owned_frees==1)`；`assert(mapped_pixel==combined_lut[input_pixel])`。
- [ ] Run `spec/panel_rendering_spec.lua`，确认新适配模块缺失导致失败。
- [ ] 实现包装 handle：委托原 `PanelSource` 取景/原图渲染，使用 `GrayEnhance.find/build_lut/apply_lut` 与 `ToneAdjust.find/build_lut/combine_lut`；渲染预算沿用核心的屏幕预算，不使用检测缩图显示。
- [ ] Run 规格；通过已有本机 BlitBuffer 测试环境检查分格尺寸及实际 LUT 像素结果，脚本缺少原生运行环境时明确失败/未验证，不以空跑代替。
- [ ] 提交：`feat: render panels from cached originals with existing filters`。

## Task 3：阅读会话、跨页与退出

**Files:** Create `mangaweb/reader_panels.lua`；Modify `mangaweb/reader.lua` 的 `_display/_move/update_settings/go_to/close` 接入点；Test `spec/reader_panels_spec.lua`。

**Interfaces:** `ReaderPanels:new{reader,ui,source,detector,schedule}`；`:enter(desired)`、`:move(delta)`、`:exit(restore)`、`:close()`、`:configure(values,commit,rollback)`、`:pan(dx,dy)`、`:zoom(factor)`。`desired` 为 `first/last`；`move` 返回是否已消费输入，`close` 幂等。

原阅读器增加 `panel_context()` 返回当前已就绪 entry、`entry.raw_path`、阅读 generation、原位置和视口；加载中或已关闭时返回 `nil,reason`。每次 `_display` 成功后才允许分格自动续接。`enter_panel_mode/exit_panel_mode` 仅委托适配器。

- [ ] 写 `late_callback_cannot_display`，在 source 的回调前跳页/关闭，断言显示次数不增加，旧 handle 被关闭一次。
- [ ] 写 `boundary_and_fallback`：最后一格正向请求下一原页第一格，反向请求上一页最后一格；连续两页无分格仍可翻原页并继续检测。自由视图移动不翻页。
- [ ] 写 `restore_and_raw_lifetime`：退出恢复进入前 segment/pan_y/fit_mode；进入分格不重复下载，引用有效时不结束原图会话；退出先脱离分格图再释放 session。
  断言：`assert(display_count==0 and old_handle_closes==1)`；`assert(next_page==current_page+1 and resume=="first")`；`assert(download_count==initial_download_count)`。
- [ ] Run `spec/reader_panels_spec.lua`，确认新增接口缺失时失败。
- [ ] 实现适配器并接入原阅读器；普通阅读、跳转、重新处理和关闭的入口统一先结束分格借用。分格设置属于视图配置，不重启正常预加载。
- [ ] Run 本项及 `reader_loading_spec/reader_preload_spec`，要求原页预加载数量和普通阅读保持原语义。
- [ ] 提交：`feat: integrate cancellable panel sessions with page navigation`。

## Task 4：原生画面、手势与灰度刷新

**Files:** Modify `mangaweb/ui/webdav_reader_shell.lua`、`mangaweb/ui/koreader.lua` 的阅读适配点；Test `spec/native_panel_reader_spec.lua`、`spec/graydither_contract_spec.lua`。

**Interfaces:** 阅读 UI 增加 `panel_snapshot()` 返回当前整页借用缓冲及内容尺寸；`show_panel(buffer,info)` 返回明确接受与否；`restore_panel_page()` 和 `detach_panel()` 幂等。`info` 包含原页索引、格ID、格序号/总数、视图、旋转和缩放；刷新标识由非敏感字段生成。

- [ ] 写 `borrowed_image_is_detached_before_free`：`show_panel` 使用 `ImageWidget{image=buffer,image_disposable=false}`，格切换、显示拒绝和关闭均不能释放 source 借用图，格缓冲只由 T1 session 释放一次。
- [ ] 写 `panel_gesture_routing`：整页长按进入；中心点按开控制；侧边按设置移动前后格；自由视图拖动仅平移、缩放；加载和设置中消费输入，不漏给下一层。
- [ ] 写 `panel_refresh_identity`：同格重复重绘不重复计数，换格有效显示累计一次，设置/暂停/退出不累计。
  断言：`assert(panel_image.image_disposable==false)`；`assert(borrowed_frees==0)`；`assert(refresh_count==2)`，最后一项对应重复显示第一格再切到第二格。
- [ ] Run 新原生规格，确认缺少显示接口时失败。
- [ ] 在现有全屏 modal Page 中实现借用分格图和保留整页图；先切换/释放 widget 的衍生缓冲再让 owner 释放源缓冲。沿用灰度桥最终绘制与暂停机制。
- [ ] Run 原生规格及共享灰度契约：`spec/run_lua_specs.py --graydither-root 'E:\jiankong\graydither.koplugin' spec/graydither_contract_spec.lua`。
- [ ] 提交：`feat: add panel gestures and safe native rendering`。

## Task 5：本漫画设置、默认设置与同层控制

**Files:** Create `mangaweb/panel_settings.lua`、`mangaweb/ui/reader_panels.lua`；Modify `mangaweb/ui/koreader.lua` 的控制入口；Test `spec/panel_settings_spec.lua`、`spec/panel_controls_spec.lua`。利用现有 `Settings.store/read/write/flush`，不改变其他阅读配置格式。

**Interfaces:** `PanelSettings:new{settings,now}`；`:for_comic(site_id,comic_id)` 返回有效配置；`:save(site_id,comic_id,changes,as_default)` 返回 `true` 或 `false,reason`。`PanelControls:new{adapter,reader,settings}`；`:show(section)` 返回是否显示。

- [ ] 写 `scope_lru_and_validation`：默认关闭、三视图、四旋转、三阅读顺序、操作反向、四边距合法；不同站点相同漫画ID隔离；第65份配置清理最久未用项，默认设置仍保留。
- [ ] 写 `failed_save_keeps_old_settings`：write/flush抛错或返回false，当前与默认配置同时回滚，显示画面不变。
- [ ] 写 `settings_stay_on_top`：点按只改当前漫画，长按同时改默认；分格控制在现有阅读窗口中更换页面，旧回调失效，未知手势不崩溃，退出控制恢复分格。
  断言：`assert(preferences:for_comic("zero","1").enabled==false)`（全新设置）；`assert(saved==false and restored_config.view=="context" and restored_config.enabled==false)`（初始context/关闭，尝试改为cut/开启但保存失败）；`assert(manager.stack[#manager.stack]==page)`。
- [ ] Run 三项新规格，确认新设置/控制模块缺失时失败。
- [ ] 实现独立验证及保存路径；复用现有 `reader_refresh/reader_filters` 的同窗口控制方式和 T1 `configure` 的 commit/rollback 语义。
- [ ] Run 新规格及 `reader_controls_spec/reader_refresh_spec`。
- [ ] 提交：`feat: manage per-comic panel preferences in reader controls`。

## Task 6：完整检查、安装包与实机验收

**Files:** Modify `scripts/build_package.py` 的明确产品清单；Modify `_meta.lua/README.md/INSTALL.md`；Create `docs/panel-copy-acceptance-2026-10-10.md`。

- [ ] Run 全部规格及共享灰度契约。基线为原项目现有45组规格；新组数按实际输出记录，不写预定通过数量。
- [ ] 检查 diff，核对所有新接口一致、原图/LUT顺序、引用释放、取消、设置回滚、NOTICE和源码来源；最终独立复核仅聚焦改动及相关调用链。
- [ ] 核验现有MangaWeb标签后选择下一未使用的补丁版本，更新_meta、说明及明确运行清单。运行 `python scripts/build_package.py` 生成候选包，解包后以 `--plugin-root` 再运行相关规格，核对文件与SHA-256，验证不包含设备日志、账号或其他插件文件。
- [ ] 获得针对该新版本的安装/发布授权后备份并安装；回读核对哈希。用户拔USB重启，验证长按进入、三视图、边距/旋转、连续前后格、跨页/失败回退、退出恢复和设置稳定性，同时复测普通阅读。
- [ ] 记录实机成功/失败与未完成项。原有封面和网络故障单独记录；未经实机验证的候选包明确标识。
- [ ] 提交本任务文档及打包变更；原 WebDAVManga 工作区和发行包哈希应与执行前一致。

## 执行建议

建议在当前对话由主实现者按任务顺序完成，再对整份改动做一次独立复核。原图、会话、界面和设置共享接口，连续实现可以减少交接与重复读取；分任务委派实现与复核会使用更多独立上下文。等待用户确认计划与执行方式后开始产品代码修改。
