# MangaWeb 阅读设置修复计划

日期：2026-10-08；基线：916e611，MangaWeb 0.8.84。

## 目标与证据

用户要求修复 MangaWeb 书架进入失败、全刷间隔调整被遮挡及设置过程中退出 KOReader。
已确认 MangaWeb 的灰度设置入口调用外部 Session.showMenu；普通数字窗口会受模态阅读窗口影响。
现有 Reader:update_settings 对刷新偏好也会重建图片处理任务，尽管这些偏好只作用于最终绘制和刷新。
本阶段在 MangaWeb 内完成设置管理，保持原有图片算法、来源隔离、授权及缓存实现。

截图中的 show library/E003 文案仅在本地 WebDAV 漫画错误报告代码中找到，MangaWeb 没有此文案。
E003 是错误顺序号，不能据此判断原因。连接设备后只读取得最新 crash.log，确认该错误与一次后台清理退出来自 WebDAV cache.lua:281；单独的0.4.18包修复四处文件大小多返回值消费，不在MangaWeb安装包中混入其他插件。

## 方案比较

1. **推荐：复用 MangaWeb 的内嵌阅读设置页。** 宿主管理开关、间隔和时长，外部服务仅处理图片/刷新；更新 MangaWeb 即可修复遮挡，兼容已有 GrayDither 0.3.0。
2. 继续调用外部窗口并同步更新 GrayDither。共享窗口修复可复用，但用户必须更新两个包，MangaWeb 设置仍依赖外部窗口生命周期。
3. 重建全部设置界面。改动范围大，与本次缺陷无关，不采用。

## 文件与验收

- mangaweb/ui/reader_refresh.lua：小模块，复用原生内嵌面板；1～50次、默认5；时长0.10～1.00秒、默认0.30；草稿确认保存和取消；旧回调失效，保存/显示/服务异常保护。
- mangaweb/ui/koreader.lua、graydither_bridge.lua：连接宿主设置页及受保护的 settingsChanged/requestRefresh 服务方法。
- mangaweb/reader.lua：刷新/灰度偏好单独保存时不取消下载、不重新处理当前图片。
- spec：先复现宿主未拥有设置页、间隔不可修改以及设置引发图片任务重建，再验证返回/退出、保存失败及旧回调。
- _meta.lua、README、INSTALL、scripts/build_package.py：MangaWeb 0.8.85 修复候选；明确打包名单，不增加依赖或运行缓存。

## 阶段

- [x] 测试先失败，并确认失败与当前行为对应。
- [x] 最小实现，源码及共享 Session 联测。
- [x] 新上下文只读审查并处理发现的问题。
- [x] 构建、解包再测试并交付 MangaWeb 安装包。
- [x] 只读设备取证，定位书架错误及同源后台退出，单独修复WebDAV缓存。
- [ ] 安装后实机验收两个修复；当前没有改写设备，不能声明真机稳定性已验收。

本次不自动发布 GitHub，不修改设备或网页收藏。
