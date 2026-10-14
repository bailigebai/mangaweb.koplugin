# 设备旋转复制：本轮范围与验收

用户确认：阅读设置提供0/90/180/270度，退出阅读保留旋转后的设备方向，与WebDAVManga原版一致；原插件不修改。

参考只读源码：`E:/jiankong/webdav-manga-handoff/worktrees/panel-reading/webdavmanga.koplugin/webdavmanga/ui_reader_shell.lua` 的 rotate_device、ui_reader.lua 的设备旋转菜单。使用KOReader公开SetRotationMode事件与onRotation，不复制WebDAV/离线/文档流程，不增加自动传感器旋转。

方案比较：推荐适配原版公开事件与MangaWeb现有窗口；完整复制WebDAV窗口会引入无关依赖；KOReader通用菜单会改变既有操作方式。

阶段1：复制四方向入口和事件流程；MangaWeb窗口当前仅清理解码缓存，没有重建尺寸，需要在新方向准备好窗口后替换旧窗口。Reader从本地原图按新视口处理，避免放大旧增强缩图；原页、页码、预加载、历史和分格设置保持。

阶段2：失败、关闭、迟到回调保护。准备失败恢复设备方向和旧窗口；同方向不重复处理。旋转后重新生成触摸范围，重置灰度全刷状态。成功后返回详情/书架时按当前方向重建。

文件：reader.lua、ui/reader_rotation.lua、ui/koreader.lua、ui/native_root.lua，新增reader_rotation_spec.lua与回归。打包白名单登记新增模块。

验收：四方向、同方向空操作、原图和滤镜处理、横屏边缘翻页、退出保留方向、分格恢复、失败保留旧页、关闭后不再绘制；完整Lua/Python回归和安装包校验。实机方向/触摸另行验证。


## 实施验证

- 阅读菜单缺入口、旧菜单可继续操作、返回根窗口保留旧绘制边界均先复现再修复。
- 独立审计发现“旋转后跳到仍在处理的预加载增强页会显示旧尺寸缩图”。真实Reader＋ImageLoader回归先复现，再在目标页显示前核对视口并复用本地原图重算；两页只下载两次，重算不增加下载。
- 76组Lua规格、89语法、9项Python检查通过。新模块进入明确打包白名单，运行文件总数93。实机方向、横屏触摸、分格与灰度效果仍需验收。
