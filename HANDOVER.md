# decache · AI 交接书 (HANDOVER) · v6.13

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
| `frontcheck.mjs` / `smoke.mjs` | 7 static gates for the frontend + a DOM-stub smoke run |

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
| `thumbs/` | 进度条缩略图雪碧图（mtime 哈希缓存，永不重抽） | 自动维护 |
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
| `/api/thumbs?rel=&dur=` | GET | 进度条缩略图雪碧图（12 帧，mtime 哈希缓存） |
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

## 13. 部署机器档案

Android 手机（Termux + Termux:API + Termux:Widget，建议 F-Droid 版）+ Windows PC 双端使用；
手机浏览器建议 Chromium 内核 80+；下载目录 `~/storage/downloads/decache`；Windows 上 start.bat 直接跑。

*本文件随版本更新。改代码不改本文档 = 失职。*
