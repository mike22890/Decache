# decache · AI 交接书 (HANDOVER) · v6.17

> 本文档写给接手本项目的 AI 或人类维护者。读完第 0/5/6 节即可安全动手。

> English readers: see the **English Overview** below (section 1–6).
> 英文读者请直接看下面的 **English Overview**（第 1–6 节）。

---

# English Overview (full details below are in Chinese)

**Decache** is a single-folder, self-hosted local media library and video
player. Pure Python standard library on the back end, one zero-build HTML file
on the front end, no accounts, no telemetry, no cloud services.

## 1. What it is

- A local media library: scan folders, browse a tree, colour tags, favourites,
  a play queue, multi-select delete, dedupe, disk stats.
- A player: seek-bar thumbnail sprites, chapters, A-B loop, playlist, PiP,
  speed control, external subtitles with styling, four play modes.
- A downloader front-end: it parses a link, then hands the actual fetching to
  an **external, general-purpose engine** (yt-dlp by default) that the user
  installs. The project ships **no site-specific code at all** — that is a
  hard rule, see `LEGAL.md` and `CONTRIBUTING.md`.

## 2. Architecture at a glance

| Piece | What it is |
|---|---|
| `server.py` | ~2,600 lines, Python stdlib only (`http.server` + `threading`), one `ThreadingHTTPServer`, JSON over HTTP, a background worker loop for the download queue |
| `index.html` | ~2,700 lines, one file: CSS + SVG icon sprite + vanilla JS, zero build, zero external assets, i18n table with zh/en |
| `install.sh` | **generated** by `sync_install.mjs` — a self-contained installer that embeds every runtime file; never edit it by hand |
| `selftest.py` / `chaos_test.py` / `fake_yt_dlp_test.py` | 278 offline assertions total (190 / 71 / 17) |
| `frontcheck.mjs` / `smoke.mjs` | 7 static gates for the frontend + a DOM-stub smoke run (smoke.mjs also regression-tests the "Resume" card, 10 assertions) |

Data-integrity rules that everything else depends on:

- **One writer.** All library mutations go through `mutate_library()` — a
  single lock around read-modify-write. Anything that loads a snapshot, works
  for a while, and saves it back will silently wipe concurrent changes.
- **Atomic writes.** `atomic_write()` = unique temp file + `fsync` +
  `os.replace` + exponential-backoff retry on `PermissionError` (Windows loves
  to hold files open).
- **Corrupt data is quarantined, never reset.** A broken `library.json` is
  *copied* to `library.corrupt-<ts>.json` and the original is left alone; the
  app refuses to start on an empty library rather than overwriting it.
- **Path whitelist.** Every filesystem access resolves the target and
  compares **path components** (`is_relative_to`), never string prefixes.
  Deletes are validated the same way — including refusing to delete the
  download root itself.
- **Destructive ops report failure.** If a file cannot be deleted (Windows
  keeps it locked), the library entry is *kept* and the user gets a message.

## 3. Cross-platform notes

| Platform | Notes |
|---|---|
| Android (Termux) | `pkg install python ffmpeg`; `termux-setup-storage` is required or downloads land in a private folder. Android 12+ may kill background processes — the panel holds a `wakelock` and the player reloads its surface on resume (an Android Chromium bug destroys the surface and leaves black-with-audio). |
| Windows | `python -u server.py` (output buffering); the console codepage can be GBK, so the server forces UTF-8 stdout; `select()` does not work on pipes here, so the engine output is read in a thread. |
| macOS | Filenames are NFD on disk — everything is normalised to NFC before comparison. |
| Linux | Standard. |
| iOS | The **server** cannot run on iOS; the phone is only a client over the LAN, and iOS Safari plays MP4/H.264/AAC only. |

## 4. Test SOP (run all of it)

```bash
python3 -m py_compile server.py selftest.py chaos_test.py fake_yt_dlp_test.py
sed -n '/<script>/,/<\/script>/p' index.html | sed '1d;$d' > /tmp/check.js
node --check /tmp/check.js
python3 selftest.py && python3 chaos_test.py && python3 fake_yt_dlp_test.py
node frontcheck.mjs && node smoke.mjs
node sync_install.mjs
```

Check the **exit code**, not just the number of passing assertions — a test
suite that dies on its last line still prints a wall of PASS.

## 5. Known limitations (honest list)

- Web playback in the background is PiP-only; system volume/brightness are
  out of reach.
- Third-party download engines come and go; the engine is pluggable for
  exactly that reason.
- Browsers need Chromium 80+ / Safari 13.1+ (`?.` / `??` are used).
- 4K/high-bitrate playback depends on the source and the browser; the panel
  does not transcode.

## 6. Before you edit

Read this file end to end. The sections below record the reasoning behind
each non-obvious decision, plus the bugs that are easy to reintroduce
(there is a numbered "blood-stained lessons" list further down).

---

## 0. 一分钟速览

- **是什么**：**Decache** —— 跑在 Android(Termux) / Windows / macOS / Linux 上的**单文件夹便携 Web 应用**：
  本地媒体库（扫描/文件夹浏览/标签/收藏/队列/章节/字幕/查重/磁盘统计）+ 浏览器内播放器
  （缩略图雪碧图/手势/A-B/Up Next/画中画/音频模式/连播四模式）+ 链接导入
  （**外部通用下载引擎 yt-dlp**，本项目不含任何站点解析器）。
- **技术栈**：Python 3 **纯标准库**（http.server / threading / subprocess / tarfile / configparser / urllib）+
  原生 HTML/CSS/JS 单页（零构建、零外部资源、中英双语）。下载引擎**可插拔**。
- **可安装成 App**：PWA（manifest + service worker + 自绘 PNG 图标）→ 手机浏览器「添加到主屏幕」
  后点桌面图标即用，**不需要终端**。
- **开机自启**：Termux:Boot + `boot.sh`（可选安装，检测到 Termux:Boot 才自动配）；
  `start.sh` 前台保活 + 崩溃自动拉起；yt-dlp `--continue --part` 断点续传。
- **规模设计目标**：3000+ 视频（ETag/304 增量同步 + 服务端视图缓存 + 前端分页渲染）。
- **命名与边界**：项目名 **Decache**，代码里**不出现任何站点名/接口/ID 格式**
  （2026-10-21 去站点化，理由见第 10 节）。cookie 域名从用户粘贴的链接自动推断。
- **v6.0 UI**（2026-10-20 重设计）：timeless 单色风——UI 灰阶退后、封面是唯一彩色、emoji 全换内联 SVG
  图标（`<symbol>` 库）、亮暗双主题（系统跟随，播放器恒暗）、沉浸式播放器（顶栏/控制条自动隐藏、
  双击涟漪、缓冲条显示、手势提示首次显示后消失）。JS 逻辑与 API 未变，改样式别动 hook id。
- **v6.8 分P 修复 + 凭据管理（2026-10-21 用户实测驱动）**：
  ① **分P 只显示 1 个的根因**：短链跟到的最终页**自带 `?p=1`**，yt-dlp 见到 `p=` 参数就只提取
     那一P（`_type: video` 而非 `playlist`）。**修法（通用，不含站点知识）**：两段式探测 ——
     先用剥掉分P/追踪参数的 URL 试；若只得到 1 个分P，再拿**跟完的最终地址**试
     「剥参数」和「只剩路径」两种形态，谁分P 多听谁的。
     另：`strip_page_params` 必须**原样保留参数值**（`parse_qs` 会把 `%2F` 解成 `/` 再
     urlencode 回去，**破坏 URL 结构**，实测踩过）。
  ② **站点凭据管理**：按域名分组存 cookie（`cookies` 键 + `cookies/<hash>.txt` jar），
     域名留空 = 通用凭据；UI 有列表/掩码显示/删除/添加；下载时按链接域名自动挑。
  ③ **端到端真机测试** `e2e_real_test.py`：用本机真 yt-dlp 解析真实短链，断言分P 数。
- **v6.17 继续观看选错片 + 动效层（2026-10-23 用户实测驱动）**：
  ① **"继续观看"万年不变（用户原话：显示的继续播放不是前一次的，而是好几次前的）**：
     老 `renderResume()` 遍历所有 `take_pos_*`，取 **pos 秒数最大** 的那条 ——
     上次看 40 分钟的老片永远压过昨天看 2 分钟的新片，跟"最近"毫无关系。
     现在另存一本带时间戳的账本 `take_hist_v1`（`{r,t,d,at}`，新在前，≤40 条），
     由 `savePos(rel, t, dur)` 统一写（进度键 `take_pos_*` 照写，恢复播放位置的逻辑没动）；
     卡片取**账本第一条**，并**跳过看完的**（`t ≥ d-15`）和刚开头的（`t ≤ 20`）、
     跳过已从库里删掉的。`closePlayer()` 关之前再钉一次并 `renderResume()` 刷新 ——
     老代码关播放器回来卡片根本不重绘。卡片多了百分比 + 一条 3px 进度细线。
     老用户升级：第一次没有账本键时，把旧 `take_pos_*` 按秒数倒序搬进账本（`at=0`，排最后），
     卡片不会突然空掉。
     **回归测试在 `smoke.mjs` 里**（12 条断言，桩环境把 localStorage 换成真内存版）。
  ② **动效层**：只动 `transform`/`opacity`（合成器上跑，手机不重排）；
     曲线用 `linear()` 烘焙的 spring，老 WebView 自动退回 `cubic-bezier`；
     `prefers-reduced-motion` 一票否决全部归零。具体：页面切换 10px 上浮、
     卡片封面悬停轻推/按下回弹、控制条与顶栏"出用 spring 收用 ease-in"（不对称才有重量）、
     进度条滑块播放时轻微呼吸、缓冲转圈（等 220ms 才显示，秒开不闪）、
     缩略图/实时帧/片尾卡/列表面板入场的位移淡入、toast 弹簧。
     **刻意没做**：列表逐张 stagger —— 库每 30 秒轮询重绘，会有动画重播的鬼影。
- **v6.16 实时预览帧 + 回前台黑屏/白屏真修（2026-10-23 用户实测驱动）**：
  ① **缩略图从"12 段"改成"这一秒"**：老雪碧图 12 帧均布，一小时的片子每段差 5 分钟，
     拖到哪看到的都是别处的画面。新增 `GET /api/frame?rel=&t=&w=` 按需抽单帧
     （`-ss` 在 `-i` 前 = 输入侧 seek，实测 5 分钟片子冷启 350ms、缓存命中 46ms），
     按 (文件, mtime, 秒, 宽) 存 `thumbs/frames/`，全局上限 3000 张（约 30MB）自动删最旧。
     前端**雪碧图先垫底秒回，真帧到了再盖上**；同一时刻只允许一个请求在路上、
     后来的只记最新一秒（拖动天然防抖）；命中过的秒零延迟，并顺手预暖相邻一秒。
     实测：拖到 60% → 请求 `t=180`、画面时间码对得上；20% → `t=60`。
  ② **回前台黑屏有声（真因 + 老代码的死代码）**：Android Chromium 切后台会销毁
     video 的渲染表面，声音走音频线程所以照常。
     **老代码 `p.insertBefore(v, v.nextSibling)` 是原地插入 = DOM 没变 = 表面不重建**，
     "第一层修复"从来没生效过，全靠第二层整个重载流兜着（断流+跳秒）。
     现在：`webkitDecodedFrameCount` 判断帧有没有在涨（真卡住才动手）→
     ① 从 DOM 真摘下来再插回去 ② 捅一下解码器(currentTime 微移)逼重出一帧
     ③ 都不行才重载流（保位置/播放/倍速）。三层之间各等 0.8s，只在播放中才修。
  ③ **回前台整页白屏**：同一个根因的另一副面孔——GPU context 丢了，`backdrop-filter`
     的模糊层直接变白砖。`repaintAll()` 临时把全站 backdrop-filter 摘掉再挂回去
     （320ms）强制重新光栅化。`visibilitychange` / `resume` / `pageshow` / `focus` 四条路都兜。
  ④ 顺带：鼠标停在进度条上时不再被 6 秒自动隐藏连缩略图一起收掉。
- **v6.14 三路审计 + 全面加固（2026-10-21 用户要求"整体审一遍 + 别有覆盖/删除的 bug"）**：
  开了三路并行审计（后端数据完整性 / 前端功能健壮性 / 跨平台兼容），挑真问题修：
  **数据安全（最高优先）**：
  ① **删视频的路径完全不校验** → 扫描导入的"面板外目录"存的是绝对路径，
     `Path(dl) / "C:/Users/x/Movies"` 在 pathlib 里**绝对路径覆盖相对路径** →
     rmtree 删的是那个真实目录；`folder=="."` 时**整个下载目录被 rmtree**
     （用户所有下载一起没）。现在：绝对路径条目只删登记的那几个文件，
     相对路径必须 resolve 后落在 DOWNLOAD_DIR 内且不等于它本身。
  ② **坏掉的 library.json 被"改名搬走"** → 第二次读返回 `{}` → 下一次写盘把**空库**
     固化 → 标签/收藏永久消失。现在只**复制**备份，原文件留着；原文件没了但有
     损坏备份时**拒绝返回空库**（报错让人来处理）。
  ③ **5 处写库绕过 `mutate_library()`** → 下载/转码期间用户打的标签/收藏被旧快照
     **静默覆盖**。全部改成锁内合并（worker / absorb_meta / marks / universal_copy /
     delete_video）。
  ④ 删单个分P 按**文件名**清库 → 误伤同名分P 的其他视频。改成 (目录, 文件名) 双键。
  ⑤ `/api/delete` 的 rel 分支能删**任意文件**（字幕/笔记）→ 限媒体扩展名。
  ⑥ 删不掉（Windows 文件被占用）时**照样摘库条目** → 磁盘留孤儿。现在删失败就报错，
     库条目保留。
  ⑦ `universal_copy` 会删掉**用户自己的同名文件**，还把原文件从库里踢掉 →
     不再覆盖别人的文件，库里另存 `uni_file`，播放时自动优先用 `_uni.mp4`。
  **功能失效（100% 必现）**：
  ⑧ `/api/redownload` 写在 `_do_GET` 里而前端一直发 **POST** → "重新下载"从来就没
     成功过（而且 GET 有副作用 = 浏览器预取就会触发改名）。已搬进 POST。
  ⑨ 解析页"全不选"是**空按钮**：`selAll` 被定义两遍，后定义覆盖前定义 → 点了没反应。
  ⑩ 章节"在当前位置标记"抛 TypeError：块级 `const t` 遮蔽了 i18n 的 `t()`。
  ⑪ 队列/章节面板被列表面板**整个盖住**（z-index 被后面的规则覆盖成 9）→ 点了像没点。
  ⑫ 三个浮层 `top:60px` 会**盖住顶栏第二行**（顶栏现在两行 = 123px）→ 按钮点不到。
     改成按顶栏实际高度(`--pTop`)定位。
  ⑬ Windows 输出重定向时启动**直接崩**（GBK 控制台打不出 emoji）→ 强制 UTF-8 输出。
  ⑭ 桌面平台默认下载目录是 Termux 的 `~/storage/...` → Windows 上凭空多个 storage 目录，
     "扫描全盘"永远 0 结果。现在按平台给不同默认值。
  ⑮ 封面兜底用了 `inset` 简写（比 `aspect-ratio` **还晚一代**）→ 老浏览器封面全被裁成空白。
  ⑯ 亮色主题兜底写死深色 → 黑底黑字，字直接看不见。
  **新闸**（frontcheck 从 4 道加到 7 道）：同名函数声明、块级变量遮蔽全局、图标 symbol 存在。
  这三条当场抓到审计都漏掉的 `prunePos/savePos` 重复定义和 `const v` 遮蔽。
  **测试制度修正**：chaos_test 以前**最后一行就崩**（`old_engine` 未定义），
  退出码非 0 但没人看 → 验收必须同时看**退出码**和"全部通过"那行。
- **v6.13 下载链路加固（2026-10-21 用户要求"选什么清晰度都不能出错 + 仅音频必须完美"）**：
  真机真下载逐条验（真 yt-dlp + 真视频），抓出 4 个真 bug：
  ① **仅音频会把整个视频下完再抽音轨**：`yt-dlp -f <视频格式串> -x` 会先下视频、
     合并成 mp4、再抽音轨（实测 0.5MB 音轨 vs 白下 4.7MB 视频；长片子就是几个 G）。
     现在**仅音频不��视频格式串**，只下音轨（实测 0.49MB，ffprobe 确认纯 audio/aac）。
  ② **`mp4s_of()` 只认 `*.mp4`** → 音频下完"检测不到新文件" → **不入库** →
     用户下完了界面上啥也看不见。现在视频+音频扩展名都认。
  ③ **Windows 上下载整个是坏的**：`select.select()` 在 Windows 只支持 socket，
     对管道直接抛 `OSError 10038`（Linux/Termux 没事，所以一直没发现）。
     改成**线程读 + 队列**（跨平台，心跳/超时/尾行收集逻辑不变）。
  ④ **错误信息永远抓不到**：读引擎输出用 `text=True`（按系统编码解码），
     遇到中文标题的 GBK 字节直接 `UnicodeDecodeError` → **读输出的线程当场死掉** →
     错误行永远拿不到，用户看到的是"Downloading webpage | ..."这种没用的开头。
     现在固定 `encoding="utf-8", errors="replace"`；另外 `reason[:400]` 改成**掐头留尾**
     （错误行在最后面，从头截正好把真因截没了）。
  ⑤ **"重试1次"是假的**：失败路径直接 `return False`，**从来没重试过**。现在真重试；
     并且当失败原因是"这个清晰度选不出格式"时，**自动降级成"自动(最优)"再试** ——
     用户选清晰度是偏好，不是"必须失败"的理由。真机实测：选 7P(不存在) → 自动降级成功。
- **v6.12 竖屏清晰度 + 报错翻译 + 模式提示（2026-10-21 用户实机）**：
  ① **清晰度上限改成"短边"语义**：**竖屏**视频是 480x852 / 720x1280 这种，
     `height` 是**长边**（852/1280），所以 `height<=480` 一个都匹配不上 → yt-dlp 直接
     报 `Requested format is not available`（用户实测：选 480P 下载失败）。
     **修法**：`height<=N` 与 `width<=N` **两条链顶层逗号并列**（逗号 = 取其中最好的），
     横竖都命中。真站实测：竖屏 480P → 480x852、横屏 480P → 640x480，全对。
  ② **引擎英文报错翻人话**：`friendly_err()` 把 "Requested format is not available"、
     "Sign in"、403/404、磁盘满等翻成"能行动的一句话"，**原话仍然保留在后面**
     （用户要能自己排查）。认不出来的**不瞎翻译**，原样给。
  ③ **循环/倍速切换弹提示**：以前只换图标（∞ ↻ ⤨ →），根本看不出是啥模式。
     现在复用中间浮层弹出模式名（单集循环/随机/顺序/全部循环，1.3 秒），倍速同理。
- **v6.11 对齐与回归修复（2026-10-21 用户实机截图驱动）**：
  ① **缩略图与进度条强绑定**：缩略图位置一律按「进度条上播放头在哪」算（`ratio` → 
     `pbar` 矩形），**不再跟手指**。画面横滑时手指位置和时间根本不对应（时间是按 ±150s
     窗口跳的），跟着手指画 → 缩略图飞到屏幕最右，看着像"跳到片尾了"。
     `pSeekTo` 和手势共用同一个 `showThumbAt()`，别再各画各的。
  ② **手势浮层改绝对时间**：画面横滑时中间浮层显示 `1:07 / 2:05`（不是 `+35s`），
     用户才知道自己拖到了哪一段；同时**删掉重复的 toast**（以前浮层和 toast 报同一个
     `±几秒`，同一信息显示两遍还互相打架）。
  ③ **标签提示区分加/取消**：同一个标签再点一次 = 取消。以前提示写死"已标记"，用户
     分不清到底加没加 → 现在按服务端返回的 `tags` 判断，显示"已标记 / 已取消标记"。
  ④ **回前台黑屏回归修复**：Android Chromium 切后台会回收 video 渲染表面 → 黑屏有声。
     老代码用 `requestAnimationFrame` 触发修复，**但刚回前台时 rAF 可能根本不触发**
     → 修复代码压根没跑 → 黑屏照旧（用户实测回归）。现在用 `setTimeout(250)`，
     两层修复：DOM 里挪位置（强制重建 surface）→ 还不行就 `load()` 重载（保位置保播放）。
  ⑤ **全屏按钮回右下角**（用户原话："谁家好人把最大化按钮放上面中间"）。
- **v6.10 播放器重排 + 清晰度 + 多选（2026-10-21 用户实机截图驱动）**：
  ① **播放器 UI 重排**：标题**独占第一行**（第二行放章节/播放列表/队列/全屏），
     全屏按钮从控制行挪到顶栏 —— 控制行以前 7 个按钮在 360px 屏上**最后一个被挤出屏幕**。
  ② **控制条 6 秒**，且**点一下永远是「显示出来」**：老逻辑 `touchstart` 先 `poke()` 显示、
     280ms 后 `click` 处理器看到"已经显示"又藏一次 → 控制条只闪 **0.28 秒**（用户实测
     "一瞬间就消失，来不及点"）。现在单击只 `poke()`，不再有"第二次点击秒收"。
  ③ **进度条黑底可见**：轨道 `rgba(255,255,255,.30)`、填充用品牌粉渐变、
     **滑块常驻**（以前 `not(.drag)` 时宽高为 0，等于没有滑块）。
  ④ **横滑缩略图 350ms 自动消失**（以前只有进度条那条路会藏，画面横滑弹出来的缩略图
     一直挂在那）。控制条隐藏时也顺手收掉。
  ⑤ **清晰度可调**（用户要"选清晰度省空间，其余自动最优"）：下载面板加下拉
     `自动(最优) / 2160 / 1440 / 1080 / 720 / 480 / 360 / 240`，**上限语义**
     （yt-dlp `height<=N`，站点只有 360P 就给 360P）。后端 `_cmd(..., quality)`
     拼 `height<=N` 过滤，**cap=0 时格式串逐字不变**（selftest 有断言）。
     真站实测：自动→1080P、选 720→720P、选 360→360P，且仍是 avc1+mp4a（全平台兼容不破）。
     卡片上显示实际分辨率（`part.h`），省没省空间看得见。
  ⑥ **媒体库多选**：工具栏「多选」→ 卡片出勾选框 → 底部操作条（全选/收藏/删除/退出）。
     批量走 `POST /api/bulk`（**服务端一次干完**，前端循环调 delete 中途断网会删一半）。
  ⑦ **修 lost update**：`scan_videos()` 以前 load→全盘扫→save，扫描期间（手机上可能
     几十秒）用户的标签/收藏/删除全被覆盖。已改成「只读收集 + `mutate_library()` 锁内合并」。
- **v6.9 封面链路重做 + 播放器补漏（2026-10-21 用户实测驱动）**：
  ① **封面**：官方封面下不下来是因为 Referer 用了**图片自己的域名**，防盗链要的是
     **来源页域名** → 库里新增 `source_url`（下载时的网页地址），`fetch_cover(bvid, url, ref)`
     用它当 Referer。官方封面存 `{bvid}.jpg`，**抽帧图改存 `{bvid}_s.jpg`** —— 以前两者
     同名，抽帧图会把官方封面永远顶掉（用户明明有封面却显示抽帧）。老库自动迁移：
     有 `cover_url` 时老图改名 `_s.jpg`，官方封面重新生效。
  ② **抽帧避黑屏**：`snapshot_thumb` 先 `ffprobe` 拿时长，沿 12%/35%/60%/85%/5s/2s/15s/0
     依次试，每次**先用 `_probe_bright()` 量那一帧的平均亮度**，黑（YAVG<28）就换下一个，
     全黑就取最亮的那个点。旧逻辑死 seek 第 3 秒 → 片头黑场 = 纯黑封面。
  ③ **缓存击穿**：封面 URL 带 `cover_rev`（官方/抽帧分开计的 mtime 版本号），换源后
     浏览器不会继续拿 24h 旧图。
  ④ **播放器**：控制条自动隐藏 3.2s → **5s** 且**暂停时不隐藏**；打开视频即**预热缩略图**
     雪碧图（以前只有拖进度条才生成，章节面板打开永远是黑框）；章节缩略图有
     雪碧图 → 封面 → 序号三级 fallback，**绝不给黑框**；**画面上横滑**也出缩略图
     （`showThumbAt()` 抽成进度条/手势共用）。
  ⑤ **播放列表面板**（用户要 MPC-HC 那种）：播放器顶栏 ≡ 打开，面板 = 当前播放列表
     `FLAT`，每项带缩略图 + 名称 + P 号，点击即切；来源可切「全库 / 我的队列」。
  ⑥ **分P 单独删除**：分P 行加 🗑 → `POST /api/delete {rel}` 删文件，**后端同步把该分P
     从库里摘掉**（否则界面显示 0P 但文件已经没了）。
  ⑦ **修了两个真 bug**：`data-uni`/`data-redl` 改成独立属性后事件处理还在 `split("|")`
     → 「生成通用版」永远失败；`$('pQMode')` 按钮挪走后绑定代码还在 → 抛错让**整个 JS
     停摆**（媒体库都不渲染）。
- **v6.7 全面加固（智障用户标准 · 2026-10-21）**：
  两路并行代码审计（前端 2079 行 / 后端 1902 行）后按"普通用户会乱点"的标准修：
  ① **失败路径全有出口**：播放器 error 态（黑屏给提示+重试+返回）、查重/磁盘/目录
     失败不再永远卡"扫描中"、目录被删自动回退父目录、任务取消失败恢复按钮
  ② **取消任务不再死锁**（`_task_lock` 改 RLock + 落盘挪出锁区）
  ③ **worker 永不自杀**（整个循环包 try/except，任何异常只记日志不杀循环）
  ④ **数据不丢**：原子写改唯一临时名+fsync、`mutate_library()` 单一写入口消灭
     lost update、库损坏时**报错并备份**而不是静默清空
  ⑤ **子进程组**：取消任务杀整棵树（Windows 用 taskkill /T /F），不留 ffmpeg 孤儿
  ⑥ **全局异常兜底**：任何未捕获异常都变成可读 JSON，浏览器不再显示"连接重置"
  ⑦ **安全**：SSRF 拦截（拒绝内网/元数据地址）、yt-dlp 选项注入拦截、
     `safe_media_path("")` 拒绝（原来会放行下载目录本身）
  ⑧ **响应式**：320/390/1440px 三档零横向溢出（实测 scrollWidth == 视口宽）；
     顶栏与页签栏不再重叠；触摸目标命中区扩到 44px；`--tx3` 对比度升到 AA
  ⑨ **重下不丢文件**：先备份原文件，下载成功才替换，失败自动还原
- **v6.6 PWA / 自启 / iOS 兼容**（2026-10-21）：
  ① **PWA**（点图标即用）：`manifest.json` + `sw.js` + `icons/`（`tools/make-icons.mjs`
     纯 Node 手写 PNG 编码器生成，零依赖）→ 浏览器「添加到主屏幕」后当 App 用。
     service worker **只缓存外壳**，绝不碰 `/api/*`（媒体流和用户数据）。
  ② **开机自启 + 保活**：`boot.sh`（Termux:Boot 调）+ `start.sh`（前台服务 + while 循环崩溃自启
     + wake-lock + 常驻通知）；`install.sh` 检测到 Termux:Boot/Termux:Widget 才自动配置，
     **没装就只提示一句，不强装**（自启必须是可选的）。
  ③ **断点续传**：yt-dlp 加 `--continue --part --retries 10 --no-overwrites`。
  ④ **iOS 兼容**：`/api/ios` 把 MKV/WebM **remux 成 MP4**（`ffmpeg -c copy`，秒级无损）；
     只有 AV1（老 iOS 无硬解）才真转 H.264。分P 列表有按钮。
  ⑤ **局域网访问**：`bind` 配置（默认仍 127.0.0.1，改 0.0.0.0 会打醒目警告）+ `/api/lan`
     自动报出本机局域网地址（**手机上的 127.0.0.1 是手机自己**，必须用局域网 IP）。
- **v6.5 主题三态 + 合规重构**（2026-10-21）：
  ① **主题切换**：`auto`(跟随系统) / `light` / `dark` 三态按钮（顶栏），存 localStorage。
     暗色是 `:root` 默认值；亮色走 `@media (prefers-color-scheme: light)` 且**必须带
     `:not([data-theme="dark"])`** —— 否则手动选暗会被系统亮色覆盖。`:root[data-theme="light"]`
     单独一份亮色变量强制生效。已验四种组合（系统亮/暗 × 手动三态）。
  ② **去站点化重构**（见第 10 节，合规红线）
  ③ **改名 decache**：UI/安装目录/文件/文档全部换名，旧目录 `~/decache` 一次性迁移
  ④ **合规文件包**：LICENSE(MIT) / LEGAL.md / SECURITY.md / CONTRIBUTING.md /
     CODE_OF_CONDUCT.md / THIRD_PARTY_LICENSES.md / CI(4 道闸 + 站点字样 grep) / ISSUE+PR 模板
- **v6.0 功能**（同日）：① 网页设置入口（下载页底部，登录 cookie 免手改配置，`/api/config` 热生效）
  ② 启动后台自动扫描（幂等，不用手点） ③ you-get 引擎的「仅音频」修复（下载后 ffmpeg 流复制抽 .m4a）
  ④ 库文件原子写+损坏自愈+RLock（断电/并发不丢库） ⑤ 倍速/连播模式记忆 ⑥ 下载完成 toast
  ⑦ 桌面键盘快捷键（空格/←→/F/Esc） ⑧ 搜索防抖+支持搜UP主 ⑨ `ui-preview.mjs`：无 Python 环境的 UI 预览 mock。
- **v6.1 功能**（2026-10-20 晚）：① 进度条缩略图预览（`/api/thumbs` 懒生成 12 帧雪碧图，
  mtime 哈希缓存永不重抽；拖动/桌面 hover 显示）② 外挂字幕自动挂载（`/api/subs` 找同目录
  同名 .srt/.vtt，`/api/sub` 动态转 VTT，CC 按钮循环轨道）③ 音频模式（.m4a 等后缀自动
  封面+律动层）④ A-B 循环（A–B 按钮三态 + 金色标记线）⑤ Up Next 片尾卡（剩 20s 出现，
  可取消本集自动连播）⑥ Android 切后台回前黑屏修复（回前台重挂 video 元素强制重建渲染表面）。
- **v6.4 章节 + 播放列表资产**（2026-10-21）：
  ① **章节 markers**（被社区点名的第一缺失功能）：`/api/chapters` 用 ffprobe 读容器真章节；
     **没有真章节就按缩略图同样的 12 段等距生成伪章节**（图直接切雪碧图，边际成本≈0）；
     进度条上画章节分隔线，点章节跳转，章节列表带缩略图切片
  ② **手动章节标记**（`/api/marks`，存 library 不改原文件，可删）
  ③ **m3u 导入/导出**（`/api/queue/import` + `/api/playlist.m3u`）——队列变成可分享资产，
     导入时逐行校验路径白名单
  ④ **坏文件体检**（`/api/health`）：`ffmpeg -v error -f null -` 逐个验，返回丢失/损坏清单
- **v6.3 引擎换代 + 性能**（2026-10-21 调研落地）：
  ① **默认引擎换 yt-dlp**（you-get 最后 release 停在 2025-01-04，2026 年当主力是等死；
  yt-dlp 抽取器日更、跨平台有官方二进制/包、Termux 官方源直接 `pkg install yt-dlp`；
  you-get 保留兜底，`config.ini` 的 `engine` 随时切）② **下载即落元数据**：yt-dlp 的
  `--write-info-json` 产物被 `absorb_meta()` 吃掉 → UP主/简介/时长/封面地址直接进媒体库
  ③ **缩略图性能修正**：从「fps 滤镜全片解码」改为「12 次输入侧 seek + image2 序列 tile 拼图」
  ——1 小时视频在手机上从几十秒降到秒级 ④ **目录黑名单** `exclude_dirs`（扫描跳过）。
- **v6.2 功能**（2026-10-21）：① **文件夹浏览页签**（`/api/browse` 逐层下钻，入库也能直接播，
  路径白名单 `safe_dir_path` 组件级校验）② **彩色标签**（6 色 + 自定义色，存 `tags[]`，
  顶部筛选条，**服务端过滤** `/api/library?tag=`）③ **收藏 ★**（`fav` 字段，筛选条同款）④ **播放队列**
  （`playlist.json` 独立存储，`/api/queue` 支持 add/remove/up/down/move/clear，播放器内面板
  上移下移，☰ 按钮切换「队列模式」播放列表）⑤ **跨平台兼容层**（见第 10 节）。
- **自测**：`python3 selftest.py [端口]` —— 37 项断言全过（路径白名单/穿越防护/标签/收藏/队列 CRUD/
  原子写/srt→vtt/Range 206/越权 403+404），假 HOME 隔离，不碰用户数据，不写 config.ini。
- **规模边界（诚实）**：万级视频时 library.json 本身几 MB，首次加载全量传一次（移动端 1-2s），之后
  ETag 304 零传输；前端永远只渲染 60 卡。再往上才需要 sqlite——纯标准库架构里不值得提前上。

## 1. 文件清单（一个文件夹即全部）

| 文件 | 职责 | 改动风险 |
|---|---|---|
| `server.py` | 全部后端：HTTP 路由/任务队列/引擎调度/媒体库/封面/扫描/导出 | 核心，改后必须 py_compile |
| `index.html` | 全部前端：三页签 SPA/播放器/手势/i18n | 核心，改后必须 node --check |
| `config.ini` | 用户配置（首次启动自动生成） | 升级**绝不覆盖** |
| `library.json` | 媒体库（紧凑 JSON）：每片的 seq/folder/parts/cover_url | 用户数据 |
| `tasks.json` | 中断恢复（只存排队中/下载中） | 自动维护 |
| `covers/` | 封面 jpg（官方抓取 + ffmpeg 抽帧双保险） | 自动维护 |
| `cookies.txt` | 引擎用的 Netscape cookie（**域名按链接自动推断**，每次下载前重写） | 自动维护 |
| `start.sh` / `start.bat` | 启动脚本（开 wake-lock → 起服务 → 开浏览器） | 低 |
| `playlist.json` | 播放队列（独立存储，不塞 library.json） | 用户数据 |
| `thumbs/` | 缩略图雪碧图 + `frames/` 实时预览帧（都按 mtime+时间哈希缓存，永不重抽） | 自动维护 |
| `sync_install.mjs` | **重新生成 install.sh**（node 一键内嵌全部文件） | 改任何文件后跑 `node sync_install.mjs`，别再手工粘贴 |
| `selftest.py` | **自测脚本**（70 项断言，Python 跑，零污染） | 改后端后必跑 `python3 selftest.py` |
| `install.sh` | 一键安装/升级器（自包含 heredoc，内嵌全部文件） | 改任何文件后必须重新同步它 |
| `LICENSE` / `LEGAL.md` | MIT 许可 + 法律声明/边界/侵权举报流程 | 合规红线 |
| `SECURITY.md` / `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md` | 安全策略（含威胁模型）/ 贡献指南（含拒绝 PR 清单）/ 行为准则 | 社区文件 |
| `THIRD_PARTY_LICENSES.md` | 外部依赖归属（yt-dlp / ffmpeg 等，均不打包） | 合规红线 |
| `.github/` | CI（py_compile + node --check + selftest + install.sh 同步校验 + **站点字样 grep**）、ISSUE/PR 模板 | 自动 |

## 2. config.ini 全键

```ini
[panel]
port = 8765            # 面板端口（只绑 127.0.0.1）
engine = yt-dlp        # 下载引擎：yt-dlp(默认) | you-get | yutto
cookie =               # 可选：站点登录 cookie "KEY=VALUE; K2=V2"（域名按链接推断）
delay = 4              # 分P之间间隔秒数（防限速，可打断）
download_dir = ~/storage/downloads/decache    # 下载落点（机器相关）
scan_dirs = ~/storage/downloads,~/storage/Movies   # 全盘扫描目录（逗号分隔）
hang_timeout = 180     # 引擎断流多少秒判卡死强杀（长视频/慢网调大）
exclude_dirs =         # 扫描排除（逗号分隔的路径片段，命中即跳过）
```

引擎可选：`yt-dlp`（默认，2026 唯一日更的抽取器，跨平台有官方包）｜`you-get`（上游停更，兜底）｜`yutto`（站点专精，Termux 上 Rust 扩展编译易失败）。

新增配置键：`DEFAULTS` 加默认值 → `_CONF.get(...)` 读取，旧 config.ini 自动兼容（configparser 缺键不炸）。

## 3. HTTP API 参考（127.0.0.1:PORT）

| 端点 | 方法 | 说明 |
|---|---|---|
| `/` | GET | 前端页面（Cache-Control: no-store） |
| `/api/version` | GET | `{"v": "5.3"}` —— 前端顶栏显示，**排查新旧的第一证据** |
| `/api/info?url=` | GET | 解析链接（分享文案通吃）→ 标题/UP主/封面/分P 列表。**委托 `yt-dlp --dump-single-json`**，本项目不直连任何站点接口 |
| `/api/download` | POST | `{bvid,title,cover,parts[],part_names{},audio_only}` → 入队 |
| `/api/tasks` | GET | 最近 30 条；排队中显示"第N位"；已剔除 proc/_before |
| `/api/cancel` | POST | `{id}` —— 排队/下载中可取消（4s 防限速等待每 0.25s 检查，秒停） |
| `/api/library` | GET | 支持 `If-None-Match`/ETag → 无变化回 **304 空响应**（3000 视频的关键） |
| `/api/cover/<bvid>` | GET | 封面 jpg；缺失时懒加载：官方 URL →（失败）→ `snapshot_thumb()` ffmpeg 抽帧 → SVG 占位（带 X-Cover-Error 头） |
| `/api/stream?rel=` | GET | 视频流，**支持 HTTP Range**（206，拖拽进度的根基），512KB 分块 |
| `/api/scan` | GET | 全盘扫描视频文件按文件夹成"部"入库（幂等），EXT_ 前缀 |
| `/api/export` | GET | tar.gz 打包 config/library/covers/程序 → ~/storage/downloads/ |
| `/api/delete` | POST | `{bvid}` 删片+联动取消其活动任务；`{rel}` 删单文件 |
| `/api/open` | GET | 外部打开（跨平台：os.startfile / open / xdg-open / termux-open） |
| `/api/browse?path=` | GET | 文件夹浏览：子目录+视频文件（不入库也能播）；越权 403 |
| `/api/tag` | POST | `{bvid,tag}` 切换彩色标签（存 `tags[]`） |
| `/api/fav` | POST | `{bvid}` 切换收藏 |
| `/api/tags` | GET | 标签计数 + 收藏数（前端筛选条） |
| `/api/queue` | GET/POST | 播放队列；POST `{op:add/remove/up/down/move/clear/set, i, item}` |
| `/api/diagnostics` | GET | 平台/ffmpeg 路径/Python 版本/兼容提示 |
| `/api/thumbs?rel=&dur=` | GET | 进度条缩略图雪碧图（12 帧，mtime 哈希缓存；章节切片也用它） |
| `/api/frame?rel=&t=&w=` | GET | **实时预览帧**：指定秒的单帧 JPEG（拖进度条的实时画面，mtime+秒 哈希缓存，上限 3000 张） |
| `/api/chapters?rel=&dur=` | GET | 章节：容器真章节，无则 12 段等距伪章节（`real` 标记真假） |
| `/api/marks` | POST | 手动章节标记（`{bvid,rel,t,title}` / `op=del`），存 library 不改原文件 |
| `/api/queue/import` | POST | m3u 导入 → 队列（逐行校验路径白名单） |
| `/api/playlist.m3u` | GET | 队列导出 m3u（#EXTM3U + #EXTINF） |
| `/api/health?bvid=` | GET | 坏文件体检：ffmpeg 逐个验，返���丢失/损坏清单 |
| `/api/subs?rel=` | GET | 同目录同名外挂字幕发现（.srt/.vtt） |
| `/api/sub?rel=` | GET | 字幕内容（srt 动态转 VTT） |

## 4. 数据格式要点

**library.json**：`{bvid: {title, owner, folder, cover, cover_url, seq, parts: {"1": {name, file, size}}}}`
- `folder` 相对 download_dir；外部扫描目录存绝对路径（Path 拼接语义天然兼容）
- `seq` 递增下载序号（"下载顺序"排序的根基，入库时 `next_seq()` 分配）
- 分P→文件归因：下载前后 `mp4s_of()` 集合差 + mtime 最新者

**tasks.json**：只存未完成任务的 `{id,bvid,title,parts,part_names,cover,audio_only,failed,created}`。完成/取消**不持久化**（重启即清历史，杜绝"完成任务复活"）。

## 5. 关键设计决策（勿轻动，动前读注释）

1. **单文件夹便携**（Homey/Plex 范式）：一切状态在同一个文件夹内，换机=拷文件夹。
2. **纯标准库**：跨平台三件套（sh/start.bat/python3）跑同一份文件；无依赖地狱。
3. **引擎适配器**：`_cmd(url, audio_only, folder)` 是引擎唯一接触点——换引擎只改它。
4. **单线程下载队列**：故意为之（防限速），不是缺陷；排队名次已可视化。
5. **心跳强杀**：`select` + `os.read` 字节级监听——**有字节流动就不计时**，只有彻底断流才累计 hang_timeout。用行缓冲 readline 会死于 you-get 的 \r 进度。
6. **封面双保险**：网络官方图 → ffmpeg 抽帧（seek 3s→0.5s→0 回退，避开头黑帧）。离线必有图。
7. **视图缓存**：library.json 的 `mtime_ns-size` 作 ETag，15s TTL 兜底；`save_library`/删除时 `_bump_view()`。
8. **乐观更新**：取消/删除先动 UI 再调 API（见 index.html 注释"乐观"）。
9. **进度记忆**：`localStorage["bili_pos_"+rel]`，>5s 且 <时长-8s 才恢复。
10. **播放列表=全库扁平化** `buildFlat()`：循环/随机/上下P 跨视频，排序跟随媒体库当前规则。
11. **安全**：只绑 127.0.0.1；`safe_media_path()` 白名单（download_dir + scan_dirs）防目录穿越。

## 6. 血泪史（已修复，防再犯）

1. **JS 顶层重复声明**（fmtT/closePlayer 两次 const）→ 整页 JS 暴毙、按钮全死。`node --check` + 顶层声明扫描是**每次改前端的必做闸**。
2. **`$` 在使用点之后才 `const` 定义**（TDZ）→ 运行时 ReferenceError，语法检查**看不见**。工具函数定义必须在脚本最顶部。
3. `urllib.parse.parse_qs` 返回**列表**：`q.get("rel","")` 必须写 `q.get("rel",[""])[0]`，否则 Path/列表 TypeError。
4. **Kiwi 浏览器缓存阴魂不散**：HTML 已加 no-store；封面 URL 带 `?t=mtime`；用户端必须**杀进程重开**（关标签页不够）。
5. **412/风控**：部分站点强制登录 Cookie → `cookie` 配置项必填；症状=全部下载失败。
6. **yutto 2.3.1 × Python 3.14**：`_Exc_BaseException` 符号缺失 → 默认引擎 you-get。
7. **Termux ffmpeg 装不上**（libc++ 符号错位）→ 先 `pkg upgrade` 再装。
8. **多行粘贴冲掉 pacman/paru 的 Y/n 提示** → 交互命令单独发，或 --noconfirm。
9. **pip 在 Android 无预编译 wheel**（maturin/Rust）→ 纯 Python 备胎 you-get 的价值。
10. **服务器≠浏览器**：关浏览器任务照跑（设计特性）；停服务=pkill 或任务页 ✕。
11. **safe_media_path 的 startswith 漏洞**（v6 修）：字符串前缀匹配会放行 `/downloads-evil` 这类同前缀兄弟目录 → 必须用 `Path.is_relative_to` 组件级比较。
12. **install.sh 手工同步屎山**（v6 治）：Kimi 时代 start.bat heredoc 被重复追加 6 遍，后段覆盖前段、中间全是尸体 → 已改由 `sync_install.mjs` 生成，禁止手工编辑 install.sh。
13. **前端 XSS**（v6 修）：innerHTML 拼接标题/文件名从未转义，标题可注入脚本 → 全部插值点走 `esc()`；任务重试按钮原 `data-retry='${JSON}'` 属性内嵌 JSON 也会被引号击穿，已改存 id 回查数组。
14. **封面 Referer 用错域名**（v6.9 修）：防盗链认的是**来源页**域名，代码里写成了图片自己的
    域名 → 官方封面一律 403 → 用户看到的是抽帧图。**通用解**：Referer 用「下载时那个网页地址」
    的域名（库里存 `source_url`），不是硬编码任何站点。
15. **抽帧图和官方封面同名**（v6.9 修）：老版 `{bvid}.jpg` 谁先写谁赢，抽帧图一旦落地，
    官方封面**永远**下不下来。现在官方 = `{bvid}.jpg`，抽帧 = `{bvid}_s.jpg`，互不打架。
16. **TDZ：`const` 声明前用它 = 整页暴毙**（v6.9 修）：`const HAS_PIP` 写在
    `const v` 前面三行。浏览器**支持画中画就短路没事**（`||` 短路），不支持的设备
    直接 ReferenceError → 页面全白。**声明顺序 = 依赖顺序**。
17. **模板串漏进纯 HTML**（v6.9 修）：`<script>` 之外的 HTML 里写 `${t('x')}` → 界面
    显示字面量。纯 HTML 要用 `data-i18n="x"`。
19. **后台扫描 = lost update**（v6.10 修）：`scan_videos()` 以前 load → 全盘 rglob →
    save，手机上扫描几十秒，期间用户打的标签/收藏**全被覆盖**。凡是"读-算-写"里
    **算的过程很慢**的，都不能直接 load→save，必须走 `mutate_library()`。
24. **测试退出码必须看**（v6.14 修）：chaos_test 一直在最后一行崩（`old_engine` 未定义），
    但我只数 PASS 没看退出码 → 一直以为它是绿的。**验收 = 退出码 0 + "全部通过"那行**。
25. **`rmtree` 之前必须校验路径**（v6.14 修）：`Path(base) / abs_path` 里绝对路径会**顶掉** base；
    扫描导入的外部目录就是绝对路径 → 一次删除能把用户的整个目录树端掉。
26. **别把文件"改名搬走"当备份**（v6.14 修）：搬走了 → 下次读当空库 → 一次写盘就把空库固化，
    用户的标签/收藏永久消失。备份要**复制**，不是搬走。
23. **Windows 上 `select.select()` 不能用在管道上**（v6.13 修）：只支持 socket,
    管道直接抛 OSError 10038。要读子进程输出就**上线程 + 队列**, 别赌 select。
24. **子进程输出解码要用 errors="replace"**（v6.13 修）：`text=True` 按系统编码解码,
    碰上非 UTF-8 字节(中文标题)直接抛 UnicodeDecodeError → 读取线程死掉 →
    **错误信息永远拿不到**。固定 `encoding="utf-8", errors="replace"`。
25. **错误信息别从头截**（v6.13 修）：`reason[:400]` 从头截, 而错误行在最后面 →
    真因被截掉, 用户只看到无害的开头。掐头留尾。
22. **`height<=N` 对竖屏视频是错的**（v6.12 修）：清晰度上限必须按**短边**算
    （`height<=N` **或** `width<=N`），否则竖屏一个都匹配不上。写过滤器前先问
    "这个站的竖屏视频长宽比是什么样"。
21. **rAF 不保证触发**（v6.11 修）：`requestAnimationFrame` 在页面刚可见时**可能根本不跑**
    （浏览器还没开始渲染）→ 挂在 rAF 里的"修复代码"等于没写。**修 UI 可见性/渲染问题
    一律用 setTimeout**，别赌 rAF。
20. **touchstart 显示 + click 再藏**（v6.10 修）：控制条"只闪 0.28 秒"的真凶。
    单击路径上**只能有一个地方决定显隐**。
18. **`$('x').onclick` 指向已删元素 = 整个 JS 停摆**（v6.9 修）：一个 null 的 onclick
    抛错，后面的代码**全不执行**，表现是「页面什么都不渲染」而不是「那个按钮坏了」。
    **每次改完 HTML 必跑 id 悬空检查**（扫 `$('x')` 引用的 id 是否还在 HTML 里）。

## 7. 测试 SOP

```bash
# 1) 语法闸
python3 -m py_compile server.py selftest.py chaos_test.py fake_yt_dlp_test.py
sed -n '/<script>/,/<\/script>/p' index.html | sed '1d;$d' > /tmp/check.js
node --check /tmp/check.js

# 2) 四套自动化测试(全离线, 不碰用户数据)
python3 selftest.py          # 190 项: 端点/白名单/全局存在性/队列/路径/UA/封面/批量/清晰度/标签/报错翻译/仅音频/数据安全
python3 chaos_test.py        # 71 项: 脏数据/并发/死锁/穿越/注入/SSRF/20端点不5xx(以前最后一行就崩, 没看退出码)
python3 fake_yt_dlp_test.py  # 17 项: 假 yt-dlp 真跑解析链路/缓存/null不崩
```

**规则**：改任何代码 → 三套测试全绿才能提交。

**改前端(index.html)额外必跑两道闸**（`node --check` 只查语法，下面这些它一个都查不出来）：

```bash
node frontcheck.mjs   # 五道静态闸: id 悬空 / 未声明标识符 / 模板串泄漏 / 语法 / 缺图标
node smoke.mjs        # 加载期冒烟: 用 DOM 桩真跑一遍脚本, 谁抛错报谁
```

- **闸1 id 悬空**：`$('x')` 引用的 id 在 HTML 里没了 → 抛 null 错 → **后面所有代码都不执行**，
  表现是「页面什么都不渲染」，不是「那个按钮坏了」。
- **闸2 未声明标识符**：少写一行 `const all = ...` → ReferenceError → 整页 JS 暴毙。
- **闸3 模板串泄漏**：纯 HTML 区（`<script>` 之前）出现 `${...}` → 界面上直接显示
  `${t('x')}` 字面量（按钮文字变成乱码，但按钮还能点 → 更难发现）。
- **闸4 语法**：等价于 `node --check`。

**为什么要有这两道闸**：2026-10-21 一天之内，前端连续炸了三次 ——
① `$('pQMode')` 指向已删按钮（整页停摆）；② `renderChapList` 少写一行 `const all`
（整页停摆）；③ `const HAS_PIP` 在 `const v` **前面三行**用了 `v`（TDZ，
**浏览器不支持画中画就整页暴毙**，支持的话短路没事 —— 这种雷最难查）。
```
另外 `smoke.mjs` 是**项目自带的**（纯 Node，无依赖），不用 playwright 也能跑。测试发现的问题**当场修**，不许留"下次再说"。

**别再犯的错（2026-10-21 血泪）**：
- 用编辑工具改代码后**必须 grep 验证真的写进去了** —— 我有过三次"以为改了其实没改"
  （`_info_cache` 声明、解析缓存逻辑、i18n 重复行），其中一次让用户的手机直接解析失败
- 改完立刻跑 `py_compile` + `node --check`，别靠肉眼
- 换行符会混（CRLF/LF），编辑工具匹配不上就换 node 脚本按行改
- `worker` 里的循环体曾被误拆成 `_worker_once()` 却留着 `continue` → 整个下载循环语法坏掉

## 8. 常见维护任务

- **登录 cookie 过期**（症状：解析正常、下载全败）→ 让用户重取填 config.ini 的 `cookie`。
- **站点接口变更** → 那是**外部引擎**的事（yt-dlp）；本项目只需升级引擎版本。
- **换/加引擎** → `DEFAULTS["engine"]` + `_cmd()` 加分支；保持 `?p=N` 语义与退出码约定。
- **用户反馈"点了没反应"** → 先看顶栏版本号对不对，再按第 6 节排查。

## 9. 跨平台兼容层（2026-10-21 调研落地 · 别删）

调研结论：这项目要跑在 Windows/macOS/Linux/**Android Termux** 上，下列坑是实测/官方 issue 确认的。

| 坑 | 症状 | 本项目的处理 |
|---|---|---|
| `os.replace` 在 Windows 目标被占用时 PermissionError(WinError 5) | 浏览器/杀软开着 library.json 就写不进去 | `atomic_write()` 指数退避重试 6 次 |
| ffmpeg 输出含非 ASCII 字节 | `text=True` 解码炸 UnicodeDecodeError | `run_ffmpeg()` 统一 `errors="replace"` + `-y -nostdin -loglevel error` |
| Windows 每条命令闪黑框 | — | `CREATE_NO_WINDOW` |
| ffmpeg 不在 PATH（Windows 最常见） | 抽帧/抽音轨全废 | `ffmpeg_path()` 扫 PATH + WinGet 常见目录 |
| Termux **没有 /bin/sh** | `shell=True` 必 FileNotFoundError | 全项目禁用 shell=True，一律传 list |
| Termux **multiprocessing 不可用**（无 sem_open） | 起不来 | 只用 threading，任务并发用线程 |
| Termux Python 随 `pkg upgrade` 滚动（3.13→3.14） | pip 装的包全废、yutto(pydantic-core=Rust) 编译失败 | 默认引擎保持 you-get；启动自检打印提示 |
| Android 12+ Phantom Process Killer | ffmpeg 子进程被 SIGKILL 打断 | 启动自检提示授予 wakelock |
| Windows `allow_reuse_address=1` | 两个实例同时跑、请求随机落到先绑的 | Windows 下关掉该标志 |
| iOS Safari 要 206 + 强 ETag | 弱 ETag 直接黑屏 | `/api/stream` 自己实现 206，**不发 ETag** |
| iOS Safari 不吃 MKV/AVI/VP9/AV1 | 播不了 | 已知限制（本项目不转码，见第 9 节） |
| Android WebView 无 PiP API | 按钮点了直接抛错 | `HAS_PIP` feature-detect 后才显示/响应 |
| 老 WebView 无 color-mix/aspect-ratio/backdrop-filter | UI 塌 | `@supports not (...)` 降级层 + 老式 background 兜底 |
| Safari 动态 track 不加载 | 字幕没反应 | track 插入后 `mode='hidden'` + `video.load()` |
| macOS 文件名 NFD vs NFC | 列表有、点不开 | `nfc()` 归一化 |
| `Path.is_relative_to` 需 3.9+ | 3.8 报 AttributeError | 启动自检提示最低 3.9 |

**新增端点**：`/api/diagnostics`（平台/ffmpeg 路径/版本/提示），前端设置页可见。

## 10. 去站点化（2026-10-21 · 合规红线，勿回退）

**背景**：2025-2026 年国内内容平台批量向开源第三方工具发律师函，被点名指控的行为
高度一致——① 逆向/改写平台接口与签名 ② Hook 客户端 ③ 系统性收集并公开接口文档与
参数结构 ④ 抓取付费/会员/限区内容 ⑤ 采集弹幕字幕。
被判死的项目（第三方客户端、API 文档仓库、番剧区解锁模块、下载器）**全部**栽在这几条上。

**本项目的立场**：只做「本地媒体库 + 播放器」，把获取能力完全委托给**外部通用下载引擎**，
自身不持有任何站点知识。已被点名的四类行为，一条都不做。

**具体改动（回退即违规）**：

| 原实现（已删） | 现实现 | 为什么 |
|---|---|---|
| 直连某站 view 接口取标题/封面/分P | `yt-dlp --dump-single-json --flat-playlist` | 站点专属接口适配 = 律师函逐字指控范围 |
| BV 号正则提 ID + 跟 302 短链 | `extract_url()` 只找第一个 http 链接，解析交给 yt-dlp | ID 格式是站点知识；短链跳转 yt-dlp 自己会跟 |
| 下载 URL 硬编码某站地址 | 解析时拿每个分P 的真实 URL，存进任务的 `part_urls` | 通用且分P 精确 |
| cookie 写死某站域名 + 固定键名 | `cookie` 配置项存 `KEY=VALUE; ...`，**域名从链接自动推断** | 用户自己填的凭据，代码不认站点 |
| 封面请求写死 Referer 域名 | Referer 按封面 URL 的来源域名自动带 | 通用 |
| 封面端点校验 `BV[0-9A-Za-z]+` | 校验 `[A-Za-z0-9_.\-]{1,120}` | 同上 |
| 任务状态用中文字符串 | 内部仍用中文标识，对外给 `status_code` 英文码 | 多语言与前端比较都走英文码 |
| 进度行中文 | 进度行改英文（技术日志性质，中英用户都看得懂） | 英文模式零中文残留 |

**CI 会拦**：`.github/workflows/ci.yml` 里有一条 grep，源码里再出现站点名/接口域名/
站点 ID 格式就红。

**README 首屏不写"支持 XX 平台"清单** —— 那种清单就是维权的关键词索引。

**永远不要加的功能**（写进 `CONTRIBUTING.md` 的拒绝 PR 清单）：站点解析器、签名逆向、
协议改写、客户端 Hook、接口文档、付费/会员/限区内容获取、直播录制、DRM 绕过、
多用户/公开库/在线转码、遥测、打包第三方二进制。

## 11. 已知限制（诚实清单）

- 网页后台播放只能走 PiP；系统音量/亮度不可控（Web 权限边界，已用软件亮度补偿）。
- you-get 分P 需逐 P 调用（`?p=N`），无整包接口。
- 第三方下载生态随时可能死于平台接口变更/合规压力——**引擎可替换架构就是为此生的**。
- 浏览器需 Chromium 80+（可选链 `?.`）；Kiwi 太旧建议用户换 Via。
- 播放 4K/高码率取决于片源与浏览器解码，面板不做转码。

## 12. 部署机器档案

Android 手机（Termux + Termux:API + Termux:Widget，建议 F-Droid 版）+ Windows PC 双端使用；
手机浏览器建议 Chromium 内核 80+；下载目录 `~/storage/downloads/decache`；Windows 上 start.bat 直接跑。

*本文件随版本更新。改代码不改本文档 = 失职。*

## 13. v6.18 升级记录 (2026-10-24)

### UI v7→v8 · 六主题换肤系统(mono/geist/catppuccin/synthwave/retro/pipboy)
- `<html data-ui="...">` 换肤, 明暗仍归 `data-theme` 三态, 主题自带亮/暗双套色板
- 内置: mono(默认, 原样)/ refactor(Refactoring UI) / retro(Win95) / 8bit(NES) / pipboy(辐射终端)
- 新增令牌 `--acc --acc-tx --ring --sh --font`, 全部注入在 index.html 尾部 "v7 主题包" 段
- 动效只动 transform/opacity, `prefers-reduced-motion: reduce` 时全局关停
- 播放器进度条吃 `--pink`, 字幕颜色从写死 `#fff` 改 `var(--tx)`
- 设置页新增"界面风格" chips, localStorage `take_ui`; JS 仅新增 `applyUiTheme()` ~20 行
- 预览: preview.html 免启动直接看 5 主题 × 3 明暗

### 修复
- **存储型 XSS**: `/api/tag` 零字符校验 + 前端标签裸插 innerHTML → 服务端拒 `<>"'&`, 前端 `esc()` 双层兜底
- **HTTP/1.0 无 keep-alive**: handler 加 `protocol_version = "HTTP/1.1"`, 全部 13 个响应出口核对过 Content-Length (304 无体符合 RFC), selftest 全过 + 活体复用验证通过
- 版本号 → 6.18

### 验证 SOP 结果: selftest 全部通过 ✅ / frontcheck 七闸全过 ✅ / 活体 keep-alive + XSS 拦截 ✅

## 14. v8 主题系统 (2026-10-24)

基于 2026 设计趋势调研(玻璃拟态2.0/Catppuccin 人气配色/StyleShift Synthwave 规范/Vercel Geist 纪律)重做的换肤层:
- refactor → geist(真 Vercel 纪律: --edge shadow-as-border/6-8-12 圆角/宽字距标签), 8bit 退役 → synthwave(深紫黑底+品红/青双霓虹+落日网格场景层)
- 新增 catppuccin(Mocha/Latte 官方色板, 胶囊 chips)
- 每主题补"组件语言", synthwave 独有 body::before 场景层(纯渐变合成层, 不随滚动重绘, 亮色自动关闭)
- 发光只给主元素(StyleShift 教训: 到处发光=廉价)
- v7 存档迁移: take_ui refactor→geist, 8bit→synthwave
- mono/retro/pipboy 保留, 全部六主题 × 明暗仍归 data-theme 三态
- 验证: frontcheck 全过 / node --check 过 / 13 张 Playwright 截图人工复核

——以上 v6.18/v8 记录的是换肤层落地; v9–v12.1 演进见第 15–17 节。

## 15. v9–v12 着色器特效 (WebGL 后处理)

设置页「画质特效」下拉, localStorage 键 `take_fx`, 4 档:
- **CRT 电视**: 扫描线+色差+失真+颗粒+辉光+微曲率+荫罩+信号行微闪+滚动亮带+亮度呼吸
- **VHS 录像**: 弯波+细撕裂+色度涂抹+跟踪磁条+磁头噪带+偏色
- **胶片颗粒**: 片门游移+24Hz 闪烁+连续颗粒
- **霓虹辉光**: 高光涨落+彩虹呼吸+轻扫描

硬约束(改前必读):
- 单 pass 单着色器 12 uniform; 全部连续时间函数无跳变
- 性能: DPR≤1.5(写 `window.devicePixelRatio`), 暂停/后台/关播放器即停渲染, WebGL 失败自动回退 off
- 存档兼容: 旧 `tube` 档→`crt` 且落盘; 无效值白名单回退 `off`
- `fxFit()`: 画布按 object-fit:contain 算法对齐视频, 防比例拉伸
- 代码位置: <script> 内 `FX_PRESETS` + fxEnsure/fxStart/fxFit/fxLoop 函数组
- 开发期预设表演示页 fx_demo.html 不在发行包内, 改它时小心大括号被替换吃掉, 改完 `node --check`

## 16. v10–v11 播放器改造

- 控制条 → 悬浮玻璃坞(毛玻璃圆角), v11 起进度条/旋钮/按钮/面板逐主题定制(六主题各一套)
- 单击切换控件: 藏着→亮 6 秒, 亮着→秒收; `barPre` 手势前状态捕获防闪一瞬
- 播放列表折叠分组: 连续同 bvid 合并为一组, 点组头展开/收回, 当前集自动展开
  (renderList/plrowHtml + .plgrp/.plparts CSS)
- 字幕颜色固定白字/黑底, 与主题无关(applySubStyle), 勿接主题令牌
- 代码位置: hideCtrl/poke + barPre 捕获; 换肤 JS「UI 主题包」段 applyUiTheme

## 17. v12.1 GL 上下文回收修复

安卓切后台系统会回收 WebGL context, 切回花屏/变卡。
fxEnsure() 已挂 `webglcontextlost`(preventDefault+fxStop) / `webglcontextrestored`
(置空 fxPr/fxTex/fxU → fxEnsure 重建程序 → fxStart) 监听, 并配合 visibilitychange 先停再启。
**勿删这两个监听。**

## 18. v6.19 待办收尾 (2026-10-24)

- **待办#4 已结**: 删除 visibilitychange 里"切后台自动 requestPictureInPicture"块;
  手动 PiP 按钮(pPip)与 HAS_PIP 能力检测保留(按钮显隐判定用)
- 文档补齐: 本 HANDOVER 新增第 15–17 节, 尾部章节重编号(12 部署档案 / 13 v6.18 / 14 v8)
- 包卫生: 清除 .frontcheck.tmp.js、cookies/*.tmp、HANDOVER.md.bak 入包

## 19. v6.20 播放器整改 (2026-10-24, 真机反馈驱动)

- **着色器丝滑化**: fs 里 4 处 `floor(tm*24/30/17)` 低频整屏跳变全改连续函数(多频 sin, 行号只做相位);
  "顿顿的"根因就是它, 不是性能问题
- **CRT 褪色+色偏**: 新 uniform `fd` — 降饱和+黑位轻提+暖绿偏色; crt 档 `fade:.3`;
  声明/上传/预设四处都要接, 漏一处就是静默无效
- **编译/链接检查**: fxCompile/fxEnsure 现在检查 COMPILE_STATUS/LINK_STATUS, 失败 console.warn + 回退 off;
  之前编译失败会静默直出原片 = "有的档有效果有的没有"的隐藏根因
- **切后台健壮性**: fxStart/fxLoop 入口查 `isContextLost()`, 丢着不硬重建, 等 webglcontextrestored 拉起;
  lost 期间不再空转画黑帧
- **章节功能整个删除**: pChap 按钮/chapPanel/chapMarks 分段条/loadChapters/renderChapters/renderChapList
  及全部调用点已清; server 端 /api/chapters 和 /api/marks 端点还在(前端不再调用), 要彻底清再删 server.py
- **播放器头部主题化**: 根因 = #pmodal 硬重置了一套 mono 局部变量把主题色板全盖了;
  现在五主题各一行 `#pmodal` 变量映射(恒暗色板) + #phead 背景逐主题渐变 + .ttl/.icbtn 接 var(--tx)
- **血泪新增**: ① cut_block 删函数后检查残留 `);` `;` 孤儿行 ② 闸2 不追踪多参数箭头函数参数,
  删函数时若带走了平铺声明表里的名字, 别处的合法参数引用会连坐误报(本次 gi 案: 没用的参数直接删)

## 20. v14 · 主题性格化 (2026-10-24)

每个主题有自己的视觉语言, 不再只是换色/换字:
- **retro 像素庄园**: 星露谷(暖木纸感卡+◆符) × MC(物品栏格硬边内阴影) × WinXP(凸起按钮, 已有);
  新增像素云+草地天际线场景层; logo 用 Press Start 2P(仅标题, 正文保可读); tabbar 小像素大写+下划线选中
- **pipboy 终端大融合**: 辐射绿基调 + TUI 语汇 — 边框卡/ $ 提示符/ [] 选中/tab [按钮] 括号/打字机 logo(steps 动画);
  扫描线/辉光/▮光标保留
- **synthwave 霓虹之夜**: logo 铬字渐变(Orbitron+background-clip:text, 原 text-shadow 须置 none 否则透明字出影框);
  .page::before 星闪层(z-index:-1 在 body::before 之后→盖场景层底下内容上面); light 模式隐藏(同落日规则)
- **catppuccin 奶油玻璃**: 毛玻璃卡(backdrop-filter blur 12px)+粉彩渐变按钮+胶囊 chip
- **geist 工程网格**: 蓝图网格纹理(.page::before+mask 渐隐)+下划线选中+卡片细边框轻投影
- 字体: Google Fonts link(offline 时 display=swap 秒回退系统字体, 不阻塞渲染)
- 新动画全部包进 prefers-reduced-motion
- 血泪: content 动画 steps() 对 logo 长度不敏感, 宁多勿少; background-clip:text 与 text-shadow 互斥

## 21. v15 · 真机二轮反馈修复 (2026-10-24)

- **纯音频黑屏**: `#pstage.audio` 时 video 被 CSS 隐藏, 但 fxCv 特效画布没禁用 → 对着无帧纹理画全黑。
  修: CSS `#pstage.audio #fxCv{display:none!important}` + fxStart 拦截 audio 类。音频视频别再开特效
- **面板主题化漏网**: `.qh`(×3) `.qitem` 的 color 和面板分隔线是 v6 时代硬编码白色系, 不换变量主题进不来。
  已全部换 var(--tx)/var(--line)/var(--tx2)
- **播放器按钮全白**: `#pmodal` 的 `color:#FAFAFA` 写死属性盖掉了 v13 的变量映射(映射只改了--tx变量,
  子元素继承的是color属性)。改 `color:var(--tx)`, mono 下 --tx 同为 #FAFAFA 视觉零回归
- **窄屏控制条拥挤**: pctrl/phead 按钮 ≤560px 缩到 32px、≤380px 缩到 28px, pipboy 按钮括号窄屏收起,
  最大化按钮不再被挤出屏
- **logo De cache 大空隙**: v14 打字机 width 动画把 .logo 拉成父容器全宽, flex 下文字被拉散。
  改 clip-path:inset 动画, 零布局副作用
- **CRT 像素微发光**: 新 uniform `pg` — 4邻域采样溢出 bloom, crt 档 `pglow:.5`
- **i18n 混杂根因**: 词典 203 键中英齐全; 混杂是动态面板(凭据/队列/SOP)初始化时插文本,
  切语言后不重渲。langBtn 加 location.reload() 根治
- **血泪**: ① 改 --xxx 变量后检查同规则里有没有写死的 color/background 属性盖它 ② width 动画做打字机
  会撑满父宽, 用 clip-path ③ CSS 硬编码色审计清单: .qh/.qitem/#pmodal/phead——以后新增面板组件必须用变量

## 22. v15.2 · 亮度手感 + 文件夹升级 (2026-10-24)

- **亮度锁 100%**: applyB 上限 1.6→1.0 只调暗; 范围跨度 1.2→0.6 同滑程手感细一倍(dy/300);
  5% 步进量化(每 20px 一档, round(b*20)/20); 100% 吸附区放宽 ±2.5%; 存量 take_bright>1 载入即拉回;
  吸附成功显示 "☀ 100% · 原色"
- **文件夹五件套**: ① 人性化大小 sizeText(436KB/1.2MB/3.4GB) ② agoText 修改时间(3天前,
  server 的 mtime 早就在响应里, 前端一直没接) ③ 面包屑全路径分段可点(原代码只有 根/..当前 三层,
  中间全断; 循环写法避闸2多参箭头连坐) ④ take_browse 存 sessionStorage, 切走再回原地
  ⑤ foldFilter 名称过滤框(事件委托绑定一次, data-i18n-ph 已有机制零新增)
- **i18n 补 7 词条**: bFilter/agoNow/agoS/agoM/agoH/agoD/agoW (zh/en 各一套, %d 模板)
- **血泪**: ① 闸2 不追踪多参数箭头函数参数 — 模板串里用参数就报未声明, 写法首选用行内
  let/const 循环, 或删无用参数 ② server.py 的 VERSION 常量要和 UI 版本一起走, 不然用户看版本号
  以为没装上(本次 6.18→15.1 就是祖传字符串没同步)

## 23. v15.3 · 全面自审 + 下载历史 (2026-10-24)

- **下载历史**: parse 成功记 localStorage take_hist(去重, 最多 8 条); page-dl 输入框下 chips 行,
  点击回填+自动重新解析; data-hu 属性 + 事件委托绑定一次; 初始化随 applyLang 渲染
- **server 死端点删除**: /api/chapters /api/marks(章节功能 v6.20 已删前端) /api/open(前端从没调用)。
  删法: 从 `if u.path == "..."` 切到下一个 `if u.path ==` 前; 删完必须 python3 -m py_compile
- **自审确认健康**: 手势三模式(进度/音量/亮度)逻辑完好; 倍速早就有 localStorage 记忆;
  i18n 203 键对齐; /api/stream|sub|thumb|library|frame 均被前端正常使用(拼参形式)
- **待办(不紧急)**: 词典 ~80 死词条(chAdd 等章节遗留)、chapPanel/chapMarks 死 CSS 规则——纯脏无害;
  任务页可加批量取消/自动归档; 媒体库可加排序选择器
- **血泪**: rep 用 `function xxx() {` 当锚点时, 先确认原文有没有 `async ` 前缀 — 被顶掉的话
  async 会 orphaned 粘给下一个函数, 原函数丢 async 里面 await 全炸(本次事故实录);
  以后锚点统一用 `async function xxx` 或带前文上下文

## 24. v16 · 微交互炫酷包 (2026-10-24)

2026 移动端 UI 趋势落地: 即时反馈/spring 按压/分层入场, 全部 transform+opacity (GPU 合成, 不重排):
- **按压反馈**: .btn/.icbtn/.chip/.tabbar button :active scale(.93) (tabbar .9), 橡皮筋曲线 cubic-bezier(.34,1.56,.64,1)
- **页面切换升级**: .page 由淡入改 淡入+上浮 pageIn .32s, 覆盖旧 fadein(旧 keyframes 留无害)
- **聚焦光环**: input/textarea/select :focus 主题色 3px 光环(color-mix 22%), 高级感主力
- **进度条流光**: #pfill::after 无限扫光 — 只挂播放器进度条(稳定DOM), 任务列表高频重渲绝不挂
- **stagger 入场**: .browsecard/.vcard/.tcard 逐张上浮(6级延迟) — 只挂用户主动触发的低频列表
- **reduce-motion 全收**: 新动画一个不落的进媒体查询
- **血泪**: ① 入场动画绝不能挂高频 innerHTML 重渲的容器(任务列表每秒重建→每秒闪) ② .logo 入场
  别碰 — pipboy 打字机/v14 主题 logo 规则特异性会互相覆盖, 各主题 logo 已有特色

## 25. v17 · 设置页 + 功能六件套 + 自适应主题 (2026-10-24)

- **独立设置页** page-settings: nav 齿轮; 从下载页搬入 凭据/手机访问/字幕大小/特效/日志/界面风格 六张卡
  + 孤儿分组 h2 一并清理; 新增 睡眠定时/最近播放/统计 三卡
- **观看进度备份**: server.py `/api/progress`(POST 存+_progress.json 落盘 / GET 全量);
  savePos() 写入时同步 server; 启动时 server 记录合并回本地 hist 账本(>20s 且未看完15s内才算),
  续播卡片(renderResume)与最近播放自动获得跨浏览器/重装不丢的能力
- **批量下载**: input#url→textarea; parse() 拆 parseOne(raw), 多行逐行解析排队(350ms 间隔)
- **睡眠定时**: 设置页 chips(关/15/30/45/60), window._sleepT, 到点 pause+toast
- **最近播放/统计**: 复用 histLoad 账本(点击 data-open 走现有 openRel 委托); 仪表盘 LIB.videos
  (视频数/P数/size_mb 总大小/收藏), statsRender 挂 loadLib 刷新
- **第 7 主题 mauto「自适应」**: 视频帧 drawImage 到 8×8 canvas, 取"饱和度×亮度"最高分像素为主色,
  5s 间隔写内联 --acc/--edge/--srf2; CSS 兜底防闪烁; 切走 mauto 时 removeProperty 防污染其他主题;
  #pmodal 映射不覆盖 --acc → 播放器控件自动跟主色
- **大扫除**: 程序化检测删 17 死词条(×中英) + 14 条 chap 死 CSS 规则
- **血泪**: ① 搬卡时别落下分组 h2(孤儿标题) ② 死词条检测要扫双引号和 data-i18n 属性两种引用
  ③ Object.entries().forEach 回调参数闸2不认, 用 for 循环+行内 const ④ rep 锚点先核对 async 前缀

## 26. v17.1 · 播放器内特效快切 (2026-10-24)

- pctrl 加 FX 按钮(i-theme 图标), 点击弹出 #fxPop 面板(上浮淡入, absolute 挂 #pctrl)
- 5 档直达: 关/CRT/VHS/胶片/霓虹, 当前档高亮; 设置页 fxSel 与面板双向同步
- fxSet(m) 统一入口封装(原 onchange 三行散落逻辑), 两处 UI 都调它
- 面板点击外部自动收起; 词条复用 fxOff/fxCrt/fxVhs/fxFilm/fxNeon

## 27. v17.2 · 黑屏根治 + 播放器重排 (2026-10-24)

- **特定主题播放黑屏根治**: 根因 = synthwave/pipboy 场景层的 infinite 动画与 Android video 硬件解码层冲突。
  body.pm-open 挂/摘钩子(随 pmodal open/close), CSS 一条 animation-play-state:paused 全场景层静默;
  openPlayer 60ms 后 repairSurface() 双保险
- **最近播放去重**: hist 账本是"每次观看一条"设计, recentRender 按 r 去重只留最新
- **统计 0MB**: part 字段是 size 不是 size_mb
- **控件隐藏 6s→3s**(poke 的 barT)
- **播放器重排**: ① 中央播放键 #pCPlay(74px 毛玻璃圆钮, absolute 居中, 复用 togglePlay,
  play/pause 同步 <use>, hideCtrl/poke 同 lifecycle) ② pctrl 移除 pPlay(悬空引用已清, 闸1 把关)
  ③ FX 按钮上移 hrow2, fxPop 改顶部弹出 ④ 睡眠 Zz 按钮上移 hrow2 + sleepPop 面板,
  sleepSet() 统一入口设置页/播放器两处共用 ⑤ #phead 本就是 absolute(定位上下文现成)
- **血泪**: ① 删按钮必须全局搜 id 引用(闸1 会逮, 但最好在删前先搜) ② 场景层动画是 Android video
  黑屏的高发根因, 播放器打开期间静默是通用解法

## 28. v17.3 · 中央键收尾 + 着色器流畅根治 (2026-10-24)

- **中央键**: 透明度 .55→.30/边框 .28→.16/68px(不挡画面); 补齐漏网显隐路径 — 单击手势
  和 pause 事件里直接操作 bar 的代码不走 hideCtrl/poke, 中央键曾只在主路径跟随
- **着色器"顿顿的"根治四板斧**:
  ① GL 上下文加 powerPreference:'high-performance' — 别把渲染分去省电核心
  ② texImage2D 去重 — video 解码 24-30fps vs rAF 60fps, currentTime 没变就跳过重上传, 省一半纹理带宽
  ③ 基准分辨率 DPR cap 1.5→1.25 — 起点降 30% 像素
  ④ fps 自适应 — 每 45 帧统计: 持续<38fps 渲染尺度×0.85(最底 0.5, fxFit 重算画布), >55fps 缓慢回升
- 顿感根因链: Android Chrome 给网页分省电调度 → rAF 帧率低 → 时间连续但帧间隔大 → 效果跳动

## 29. v18 · 播放器主题深融合 (2026-10-24)

终端主题融合的配方 = pctrl 全定制 + phead 渐变 + pmodal 变量映射 + TUI 语汇多层叠加;
其他主题只吃了变量映射的表层。补齐:
- **病灶板变量化(一处治好所有主题)**: #partCover 封面底板 #1b1b26→var(--srf2)/var(--bg);
  #listPanel/#queuePanel 面板底 rgba(16,16,20,.97)→color-mix(var(--srf3) 96%) — 这俩是"封面/面板不跟主题"的元凶
- **pfill 进度条短板**: catppuccin 粉彩渐变 / geist 纯白 — 之前它们露着 mono 的 B 站粉, 割裂感主源
- **geist pctrl 补完**: 之前裸奔(只有 icbtn.on 颜色), 现在深灰底+细边+白字
- **中央键逐主题**: pipboy 绿边 / synthwave 霓虹边 / catppuccin 粉彩边 / retro 像素方钮
- **retro 像素块进度条**: repeating-linear-gradient 9px 草绿块 — MC 物品栏语汇延伸
- mono 进度条保留 B 站粉 = mono 的个性, 不动

## 30. v18.1 · 封面融合 + synthwave 阳光 (2026-10-24)

- **"纸片感"根治**: 媒体库封面是实打实的彩图, 卡片硬边贴背景上像异物。两味药:
  ① .vcard .cov::after 底部 32% 渐变(var(--srf)) — 封面下缘"熔接"进卡底板, 消硬边
  ② --cardglow 环境辉光(卡片阴影叠一层主题色) — 各主题变量段声明, :root 默认透明, mauto 也有份
- **synthwave 阳光**: body::before 背景顶部加两层 — repeating-conic 从太阳中心(50% 104px)
  向下 2.5°宽金黄光束扇形展开(9°周期) + 180px 橙金光晕。repeating-conic 放最上层被太阳圆盖中心,
  光束自然从日缘射出; 透明度 .10 不抢戏

## 31. v18.2 · 全局 UI 融合层 (2026-10-24)

- **顶面主题光**: 所有卡片/面板/标签组/目录行 background-image 叠加 7% --acc 顶渐变(42% 处淡出),
  像被场景光源照亮; 用 background-image 分量叠加, 不碰现有 background 简写和 box-shadow
- **环境辉光**: filter:drop-shadow(0 6px 18px var(--cardglow)) — drop-shadow 不动 box-shadow,
  retro 的像素阴影/pipboy 的内辉光零冲突
- **毛玻璃透出**: synthwave blur 18(原 82% 半透明无 blur) / geist 85%+blur 14 / retro 94% 微透无 blur(保像素锐度)
- retro 全程排除渐变/辉光 — 纸片人格不能软; pipboy/mono 本就单色无场景层, 不加 blur
- mono 补 --cardglow 淡粉(.06)
- **血泪**: 叠加光影别用 box-shadow 简写(会清掉主题定制阴影) — background-image 分量叠加 +
  filter:drop-shadow 是零冲突双通道

## 32. v17.4 · 黑屏根除 + 中央键常显 (2026-10-24)

- **黑屏从"缓解"到"根除"**: v17.2 的暂停动画只治了 animated 层, retro 的**静态** fixed 场景层
  同样触发 video 解码层冲突(用户实测复现)。修法升级: 播放器打开时 display:none 场景层 — 
  全屏被不透明 #pmodal 盖死, 场景层本就看不见, 隐藏零视觉代价, fixed 层冲突连根拔除
- **中央键常显**: 之前跟着 hideCtrl 隐藏 → 用户看到"点一下出现再消失"以为没生效。实际它是
  正常工作的, 只是被误隐藏。撤出隐藏体系常显, 透明度再降 .30→.22, 定位=播放状态灯
  (播放中显暂停图标/暂停显播放图标)

## 33. v17.5 · 中央键收尸 + 着色器热节流稳态 (2026-10-24)

- **中央键**: ① 删 backdrop-filter — Android 上 backdrop-filter 元素与 video 同框是黑屏大户(retro 黑屏嫌疑+1)
  ② 显隐改 #pmodal:has(#pctrl.hide) #pCPlay 纯 CSS — 显隐 100% 跟随控制条, hideCtrl/poke/单击手势/
  pause 所有野路径自动同步(旧 JS 逐路径挂钩必然漏), JS 钩子留作 :has 不支持时兜底
- **着色器越用越卡**: 不是内存泄漏(program/texture 复用、监听一次性绑定, 全排查过) — 症状
  "视频流畅着色器卡" = 手机发热降频: 硬解视频不吃 CPU, GL 效果吃 GPU 先感知。
  旧自适应在发热场景 fps 38-55 间震荡 → 每 45 帧重设 canvas(纹理重 alloc+合成层重建) 反而更卡。
  稳态化: 快降(×.8)/慢升(+.04)/双阈值滞回(降<38 升>58)/升档 30 秒锁定/采样窗 45→60 帧

## 34. v19 · 性能大治理 (2026-10-24)

- **#phint span**: 删 backdrop-filter:blur(6px) — retro 黑屏最后嫌疑(视频区里最后一个 blur 雷)
- **毛玻璃降档**(大面积 blur 是移动端最贵 CSS, 媒体库 60 卡滚动时卡爆):
  synthwave 18→10 / geist 14→8 / catppuccin 12→8+底更不透明(84%)
- **drop-shadow → box-shadow 多层**: v18.2 的 filter:drop-shadow 给每张卡建合成层(60卡=60层),
  改 box-shadow 追加辉光层(绘制时画, 不建层); retro/pipboy 排除保定制阴影
- **着色器再压**: DPR 基准 1.25→1.0(像素量-36%, 6寸屏1080p看不出), 自适应下限 0.5→0.4 降档 ×0.8→×0.75
- 场景动画排查: synPulse/synRoll/geist漂移/pipboy 全是 transform/opacity 合成器动画, 便宜, 不动
- **血泪**: 移动端 CSS 性能三雷区排序: backdrop-filter > filter(每元素合成层) > 大面积渐变动画;
  辉光类效果永远优先 box-shadow 多层方案

## 35. v19.1 · 落日体积光 + 发热根治 (2026-10-24)

- **落日重做**: 删 repeating-conic 线条光束(用户: 太low) → 体积光四件套:
  ① 地面反光 linear-gradient(to top) 橙金洒在网格上 ② 宽光柱 conic 带亮芯(11°-23°, 中心 .26 亮)
  ③ 天空染色 顶部暖橙渐变 ④ 暖阳晕 210px。静态渐变零动画成本
- **发热根治**: pollTick 原每 3s 无条件 refreshTasks+loadLib — loadLib 重建 60 张卡+触发
  vcard stagger 动画每 3s 全场重播(动画挂高频容器, v16 时的告诫自己踩了)。门控:
  媒体库全量重建只在 任务页/媒体库页激活时; 其他页只 refreshTasks(轻量)。轮询重建时
  #lib.rebuild 禁入场动画

## 36. v19.2 · 着色器渐进卡顿收尾 (2026-10-24)

- **texImage2D → texSubImage2D**: Chrome 对 video 元素反复 texImage2D 会走存储重分配路径,
  部分驱动累积 GPU 内存不释放 = "越用越卡"的驱动级根因(已排除 JS 泄漏/监听绑定/program 复用)。
  texSubImage2D 只更新像素不重新分配存储(官方推荐); 首帧仍 texImage2D 初始化(window._fxTInit 标志,
  纹理重建时归零)
- 至此着色器性能五层防御: 高性能GPU → 纹理去重 → DPR1.0基准 → fps自适应稳态 → texSubImageD

## 37. v19.3 · 双视频叠加根治 + 原生清晰度 (2026-10-24)

- **双视频叠加/黑屏真凶**: v19.2 的 texSubImage2D 有尺寸陷阱 — 换视频后新分辨率≠纹理存储尺寸
  时更新 INVALID_OPERATION, fxCv 画布冻结在旧视频最后一帧 → 新旧画面叠加(或整片冻结=黑屏感)。
  修法: videoWidth/Height 匹配才走 texSubImage2D, 不匹配/首帧/分辨率变化 → texImage2D 全量重建
- **清晰度还原原生**(用户点名): 删 _fxQ 分辨率降档(含稳态逻辑), DPR 上限 1.0→2.0。
  保留: 纹理去重 + texSubImage2D(尺寸守卫版) — 这俩不降画质
- synthwave 卡底 82%→90%, 落日透出含蓄

## 38. v19.5 · 黑屏自愈架构(永久根治) (2026-10-24)

七轮对症修复(synthwave/pipboy/retro 轮流犯)证明根因是机型/GPU/驱动层面的组合, 远程猜测修不完。
换打法: 自愈 — 让"用户看到黑屏"在系统层面不可能发生:
- fxLoop 每 30 帧 gl.readPixels 读画布中心像素, 连续 3 次(<5/255, ~1.5s, 防夜景误伤) 全黑
  且 video 在播/非音频 → fxStop+fxStart 重建 GL 全链路(program/texture/缓冲全重建)
- 同视频重建 >3 次仍黑 → FX_MODE=off 落盘, 回退原生 video(fxStop 隐藏 fxCv 即露出原画),
  toast 提示; 下个视频 _fxRecovers 归零给特效重试机会, 连续 3 个视频都黑才维持关闭
- 不猜根因: 驱动 bug/图层冲突/纹理失败/静默 context lost — 黑=被检测=被修复或回退
- **血泪**: 反复出现的平台级 bug, 别再做第 N 次根因猜测 — 上自检+自愈+优雅降级三件套

## 39. v19.6 · 着色器根治·RVFC 架构 (2026-10-24)

搜索+发散后的架构级重做:
- **渲染驱动: requestVideoFrameCallback 替代 rAF** — 回调绑视频解码帧率(25fps视频=25次渲染/秒,
  rAF 60 次纯属浪费), 与解码器零浪费同步, 时间仍连续(performance.now() 驱动 GLSL 时间)
- **texImage2D 回退**: Unity 论坛实测 Chrome 上 texImageD **way faster**, 此前按通用建议改的
  texSubImage2D 方向错误已回退; RVFC 每次回调必是新帧, 天然去重, 直接全量
- **rAF 30fps 节流回退**(老浏览器)
- 驱动双轨: 支持 RVFC 走 fxVF, 不支持走 fxLoop, fxStart 自动选, fxStop 双取消
- 黑屏自愈(v19.5)在 fxRender 内继续生效
- 理论依据: ml5/Chrome 案例 GPU 进程随 video-texture 时长劣化 → 渲染次数减半 = 累积速度减半,
  配合 RVFC 精确同步消除空转

## 40. v19.7 · 终极体检收官 (2026-10-24)

全项目发散审计结论:
- **后端健康**: ThreadingHTTPServer(多线程, 视频流不堵API) + Range 13处 + 死端点已清
- **前端规模**: 221KB 单文件 / CSS 646 规则 / JS 2436 行 / i18n 220+键中英对齐 / 30 SVG 图标
- **渲染管线**: RVFC 驱动 + texImage2D + 黑屏自愈 + readPixels 自检 — 平台级问题全部架构自愈
- **性能三雷区**: backdrop-filter 34处残留全是已降档卡片(8-10px) | drop-shadow 合成层已清 |
  轮询已页面门控
- **定时器**: 仅 2 个 setInterval(mauto 5s 取色带主题预检 + pollTick 3s 已门控)
- sw 缓存名 v1→v2

## 41. v19.8 · 合成层快路径 (2026-10-24)

搜索"丝滑且省电"的 actionable 结论:
- **fxCv/pvideo 加 translateZ(0)**: 15 浏览器实测 Android Chrome 合成提升 35%(web_search:269#9) — 每帧
  参与合成的两个元素走合成器快路径, 不再每帧与页面层协商
- 旁证搜索: DVFS 论文证实"帧率匹配负载"是省电视角的最优解(RVFC 已做到); emscripten 官方
  "lowest possible precision on mobile"(mediump 已符合); "单 pass SuperShader"(已符合);
  渲染循环零对象分配(已符合)
- 剩余理论空间: shader 分支削减/低精度 hash — 收益小风险大, 不动

## 42. v19.9 · 着色器定期保养 (2026-10-24)

- window._fxCare 每 90 秒(仅播放中): deleteTexture + createTexture + 参数重设 + _fxTInit=0
- 原理: ml5/Chromium 案例证实 Chrome GPU 进程处理 video-texture 随时长渐进劣化; 定期换纹理对象
  让该路径重走干净初始化, 累积每 90 秒清零一次
- 零打断: 纹理每帧本来就要上传(texImageD), 换对象后下一帧就是一次常规全量上传, 单帧开销无感
- program 对象不保养: 重编译要几十 ms 会真卡; 单对象无累积问题
- 暂停/关闭/特效关/context丢 时不动作

## 43. v19.10 · 感知层优化 (2026-10-24)

发散推演结论:
- 人眼流畅感主因 = 帧间隔均匀(jank感知), 不是帧率高 — 24fps电影恒定间隔没人说卡。
  RVFC 天然供给恒定间隔, 此层已满配
- 死路两条(已排除): 双纹理ping-pong(直接采样视频帧架构, 交替会放出旧帧);
  帧混合柔化(需FBO双pass, 成本反涨40-60%)
- 落地: ① GLSL 时间流速 ×0.9 — 运动幅度降10%, 同样帧率下更柔更不暴露不均匀,
  速度变化低于人眼察觉阈 ② 纹理保养 90s→60s

## 44. v19.11 · 全项目终审 (2026-10-24)

逐文件审查结论:
- **server.py (2937行)**: ThreadingHTTPServer + safe_media_path/safe_dir_path 路径穿越双防护 + Range
  拖动 + iOS MP4 兼容副本 + 死端点已清 — 健康
- **start.sh/boot.sh**: 保活循环+wakelock+termux-notification 完备 — 健康
- **sw.js/manifest**: 网络优先+离线壳, 缓存名 v2 — 健康
- **前端盲区复查**: 字幕系统(gen代次令牌防竞态)/任务系统(Map)/下载队列 — 健康;
  eval=0, XSS esc() 双层防御在位, console 仅 shader 编译告警 2 处
- **i18n 终验**: zh 211/en 213 键完全对齐; 修复 uiAdaptiveHint 被 v17 死词条清理误删(zh 缺 en 在);
  Damaged/tablet 两键差为值含冒号的正则假阳性
- **测试件**: chaos_test/e2e_real/fake_yt_dlp/selftest 在位 — 不改
- **体检数据**: 221KB 单文件/646 CSS 规则/2436 行 JS/30 SVG 图标/GL 30+uniform

## 45. 未来线索 · 着色器性能的未竟之路 (2026-10-24, 存档给下一代 AI)

用户决定暂缓。已穷尽的方案: RVFC驱动/texImage2D/黑屏自愈/60s保养/合成层/感知层/时间流速 — 
卡点在 Android Chrome 的 <video>→WebGL 纹理路径(架构性上限, 网页层无法绕过)。
**下一代可探索的方向(按优先级)**:
1. **WebCodecs API** — VideoDecoder 解码出 VideoFrame 对象, 直接 texImage2D(VideoFrame),
   绕过 <video> 元素的合成器路径 — Chrome 官方推荐的未来视频处理姿势, 可能是真根治
2. mpv IPC 混合架构(网页遥控器+mpv引擎) — 设计已在对话中定型, 未动工
3. Chrome 自身演进 — 零拷贝 video texture 是 Chromium 团队持续投入方向, 可能某天自愈
桌面端 Chrome 的着色器流畅度待用户验证(可能只有 Android 病灶)。
