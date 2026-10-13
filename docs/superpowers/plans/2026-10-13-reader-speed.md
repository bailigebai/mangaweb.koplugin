# 翻页预加载优化实施计划

> 执行方式：superpowers:executing-plans，单人逐阶段实施、测试后单独审计。

**Goal:** 目标页优先下载；后续已下载的两页提前解码，减少翻页现场处理；安装并发布用户已授权的修复版。

**Architecture:** 复用 ImageLoader 的队列和取消接口、Reader 的预加载窗口及原生阅读窗口。准备的图片只由原生窗口拥有，最多两张，离开窗口即释放，不复制 WebDAVManga 的任何运行文件。

**Tech Stack:** Lua5.1、KOReader ImageWidget/UIManager、现有 Lupa 测试。

## 证据与方案

2026-10-13 14:34设备日志首图下载4986/9011ms，处理到ready再1444/1231ms。部分后续页翻到时尚未ready。Reader复用已有预加载句柄时没有改变priority；原生update_page每次新建ImageWidget/getSize，解码缩放仍在翻页时发生。这是代码事实，不能据日志认定所有等待都由它导致。

| 方案 | 影响 | 选择 |
| --- | --- | --- |
| 增加下载并发/预加载数量 | 抢带宽、增加内存和远页处理，不解决任务排序 | 不采用 |
| 统一降低正文质量 | 缩小网络负载但影响清晰度、需站点支持 | 不采用 |
| 目标页升级优先级＋两张提前解码 | 保留原图、复用现有接口、限制内存与工作量 | 推荐，按用户已授权优化实施 |

## 阶段与文件

### 1. 目标页优先（可独立验证）
- 修改 `mangaweb/image_loader.lua`：`promote(generation,key)` 把现有任务提升为1，重排等待队列；当前有槽时启动。已在下载的同一任务继续，不能重复下载；抢占逻辑仅用原有远页取消策略。
- 修改 `mangaweb/reader.lua`：翻到尚未ready的预加载页调用promote；ready页直接显示。
- [x] `spec/reader_preload_spec.lua`、`spec/image_loader_priority_spec.lua` 先失败后通过：队列里的目标先于远页，活动目标不取消/不重复，已取消/已完成不复活；实际worker取消后保持槽位至回收，然后启动目标一次。

### 2. 原生图片提前准备（可独立验证）
- 修改 `mangaweb/ui/webdav_reader_shell.lua`：`prepare_pages(paths)` 最多2张，UI空闲回调逐张准备，命中时所有权转给当前页；淘汰、关闭、尺寸变化取消回调并释放，失败回退普通显示。
- 修改 `mangaweb/ui/koreader.lua`：适配Reader到原生窗口的准备入口。
- 修改 `mangaweb/reader.lua`：显示和后台ready时通知窗口，仅准备下一/下两页且已有下载，切换设置/会话清空。
- [x] `spec/reader_decode_cache_spec.lua` 先失败后通过：翻页命中不重复解码，最多两张、去重、关闭后回调无效、准备失败能回退；既有灰度/分格所有权规格继续通过。

### 3. 验证与交付
- [x] 全部66组Lua规格＋85项语法＋8项Python包检查；以新视角审计任务生命周期与图片所有权。
- [x] 生成v0.8.92包，设备备份、安装、回读89文件哈希一致；账号设置哈希不变，非程序文件603项路径/大小不变；回读代码66组规格/85语法通过。
- [x] 上传GitHub v0.8.92测试版，main/发布分支/标签在发布时均为48c5e93；重新下载89文件安装包，SHA256与本地及设备回读一致，交付记录见 `../../delivery-0.8.92.md`。
- [ ] 实机速度改善由用户断USB重启后验收，桌面调用次数证据不能等同Kindle耗时。

## 单独跟进哔哩哔哩

续执行既有 `2026-10-10-bilibili-account-source.md` 的章节/正文阶段。新实测设备会话GetNewbieInfo code0，ComicDetail code99；官网移动详情SSR有seasonData.ep_list，可读取真实章节（示例68章）。先核对正文合法授权读取接口再实现，不通过开放按钮伪造可阅读。凭据与原始响应在仓库外。
