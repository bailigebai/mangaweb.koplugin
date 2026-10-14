# MangaWeb 功能独立审查 — 2026-10-10

结论：**With fixes**。发现 2 项 Important，未发现已证实的 Critical。分格候选应先修复原图失败回退问题；账号模块应修复验证状态失真后继续后续集成。本结论不代表实机验收或完整哔哩哔哩站点可用。

审查范围：`6292dbe..2ec41ed`，工作区 `E:/jiankong/graydither.koplugin/.test-output/compat-work/mangaweb`。文件行号均相对于此目录。依据临时规划书、两个实施计划、同一 review diff、两个 progress.md 的 Ruling 和实际调用链。只读审查，唯一写入为本报告；未修改代码、索引或 HEAD。结束时 HEAD 为 `2ec41eded6930350dabeb8a358b2f3dd73ce6cf7`；工作区已有 `docs/panel-copy-acceptance-2026-10-10.md` 修改，非本审查所写。

## Strengths

- 分格会话与阅读适配分责明确。ReaderPanels 在关闭、翻页和重新处理前先脱离借用图，再关闭 Session；Reader 仍持有当前 entry，普通缓存淘汰保留当前页。原图地址来自 `entry.raw_path`，不是默认拿增强产物作为原图。
- `PanelSession` 对迟到回调、重复完成、预渲染失效和发布重入有明确令牌与缓冲所有权。核对了真实 ImageWidget 的 `_bb_disposable/image_disposable` 实现，借用分格缓冲的基本约定成立。
- 设置通过现有阅读窗口嵌入显示，旧控件回调有界面和代次检查，保存候选有回滚路径。没有引入另一个阅读器或跨插件运行时依赖。
- Bili API 使用固定 HTTPS 端点，显式关闭重定向；Http/Transport 确实传递并执行该标志。会话 Cookie 白名单、多 Set-Cookie 解析、UID 绑定和取消后的持久化守卫都位于独立模块。
- 文档明确区分桌面测试、扫码实际验证和未实现的漫画协议；未把 code99 当成空列表，也未把未验证站点注册为默认可用源。

## Critical (Must Fix)

无已证实项。

## Important (Should Fix)

### 1. 原图裁切失败后，实际退回已增强缩图并再次应用 LUT

- 位置：`mangaweb/panel_rendering.lua:58–66`；真实回退发生于 `mangaweb/panel_source.lua:100–102`。检测采样也经过 `panel_rendering.lua:43–46` 的同一 render 路径。
- 触发条件：阅读增强开启，`page_buffer` 是已增强且按屏幕缩小的整页；MuPDF 成功 openDocument/openPage/getSize，因此 `raw.kind == 'mupdf'`，但后续 `draw_new` 抛错或未返回图像。只要借用 buffer 的 viewport/scale 可用，PanelSource 会返回该 buffer 的裁切缩放产物，且不会改变 kind。
- 问题：Rendering 只在调用 render **之前** 用 `raw.kind == 'buffer'` 拒绝重复增强。上述回退绕过检查，随后又套用 LUT。用户会看到从屏幕缩图放大的模糊文字，以及重复增强导致的灰阶/细节丢失；原图裁切失败被错误呈现为成功。这直接违反本次清晰度和失败恢复要求。
- 证据：以真实 `PanelSource` 和 `PanelRendering` 在 Lua 5.1 内存运行，仅注入 MuPDF 与缓冲依赖：open/getSize 成功、draw_new 抛错、borrowed viewport/scale 成功。实际断言 `raw.kind == 'mupdf'`、返回结果非 nil、fallback_count == 1、lut_count == 1 全部成立。现有 `panel_rendering_spec` 使用替代 source，不覆盖这一真实内部回退。
- 最小修复比较：A（推荐）在 MangaWeb 包装层要求只使用原图，例如不给内部 source 提供已处理 page_buffer，让原图失败沿现有 fallback 恢复整页；B 为核心 render 增加实际产物来源标记，再由包装层拒绝缩图，契约改动更大；C 仅在回退后跳过 LUT，只解决重复增强，仍不满足清晰度，不能作为完整修复。优先 A，可保持复制核心不变。
- 验收：对真实 Source 注入上述 draw_new 失败，必须不发布任何来自 processed buffer 的分格、不调用 LUT，恢复原有整页；原图成功的 LUT 和三视图仍通过。

### 2. 已验证账号重新验证失败后仍保留 verified，关闭页面恢复“已登录”

- 位置：`mangaweb/bilibili_auth.lua:118–127`、`:42–43`、`:37–39`；用户可见状态使用点为 `mangaweb/ui/site_center.lua:38`。
- 最小序列：同一 Auth 实例已有成功验证账号（verified=true）→ 点击“验证已保存账号” → verify_account 返回 auth_required/网络错误（verify_manga 失败同理）→ UI 先显示 error → 关闭账号页触发 cancel。
- 问题：verify_saved 与失败路径都不使旧 verified 失效；cancel 根据这个旧值把 state 恢复 connected。站点中心只看 account.verified，失败当时即可能继续把账号列为已连接。用户看到已过期/刚验证失败的会话仍然通过验证，无法依赖界面判断需重新扫码。
- 证据：Lua 5.1 内存运行真实 Auth；预置 verified=true，调用 verify_saved，触发保存的 on_error。断言 error 状态同时 verified==true；再 cancel，断言 connected 且 verified==true，均成立。没有清除或改写任何真实账号。
- 最小修复：将“验证当前保存账号”的状态与“候选新账号验证”区分；前者开始或失败时令当前验证状态失效/待验证，保留凭据。不要简单在所有 _fail 中清 verified，否则切换候选失败会错误清掉旧账号已验证状态。
- 验收：上述重新验证失败后关闭/重开/站点中心应显示待验证或失败，旧账号仍保存；另外确认新账号切换失败仍保留旧账号与其有效验证状态。

## Minor (Nice to Have)

无单列项。

## Recommendations

- 把上述两个最小失败序列补为回归检查，再改最小产品边界。无需扩大为 Bili 阅读实现。
- 继续保留真实 Source 与包装层之间的集成检查；纯替代 source 的像素测试不足以证明原图失败路径。现有 native UI 测试与共享灰度测试各有价值，但桌面缓冲和手势模拟不能替代设备验收。

## 验证证据

本审查重新运行 11 组针对性规格：panel_copy、panel_rendering、reader_panels、native_panel_reader、panel_controls、panel_settings、bilibili_api、bilibili_session、bilibili_auth、bilibili_account_ui、graydither_contract；全部 PASS，84 个产品 Lua 文件语法检查通过。两个新增失败序列采用 stdin 内存执行，未保存测试文件，均复现上述行为。父任务提供的 58 组全量通过结果作为已有证据，本审查没有重复全量运行。

## Declined to judge

- Bili T5/T6 的目录、默认站点注册、章节索引、签名地址刷新、账号隔离图片缓存和完整正文读取：尚未实现；接受两份 ledger 的暂停裁定。官网新签名/加密层已有文档证据，强行凭空补实现不属于本次审查。
- 真实扫码成功后的 Cookie/漫画服务衔接，以及 GetNewbieInfo 是否能在用户环境稳定完成账号门槛：当前没有用户实际扫码和成功响应，mock 只证明内部契约。
- Kindle 实际文字清晰度、内存峰值、真实触摸与刷新观感：本次是桌面只读审查，没有新设备运行证据。共享 runtime 的 hash 检查可支持桌面契约，不能推出实机完成；接受 fixture Ruling 的有限含义。
- 旧 v0.8.86 封面、预览与正文网络故障：不在本次 Git range，且没有新现场日志，不判断根治。
- 原 WebDAVManga 安装和发行包是否与最初完全一致：本次只读 MangaWeb 和外部已提供源码材料，未执行原项目/设备全量哈希审计，不能独立认证安装状态；复制核心无跨插件 require 的检查已通过。
- 最终发布/安装候选的设备回读：未执行发布或安装。接受一次最终审查的 Ruling，但当前审查发现需修复项，现有纯分格候选不应据此报告已通过最终发布门槛。

## Assessment

**Ready to merge? With fixes.**

主要结构与取消/所有权设计符合已实施范围，桌面检查通过；两个真实边界问题仍需修复。完成对应回归后可继续分格候选和账号模块后续工作；完整哔哩哔哩站点及实机验收仍是明确未解决事项。
