# MangaWeb 插件安装

当前安装包：`mangaweb.koplugin-v0.8.76.zip`。

下载：[v0.8.76 安装包与校验文件](https://github.com/bailigebai/mangaweb.koplugin/releases/tag/v0.8.76)。

## 安装或更新

1. 下载并解压安装包，得到 `mangaweb.koplugin` 文件夹。
2. 退出 KOReader，将该文件夹复制到设备的 `koreader/plugins/`。
3. 更新时先在电脑备份原插件文件夹，再覆盖插件程序文件。
4. 重启 KOReader，在主菜单打开“漫画网站”。

正确路径是 `koreader/plugins/mangaweb.koplugin/main.lua`，不要多套一层文件夹。

网站设置、收藏与本地授权保存在 KOReader 设置目录，更新时请保留该目录。

## 使用与验收

- 默认只提供 Zero；其他站点需要手动新增域名和解析规则。
- 开始阅读需要有效的阅读授权，具体流程见 [README](README.md)。
- 详情页收藏只能选择一个分类；收藏页“默认”显示全部收藏，并支持多选后批量调整分类。
- 安装后请打开此前卡住的漫画，确认首图显示、翻页及退出正常。

v0.8.76 针对 JPEG 首图加载路径进行了修改。桌面检查和实际缓存图片检查已完成，Kindle 的实际阅读显示仍待验收。

完整功能说明见 [README](README.md)。
