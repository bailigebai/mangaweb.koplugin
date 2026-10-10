# 哔哩哔哩协议核对

## 已验证的官方接口和运行边界

- 官方登录组件使用 passport.bilibili.com 的 `/x/passport-login/web/qrcode/generate` 与 `qrcode/poll`，每2秒轮询。
- generate 匿名实际返回 code=0，data 有 url/qrcode_key；poll 业务状态是未扫86101、待确认86090、过期86038、成功0。
- 官方漫画首页请求模块默认 POST JSON，并增加 device=pc/platform=web/nov=27；GET 主站 `/x/web-interface/nav` 可验证账号。
- 官网登录后调用 `/twirp/user.v1.User/GetNewbieInfo`。本插件将其成功作为候选漫画会话验证门槛；未返回成功不能保存为已登录。
- 已连接 Kindle 提供 `frontend/ui/widget/qrwidget.lua` 与 `ffi/qrencode.lua`，可本地生成二维码。
- 固定官方HTTPS端点、禁止自动重定向、响应大小上限和单次完成；业务错误不返回空列表，也不记录响应正文或凭据。

## 未打通的实际读取

在电脑匿名直接联网、使用官方默认方法和参数、再次访问首页后，ComicDetail(39700)和ClassPage仍返回 code=99、data=null。没有获取用户会话。

2026-10-10进一步读取官网分类页使用的 `classify.9885fd4eae.js`，发现其请求包装层对 ComicDetail、ClassPage、GetImageIndex、ImageToken 增加 `ultra_sign` 查询参数及 `x-bili-data-sn` 请求头；收到 `bytesData` 后，调用解密函数，而非直接使用 JSON data。签名和解密模块加载 Go/WebAssembly 运行时。函数输入还包括完整请求地址、请求 JSON、buvid 和平台。

这是已核对的官网代码事实。当前纯 Lua 适配未实现这一层，不能据此宣称目录和阅读可用。该缺口可能解释 code=99，但尚未通过有效签名请求验证其是否为唯一原因；登录会话、区域和风控仍未排除。

列表和章节图片成功响应仍需核验；测试中的成功数据仅用于结构契约，不证明官方读取成功。扫码成功时的Set-Cookie及漫画服务衔接需用户实际扫码验证。T1–T4代码保留在隔离研发分支，不作为已完成站点发布。

## 继续实施后的实际探测

用户已要求继续完成，原来的范围选择等待已撤销。继续沿用独立官方接口方案，不新增插件运行时或中间服务。

- 桌面研究工具已运行官网签名组件，得到48字符签名，一次探测约27毫秒。该工具仅用于验证，未放入插件；桌面运行不证明 Kindle 提供对应运行时或足够内存。
- 严格依照官网请求包装层，签名输入含 `eot=812`，实际查询参数不发送该常量。即时签名请求 ComicDetail(39700) 仍为 HTTP 200、业务码99，无 `bytesData`。此前附带该常量的探测同样失败；不能将签名缺失定为唯一原因。
- 电脑时间与官方响应 Date 对比相差0秒。匿名 GetNewbieInfo/GetInitInfo 实际为 HTTP 401，未获得有效账号会话；账号、初始化及风控条件尚未排除。
- 实际 generate 接口返回的二维码使用 HTTPS `account.bilibili.com` 主机。已修复原先只接受 passport 主机的问题，补测合法主机及相似恶意主机、用户信息伪装、HTTP和控制字符拒绝；先失败后通过。
- 已生成本地二维码并按官方2秒间隔等待；本次未收到手机确认，300秒后停止。没有保存账号凭据，不把扫码界面或桌面契约当作真实登录成功。

下一验收门槛是用户实际扫码后取得账号及漫画服务成功响应。若签名请求仍失败，需据响应或真实官网行为定位；当前不能猜测解密密钥或注册不可阅读的站点为已完成功能。

## 新限制下的方案比较

2026-10-10后续补充：用户再次明确要求增加默认站点。官网首页现已确认含 `id=vike_pageContext,type=application/json` 的公开SSR数据，`data.latestWorks.list`实际50项，可直接复用既有JSON模块读取。实际Lua源取得首页200，547,325字节；首张缩图30,583字节、240×360 JPEG。采用不新增依赖的首页浏览阶段，详见 `bilibili-homepage-stage-2026-10-10.md`。这项公开目录成功不代表章节接口、登录或授权阅读成功。

扫码新证据：用户报告已扫码并确认，但第一轮服务端持续86101，随后86038；新二维码也过期，均无成功会话。生成响应的服务器Date与电脑约差1秒，禁缓存生成返回不同key；不能将原因定为时间错误或缓存。临时键与原始payload均留在仓库外；不在Git或安装包中。

| 方案 | 交付内容 | 成本与稳定性影响 |
| --- | --- | --- |
| A（推荐） | 先交付独立分格；哔哩哔哩进入专项设计 | 分格不依赖接口变化。后续以真实签名响应决定实现，当前不增加运行时依赖。 |
| B | 交付分格与扫码账号管理，禁用漫画读取 | 可保留账号入口，但扫码实机验证仍需完成；用户暂时不能在该站点阅读。 |
| C | 等完整阅读方案确定后一起交付 | 需先比较浏览器桥接、WASM运行时与官方可用接口路线，明确设备可行性、依赖和维护成本；当前不能承诺完整接入。 |

不猜测签名和加密格式、不绕过章节权限；是否引入新运行时或服务必须另行确认。该限制不影响已实现的分格或原有Zero站点。

## 资料

[官方首页](https://manga.bilibili.com/)、[当前请求模块](https://s1.hdslb.com/bfs/manga-static/manga-pc-ssr/assets/chunks/chunk-CGSLAhjM.js)、[分类页签名与解密包装层](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/classify.9885fd4eae.js)、[官方扫码组件](https://s1.hdslb.com/bfs/seed/jinkela/short/mini-login-v2/miniLogin.umd.min.js)。原始响应和临时二维码键保存在仓库外。
