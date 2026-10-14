# Zero v0.8.90 交付记录

已发布 [v0.8.90 Zero网络恢复测试版](https://github.com/bailigebai/mangaweb.koplugin/releases/tag/v0.8.90)。发布提交 `3f4ea24e0b6d7d968d3c048d08957b7bf37fa8d4`，父提交为v0.8.89；远端 `release/mangaweb-v0.8.90` 与 `v0.8.90` 标签回读指向该提交。

最终包从该提交导出并构建，解包后62组Lua规格及85个Lua文件语法检查全部通过，含真实GrayDither共享Session契约。8项Python工具与打包检查通过。包内89个公开运行文件逐字节与源码、manifest、发布提交比对一致。

GitHub三个资产均已重新下载，逐字节、大小、GitHub摘要和本地SHA-256一致：

| 资产 | SHA-256 |
| --- | --- |
| `mangaweb-0.8.90.zip` | `0c3b59b2e5196cf00d22ecd04815bc893720d776e092c1c0b1ec4b9fec498337` |
| `mangaweb-0.8.90.zip.sha256` | `9248540ce2ff9453e035fd7652315bbed4667b357a012e436e3a592c0c36389f` |
| `mangaweb-0.8.90.manifest.json` | `82c189e7fa86274a85c7bd79630f7cc43d0b5ee461ca27d1a04dcd518f6f2581` |

本机也保存了同一安装包及校验文件；没有覆盖用户旧插件程序、缓存或设置，没有修改WebDAVManga。

设备无法连接，本次未安装至Kindle，未取得新现场日志；最近截图的底层原因和设备网络恢复效果仍未验证。本版只修复两个已复现的恢复流程缺陷。运行中取消与延迟回收的交错时序未新增专项测试；独立代码复核将其列为非阻塞事项。

哔哩哔哩扫码成功是用户实机反馈，本版未新增章节或正文阅读。验收时保留cache和KOReader设置，备份并覆盖程序后重启，测试原失败Zero漫画的封面、预览、未缓存章节首图、连续翻页、重试与重开。
