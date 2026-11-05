# Changelog

## v22.7 (2026-11-05)

### 真机第六轮 · 找到"下到网页"的真凶：链接形状
前面几轮一直在治"下回来的是网页"，现在定位到**根因不在 cookie，在 URL 本身**。

**真机复现（同一台机器、同一个视频）：**

| 链接形态 | 结果 |
|---|---|
| `https://b23.tv/hoIux0u`（分享短链） | ❌ 存成 `P1.html`(6.59 KB) → remux 报 `Invalid data found` |
| `https://www.bilibili.com/zh-Hans/video/BV1cwxf6TE2H`（短链 302 落地页） | ❌ 只认出一个 `html` 格式 |
| `https://www.bilibili.com/video/BV1cwxf6TE2H`（规范形） | ✅ **直接下成 1080P，55 MB，全程无 cookie** |

**根因**：yt-dlp 的 B 站提取器 `_VALID_URL` 只认 `bilibili.com/video/BVxxx`，
**不认 `/zh-Hans/` 前缀** → 短链 302 过去就掉进通用提取器 → 把网页当媒体抓。
（所以之前让 Mike 折腾 SESSDATA 也是治标 —— 引擎压根没走到"要 cookie"那步。）

**修法（第一层 · 链接归一化，零配置）**：
`normalize_url()` 在把链接交给引擎之前规整成规范形状：
- 认 `b23.tv` 短链（跟一次 302 拿真实地址）
- 认 `/zh-Hans/video/`、`/video/`、`/av` 号、`bangumi/play/ep|ss`、`bangumi/media/md`、`cheese/play/ep`
- 抽 `BV`/`av`/`ep`/`ss`/`md` 号，重建成规范链接（保留 `?p=N`）
- 只处理 B 站；其它站点原样透传

在 `fetch_video_info()`（解析）和 `_cmd()`（下载）两处都做了，老任务/手改 URL 也兜得住。

### 验证
- 端到端：`b23.tv/hoIux0u` 与 `/zh-Hans/...` 两条链接，经 `_cmd()` 实跑
  → **exit 0，产物 `P1.mp4` 55,226,665 字节（1080P）**，无需任何 cookie。
- `fetch_video_info()` 两条链接都拿到正确标题/UP主/bvid。
- `selftest` 新增 8 条归一化断言（含"非 B 站原样透传""空链接不炸"），全套闸门绿。

### 还没做（第二层，按需）
- 自动获取访客指纹（`x/frontend/finger/spi`，实测通）作为兜底
- 引擎多候选（yt-dlp → bilix）
- 会员专享高码率才需要登录 cookie（那是 B 站规则，不是工具问题）

## v22.6 (2026-11-05)

### 真机第五轮 · 站点凭据为什么等于没填
Mike 填了 B 站 cookie 还是下到网页。查出来是**两件事叠在一起**：

- **cookie 名写成了 `KEY`**：他照着输入框的提示 "KEY=VALUE" 抄，于是真的把键名写成了 `KEY`。
  发出去的是一个叫 `KEY` 的 cookie，B 站根本不认 → 还是返回网页。
  （cookie 名必须是站点真实的名字，B 站要 `SESSDATA` / `bili_jct` / `buvid3`。）
- **值是 URL 编码的**：从 DevTools/地址栏复制出来的 SESSDATA 里，`,` 变成 `%2C`、`*` 变成 `%2A`。
  原样发出去站点不认。

修掉：
- `cookie_pairs()` 现在会 **`urllib.parse.unquote()` 还原值**（`%2C`→`,`、`%2A`→`*`）。
  实测：`KEY=4ca027cf%2C1809415352%2C5a06f%2Ab1Cj…` → `4ca027cf,1809415352,5a06f*b1Cj…`。
- **保存时点破可疑键名**：键名是 `KEY` / `VALUE` / `COOKIE` / `TOKEN` 时，
  返回 `warn` 并在界面弹一句「第一个键名是 KEY —— 这多半不对: 要填站点真实的 cookie 名(如 SESSDATA)」。
- **输入框的提示改写**：placeholder 直接给 `SESSDATA=xxx; bili_jct=xxx; buvid3=xxx`，
  说明文字写明「键名必须是站点真实的 cookie 名(别写 KEY)」。

### 验证
`selftest` / `chaos_test` / `fake_yt_dlp_test` / `frontcheck`(8闸) / `smoke`(12项) 全绿。
实测 `cookie_pairs()` 对 URL 编码值的还原结果正确。

### 还没做
- 真正下载成功仍需**正确的 cookie**（名字对、值对，最好三件套齐全）。
  Decache 只能把话说清楚，不能替用户登录。

## v22.5 (2026-11-05)

### 真机第四轮 · "下载到的根本是网页"
真机日志把真因暴露出来了：

```
P1.html has already been downloaded | [download] 100% of 6.59KiB |
[VideoRemuxer] Remuxing video from html to mp4; Destination: .../P1.mp4 |
ERROR: Postprocessing: Error opening input files: Invalid data found when processing input
```

**下回来的不是视频，是一个 6.59 KiB 的网页**（B 站反爬 / 未登录），yt-dlp 把它当媒体，
再按 `--remux-video mp4` 让 ffmpeg 把 HTML 转成 mp4 → "Invalid data found"。
更糟的是那个 `P1.html` **留在盘上**，重试时引擎直接 "has already been downloaded" 跳过 ——
所以补下按钮点一次没用一次。

修掉：
- **认出这个真因**：`_is_html_bogus()` 看两条证据（引擎输出里的 `remuxing video from html`、
  目录里留下的 `P{n}.html/.htm`），命中就直接给一句能行动的话：
  「B站返回的是网页不是视频(反爬/未登录) —— 去设置页『站点凭据』填 B 站 cookie 后重试」。
- **不再做无意义的重试**：命中后第一次就判失败（没 cookie 的话重试同一个 URL 只会再拿一次网页）。
- **失败时清掉这一 P 的所有残留**（`P{n}.*`，含 `.html`/`.part`/`.ytdl`/分片），
  但保留下载开始前就存在的文件（`_before`）—— 那些不能删。
- **两份重复的报错提示清单合并成一份**（`ERROR_HINTS` / `_ERR_ZH`）：
  2026-11-05 踩过 —— 往 `ERROR_HINTS` 里加的提示根本没生效，`friendly_err()` 用的是另一份。
  顺带把 `requested format is not available` 的措辞改回更行动导向的
  「这个清晰度没有可用的格式 —— 换一个清晰度, 或者选『自动(最优)』」。

### 验证
`selftest`（含 `friendly_err` 的三条断言）/ `chaos_test` / `fake_yt_dlp_test` /
`frontcheck`(8闸) / `smoke`(12项) 全绿。
实测：`friendly_err("Remuxing video from html to mp4")` → 中文提示；
`_is_html_bogus()` 对含 "remuxing video from html" 的输出返回 True、对普通错误返回 False。

### 还没做
- **真正的解法是给 B 站填 cookie**（设置页 → 站点凭据）。Decache 只能把话说清楚，
  不能替用户登录。填完 cookie 后再补下，才能下到真视频。

## v22.4 (2026-11-05)

### 真机第三轮 · 播放列表在播放页终于能看见了
Mike 指出：重点是**播放列表在视频播放页面要能正常显示使用**。查出来是两个叠在一起的坑：

- **面板打开了，但永远是透明的**（真因）：
  `body.pm-open :not(#pmodal):not(#pmodal *){animation-play-state:paused!important}` 这条
  「播放器打开时暂停一切动画」的规则，把 `#listPanel` / `#qpanel` 也带上了 —— 它们是
  `#pmodal` 的**兄弟**，不是后代。而这两个面板的进场动画是
  `panelIn{from{opacity:0}}` + `fill-mode:both` → 动画被暂停在第 0 帧，
  **面板 opacity 永远停在 0**。所以从播放器里点「列表」：DOM 里 class 加上了、
  尺寸位置都对、22 行也渲染了，但屏幕上什么都没有。
  修法：把这两个面板从那条规则里排除。
- **顶栏会自动隐藏，隐藏时 `pointer-events:none`**：`poke()` 3 秒后 `hideCtrl()` 把
  `#phead` 也加上 `.hide`（透明 + 禁点）。正在播放时顶栏消失，用户点「列表」
  实际点在了画面上（只是把顶栏唤回来），要连点两次才开得出来。
  修法：**顶栏不再参与自动隐藏**，只收底栏；列表面板/队列面板开着的时候连底栏也不收。
- 之前给媒体库加的那颗常驻列表按钮保留 —— 两条路都能开。

### 验证
`frontcheck`(8闸) / `smoke`(12项) / `selftest` 全绿。
浏览器实测（390×844 移动视口，真实点击）：进播放器 → 等 4 秒（过了自动隐藏）→
顶栏仍在（`pointer-events:auto`）→ 点「列表」**一次**就开出面板：
`opacity=1`、`rect=[38,109,340,639]`、`z=200`、22 行、缩略图和 P 标签齐全
（截图人工核对：面板不透明、条目和封面都看得见）。

## v22.3 (2026-11-05)

### 真机第二轮 · More on-device fixes
Mike 又跑了一轮，三个问题：

- **播放列表彻底摸不到了**：面板只有播放器里的「列表」按钮能开，关了播放器就再也开不了。
  现在媒体库搜索框旁边多了一颗常驻按钮，和播放器共用同一个 `togglePlaylist()`；
  而且从媒体库直接开时会先 `buildFlat()`（以前 FLAT 只在开播时才构建，直接开就是空面板）。
- **下载还是失败**（`Invalid data found when processing input`）：根因是 DASH 音视频分离后
  ffmpeg 合并阶段拿到的分片是坏的（反爬/网络中断）。现在第一次失败会自动改用
  **单文件兜底格式**（`b[ext=mp4]/b`）重试 —— 不下分离流就不需要合并，整条合并链直接绕开。
  判定函数 `_is_merge_err()` 认 `invalid data found` / `error opening input files` /
  `decoding failed` / `corrupt`。
- **「继续观看」缩略图不吃主题**：六个主题的封面滤镜规则里没有它。已全部补上
  （synthwave 饱和提升 / pipboy 绿磷光 / retro 做旧 / catppuccin 柔化 / geist 轻对比）。

### 新功能 · 终端绿屏着色器
设置 → 特效里多了一档 **「终端绿屏」**，对着 pipboy 主题做的：
去色 → P1 磷光绿 + 扫描线/荫罩/暗角/微曲率/滚动亮带。
新增 `hs`（phosphor）uniform，其余预设不受影响（`P.hs || 0` = 0 时整段跳过）。

### 验证
`py_compile` / 语法闸 / `selftest` / `chaos_test` / `fake_yt_dlp_test` / `frontcheck`(8闸) / `smoke`(12项) 全绿，
`sync_install.mjs` + `bash -n install.sh` 通过。
浏览器实测（390×844 移动视口）：特效下拉出现 `term:终端绿屏`；媒体库有 34×34 的列表按钮；
点它直接开出 22 行的列表面板（含分组封面 `url(.../api/cover/EXT_532bb42570)`）。

## v22.2 (2026-11-05)

### 真机反馈修复 · On-device fixes
Mike 在手机上（Kiwi + Termux）跑了一遍，提了 8 个问题，全部定位并修掉：

- **播放列表里本地导入的视频没缩略图**：`plrowHtml` 和分组头都只在 `bvid` 是 `BV` 开头时才去要封面，
  而本地导入/全盘扫描的条目 bvid 是 `EXT_xxx` / `LOC_xxx` → 永远只剩灰底。现在只要有 bvid 就要封面
  （服务端 `/api/cover` 会懒生成抽帧，404 也只是没背景图，不会出破图）。
- **「继续观看」卡没有缩略图**：卡片以前只有播放钮 + 文字，左边空一块。补上 56×38 封面图。
- **媒体库卡片封面加载失败时显示破图**：给 `<img>` 加 `onerror` 隐藏，露出干净占位底。
- **顶部页签栏会跟着内容滚走**：`relative` 改回 `sticky`（贴视口顶）。真机上切个页签得先滑回顶部，
  等于每次点导航都多滑一次。现在它一直在。
- **右下角浮球（导入/回顶/到底）一直悬着盖住卡片**：`fixed` 改 `sticky`，
  仍在文档流里（排在媒体库末尾）但贴着视口右下角跟随滚动，不再压内容。
- **关播放器后列表面板留在原地**：面板是全局 fixed 浮层，关播放器时没一起收，
  用户切回媒体库就看见"播放列表挂在媒体库上"。现在 `closePlayer()` 会一并关掉它。
- **粘贴按钮弹「剪贴板不可用」就没下文**：安卓 WebView / Kiwi 上
  `navigator.clipboard.readText()` 经常直接 reject（非安全上下文、权限没给、内核太老）。
  现在失败时把光标送进输入框并提示"长按输入框粘贴"，这条路永远走得通。
- **播放器顶栏没跟上主题**：以前只有背景渐变是各主题自己的，标题/副标题/按钮还是通用色，
  真机上看着就是"上半截没换主题"。六个主题的标题/按钮/副标题全部收进各自的语言里。
- **下载失败只给一句英文**：`Invalid data found when processing input`（分片是坏的，
  站点反爬或网络中断）原来不匹配任何提示。现在给"点补下重试；反复失败就换引擎或装 nodejs"，
  并且失败时清掉引擎留下的临时分片（`*.part` / `*.ytdl` / `P{n}.f*`），
  否则补下时引擎以为"这 P 已经下过了"直接跳过，怎么点都是同一个坏文件。
- **浏览器标签页标题还写着 `Decache v15.1`**：改成 `Decache`（版本号只跟自己比，不写在标题上）。

### 验证
`py_compile` / 语法闸 / `selftest` / `chaos_test` / `fake_yt_dlp_test` / `frontcheck`（8 闸）/ `smoke.mjs`（12 项）全绿，
`sync_install.mjs` + `bash -n install.sh` 通过。
浏览器实测（390×844 移动视口）：页签栏 sticky、浮球 sticky 且不压卡片、
播放列表分组头与行的封面都正常加载（naturalWidth=480）、封面接口返回真实 JPEG（14228 字节）。

## v22.1 (2026-11-05)

### 审计修复 · Audit fixes
本次对整个仓库做了一次自审（后端 / 前端 / 安装器 / CI / 文档），修掉的真问题：

- **后端**：`/api/progress` 只有 POST 没有 GET → 前端「把服务端进度合并进本地账本」永远拿到 404，重装/换浏览器丢进度这条功能是死的。补 GET 端点。
- **后端**：POST `/api/progress` 在 `_do_POST` 开头已把请求体读过一次，这里又 `rfile.read()` 一次 → 读空 + **阻塞等下一段字节**，客户端直接超时。改为复用已解析的 `body`。
- **后端**：`Range` 解析有洞 —— `bytes=99999999999-` 会算出负 `Content-Length`（客户端卡死），`bytes=500-100` 倒挂，`bytes=-N`（取末尾 N 字节）被当成从头发。改为 416 / 退化成整段 / 正确取末尾。
- **后端**：上传与本地导入的文件名可以带路径（`../../x.mp4`）→ 会写到下载目录**外面**。现在只取文件名本体，并校验落地路径必须在下载目录内。
- **前端**：`index.html` 有两个 `<script>` 块之后，`frontcheck.mjs` / `smoke.mjs` / CI 的语法检查全都只抓**第一块**（37 行的诊断浮层）→ 主脚本 2600 行从未被检查过。三个工具改成抓全部块。CI 的 `sed` 管道本来就已因此报 `Unexpected token '<'`（CI 会红）。
- **前端**：「继续观看」账本迁移有个一次性锁 `_histMigrated`，页面启动时第一次 `histLoad()` 没找到旧键就把锁扣上 → 之后旧键再出现也永远搬不进来。锁删除。
- **前端**：`retro` 主题的草地渐变是 top-anchored → 草地跑到了视口**顶部**，顶栏正下方横着一道绿边。改为 bottom-anchored。
- **前端**：`mauto`（自适应）主题在 v22.0 已移除，但设置里的「自适应」chip 忘了摘 → 点了只剩半截主题，还把 `take_ui=mauto` 写进 localStorage。chip 删除。
- **前端**：`pipboy` 扫描线闪烁动画 `pipFlick` 在 v21.8 迁移场景层时被删了（交接手稿却写着「已恢复」）。补回。
- **版本**：`server.py` 的 `VERSION` 冻结在 `15.1`、`data-ver` 停在 `v15.1-20261024`、`ui-preview.mjs` 还在报 `6.13`、README badge 写 `v21.x` —— 四处各说各话。统一到 `v22.1`。
- **CI**：`selftest.py` 原来用 `HOME/"downloads"` 当下载目录，与平台默认的 `~/Downloads/decache` 在 Windows 上大小写撞车 → 本地永远红一条、CI 绿。改用 `dlroot`。
- **文档**：README 的行数（2900/4200）、闸门数（7 → 8）、主题数（七套 → 六套）、版本 badge 全部对上现实。

### 已知遗留 · Known gaps
- CI 只跑 `py_compile` / 语法检查 / `selftest` / 安装器同步校验；`frontcheck.mjs`、`smoke.mjs`、`chaos_test.py`、`fake_yt_dlp_test.py` 仍不在 CI 里。
- `_progress.json`（观看进度账本）没进 `.gitignore`，理论上会被 git 跟踪。
- `pipboy` / `mauto` 的部分 CSS 残留（`mauto` 整套、若干重复 `@keyframes pageIn`）还没清。

## v22.0 (2026-11-03)

### 主题与播放器 · Theme & player
- 修复切主题后播放器无法操控（氛围光双层重写 + 性能模式，重活降级可关）
- 播放列表硬编码色清零，全部走主题令牌
- 移除 mauto 自适应主题（旧存档自动回退 mono）

### 媒体库 · Library
- 列数切换 1/2/3/auto + 顶/底跳转按钮
- 本地视频导入：扫描目录里的视频一键搬进媒体库（move/copy、自动抽帧封面、每视频独立文件夹）
- 修复：EXT 原地收编会把整个扫描目录拉黑，导致新视频既不被扫描发现也进不了导入候选的存量 bug
- 修复：三列模式卡片顶破列宽导致横向溢出屏幕（grid 卡片固有宽未约束）
- 修复：氛围光双层交叉淡入在低清画布上高频狂闪，改为单层持续重绘（24×14 重绘成本可忽略）
- 修复：打开视频偶发黑屏（音频正常画面黑）——补齐「刚打开」时机的三层自动修复链，不再需要杀浏览器
- 「导入本地」按钮加入右下常驻浮球组，窄屏不用再滚动找

## v16.2 (2026-10-24)

这是迄今最大规模的社区驱动改版。自 v6.18 起，经过多轮真机反馈迭代，累计修复 40+ 问题、新增 20+ 功能。

### 主题系统重做 · Theme overhaul
- 七套主题：mono / geist / catppuccin / synthwave / retro / **pipboy 终端** / **mauto 自适应**（取视频主色实时生成色板）
- 每主题独立视觉语言：像素庄园（星露谷×MC×WinXP 融合）、终端（TUI×打字机×辐射绿）、复古未来（铬字落日+体积光）、奶油玻璃、工程网格
- 全局 UI 融合层：卡片顶面主题光 + 环境辉光 + 封面熔接 + 毛玻璃透出，杜绝"纸片感"
- 播放器全区域逐主题接管：进度条/封面底板/中央键/控制坞

### 播放器重做 · Player
- 着色器特效四档：CRT / VHS / 胶片 / 霓虹，播放器内一键切换
- 中央大播放键（常显状态灯）、控制条 3 秒自动隐藏、顶栏集成 FX/睡眠/列表/队列
- 睡眠定时（15/30/45/60 分钟）、最近播放、亮度手势锁 100%（5% 步进+吸附）
- 章节功能移除（含进度条分段条）

### 功能新增 · New features
- 独立设置页（原散落于下载页的六项设置收拢 + 睡眠/最近播放/统计三张新卡）
- 观看进度备份到 server（`_progress.json`）— 续播卡片跨浏览器、重装不丢
- 批量下载（多行粘贴）、下载历史 chips、媒体库统计仪表盘
- 文件夹浏览升级：人性化大小、修改时间、全路径面包屑、位置记忆、名称过滤

### 渲染管线 · Render pipeline
- `requestVideoFrameCallback` 驱动（帧率绑定视频源，比 rAF 省一半渲染）
- 黑屏自愈架构：每 30 帧像素自检 → 自动重建 GL → 连续失败回退原画
- 60 秒纹理定期保养（防 Chrome GPU 进程渐进劣化）
- 合成层快路径、时间流速感知优化

### 性能治理 · Performance
- 毛玻璃降档（blur 18→10）、drop-shadow 合成层清零（改 box-shadow 多层）
- 轮询页面门控（媒体库不再 3 秒空转重建 60 卡）、死端点/死词条/死 CSS 清理
- i18n 全对齐（zh 211/en 213）、七闸持续全绿

### 修复精选 · Notable fixes
- 特定主题播放黑屏（场景层摘除）、双视频叠加（纹理尺寸守卫）、
  logo 打字机布局副作用、纯音频视频黑屏、中英混杂（切语言重载）、
  统计字段、历史溢出、窄屏控制条拥挤、server 版本号冻结

[完整演进见 HANDOVER.md 45 节记录]
