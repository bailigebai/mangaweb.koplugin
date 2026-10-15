# MangaWeb 本阶段结果 — 2026-10-10

## 当前结果

- 独立分格副本已实现，审查发现的原图失败回退问题已修复。候选版本0.8.87已同步到 E:/mangaweb.koplugin，安装包位于该项目 dist/。
- 原 WebDAVManga 没有写入；八个参考核心文件哈希仍与复制前一致，MangaWeb副本仅替换内部模块名。
- 哔哩哔哩扫码、会话和账号界面已有独立模块及桌面检查，保存在隔离研发分支；尚未注册为默认站点，不包含在分格候选包内。
- 官网目录/详情/图片接口使用签名参数和加密响应，由浏览器Go/WASM组件处理。用户要求继续后已恢复实际协议探测；电脑运行官网签名并按真实查询参数请求，仍返回业务码99。真实扫码会话尚未取得，详见协议核对。
- v0.8.87已安装至连接设备：84个程序文件回读一致，74个缓存文件保留。已发布GitHub测试版；分格触摸与旧封面/预览/正文网络问题仍待用户拔线测试和新增日志，不能宣称根治。

## 改动与证据

分格提供保留周边、独立格、自由视图、旋转、顺序、操作方向、边距及本漫画/默认配置；默认关闭。使用缓存原图，不使用放大后的已增强缩图；只有下一格提前渲染。页面、会话和设置沿用现有阅读器。

一次独立审查发现两项Important，无Critical或Minor。两项均补回归，先复现失败，再改到通过：真实Source裁切失败禁止处理图回退，真实Session恢复整页；当前保存账号验证失败失效，但候选切换失败保留原账号验证状态。

- 最新研发分支：58组规格、84个产品Lua文件通过。
- 纯分格ZIP解包回读与本地交付项目：54组规格、80个产品Lua文件通过。
- 原图成功链路使用真实LuaJIT FFI像素缓冲验证组合LUT及释放；桌面检查不等于实际MuPDF内存和Kindle触摸验收。
- 安装包84个公开文件均核对SHA-256，未包含Cookie、日志、临时二维码键或其他插件文件。
- 本地交付修改前备份：E:/jiankong/webdav-manga-handoff/backups/mangaweb-before-panels-0.8.87-20261010。只写明确程序、规格及说明路径，没有写用户缓存和配置路径。

## 验收方法

安装候选后先确认Zero普通阅读正常；阅读设置→智能分格→开启→返回阅读并长按整页。检查三个视图、文字清晰度、连续前后格、跨页、自由视图拖动/缩放；退出后检查原页位置恢复。再反复调整灰度和刷新设置，检查是否退出KOReader。具体步骤见 panel-copy-acceptance-2026-10-10.md。

## 未解决

1. 候选的实际设备触摸、内存与显示验收；安装和GitHub测试版发布已执行。
2. 哔哩哔哩真实扫码会话与成功读取响应；默认站点、目录、预览和正文阅读仍未实现。已修复真实扫码地址主机不匹配，58组研发规格通过；临时扫码无人确认后到期，未保存账号。
3. 旧封面、预览和正文网络问题的新现场验收日志，不能宣称根治。

## 执行取舍记录

以下为两份实施ledger中的全部唯一Ruling行；重复行只保留一份。取舍保留在文档，后续实施不能依赖聊天记忆。

- Ruling: Rename plan task headings T1–T6 to Task 1–6 — required by existing task-brief parser; content unchanged — cost if wrong: documentation-only rename.
- Task 1: Ruling: Replace WebDAV-specific panel_memory_spec with core-session ownership tests — original test imports the entire WebDAV reader and state, contrary to standalone copy requirement — cost if wrong: MangaWeb integration lifetime still needs T3/T4 coverage.
- Task 4: Ruling: Use GrayDither's verified compat-work/gray fixture runtime — primary directory lacks imagewidget_test_support; the copied fixtures are hash-checked by the runner — cost if wrong: shared-core verification would test a different version, so actual device remains required.
- Task 6: Ruling: One final fresh-context review and final candidate after Bilibili plan — the user approved both sequential features; avoid reviewing and packaging the same shared interfaces twice — cost if wrong: interim panel candidate is not cleared for release.
- Final: Ruling: review implemented tasks once now, range 6292dbe..HEAD — Bilibili T5/T6 require a new protocol decision, while independent panels and account modules can be audited without it; 6292dbe is the verified start of these approved features, older installed network fixes are outside this review — cost if wrong: future Bilibili reading implementation requires its own later review.
- Final: Ruling: Bili T5/T6 and signed-image cache correctness remain unimplemented — new signature/decryption scope needs user decision, not guessed protocol — cost if wrong: no Bili catalogue or reading can be delivered yet.
- Final: Ruling: real QR success / Set-Cookie / manga verification are pending — no human scan and no successful account response were obtained — cost if wrong: account UI desktop contracts may still need device/service adjustments.
- Final: Ruling: Kindle sharpness, memory, gestures and refresh require device acceptance — desktop/FFI/shared-fixture checks cannot certify native execution — cost if wrong: device-only defects remain possible.
- Final: Ruling: old v0.8.86 network failures remain separate and open — no new field log proving covers/preview/first image success — cost if wrong: users may still encounter network faults.
- Final: Ruling: certify eight original core hashes only, not all WebDAV installed/release state — this task performed no writes to that plugin and reverified source fingerprints — cost if wrong: unrelated external changes are outside this evidence.
- Final: Ruling: final new-version installation/release readback remains pending — no new install or publish was executed; interim ZIP needs replacement with reviewed fixes — cost if wrong: an old interim ZIP would miss the raw-only fix.
- Task 5/6: Ruling: pause catalogue/image implementation pending user scope choice — official classify JS adds ultra_sign and encrypted bytesData using Go/WASM; original pure Lua plan does not define that boundary — cost if wrong: full reading needs a new architecture and real-response verification. Three options are recorded in docs/bilibili-protocol-2026-10-10.md; async question remains pending.
- Verification: Ruling: syntax checks enumerate main.lua, _meta.lua and mangaweb product modules only — recursive root enumeration also checked scratch readbacks and inflated the count — cost if wrong: ancillary Lua outside the product tree would need an explicit check.

候选包SHA-256：`524fea8b69406e8aec03e1969d4a6458b5f20b69d799ec14aa28d46cdfb7cb5d`。

## 继续实施后的交付记录

- 分格发布源码：`633551e736a4f13bc154055438d2689c87280343`，84个程序文件与安装包逐一相同，未混入哔哩研发模块。
- 安装前完整备份：`E:/jiankong/webdav-manga-handoff/device-backups/2026-10-10-before-mangaweb-repair-cdbb10e3`。
- 安装回读：`E:/jiankong/webdav-manga-handoff/device-install-verify/2026-10-10-mangaweb-v0.8.87-reviewed-fa0b7d03`。
- 发布：[MangaWeb v0.8.87](https://github.com/bailigebai/mangaweb.koplugin/releases/tag/v0.8.87)，标为测试版，未替换稳定版标签。
- 发布前纯分格规格54/54、产品语法80/80；扫码主机回归先失败后通过，研发完整规格58/58、产品语法84/84。
- 新日志仍只包含10月8日的 MangaWeb 失败记录，没有本次安装后阅读成功/失败记录。已请求用户拔线测试后重新连接。
- Ruling: 用户“未完成的继续完成”撤销原交付范围等待，继续已批准的独立接口方案和安装发布；不扩展为新增设备运行时、中间服务或费用操作。
- Ruling: 官方二维码 account 主机只用于二维码内容校验，不扩大Cookie请求白名单；HTTP、伪装主机和控制字符仍拒绝。
