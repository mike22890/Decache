# Decache v22.1 交接手稿（2026-11-05）

> 上一份是 `HANDOFF-v21.7.md`（v21.7/v22.0 并行会话的产物）。本份是**全量自审后的状态**。

## 本轮做了什么：一次全仓库自审 + 修复

范围：`server.py` / `index.html` / `install.sh`+`sync_install.mjs` / CI / 文档 / 测试基础设施。
方法：主 agent 逐行读 + 3 个并行子代理（server 安全、install.sh、index.html 四类问题）+ 一路生态调研。

### 后端（server.py）
1. **`/api/progress` 只有 POST 没有 GET** → 前端「把服务端进度合并进本地账本」永远拿 404，
   "重装/换浏览器不丢进度"这条功能**一直是死的**。补 GET 端点。
2. **POST `/api/progress` 重复读请求体** → `_do_POST` 开头已 read 过一次，这里又 `rfile.read()`，
   读空 + **阻塞等下一段字节**，客户端直接超时。改为复用已解析的 `body`。
3. **Range 解析三个洞**：`bytes=99999999999-` 算出**负 Content-Length**（客户端卡死）；
   `bytes=500-100` 倒挂；`bytes=-N`（取末尾 N 字节）被当成从头发。→ 416 / 退化成整段 / 正确取末尾。
4. **文件名穿越**：`/api/upload` 的 name 和 `/api/import_local` 的 names 都能带路径
   （`../../x.mp4`）→ **写到下载目录外面**。现在只取文件名本体 + 落地路径必须在目录内。
5. `open_external()` 的 termux-open 等全部加 timeout + DEVNULL（原来 Popen 无时限，IPC 未就绪会永久挂起）。
6. `VERSION` 从冻结的 `15.1` 改为 `22.1`；`data-ver` 从 `v15.1-20261024` 改为 `v22.1-20261104`。
7. 诊断端点加一条提示：面板本体 3.9 能跑，但 **yt-dlp 2026.10.26 起要求 Python ≥3.11**。

### 前端（index.html）
8. **两个 `<script>` 块让三道闸全废**：`frontcheck.mjs` / `smoke.mjs` / CI 的语法检查都只抓第一块
   （37 行的 v21.9 诊断浮层）→ 主脚本 2600 行**从来没被检查过**。三个工具改成抓全部块。
   CI 的 `sed` 管道本来就已因此报 `Unexpected token '<'`（**CI 现在必红**）。
9. **「继续观看」账本迁移有个一次性锁** `_histMigrated`：页面启动时第一次 `histLoad()` 没找到旧键
   就把锁扣上 → 之后旧键再出现也永远搬不进来。锁删除（smoke 的 12 项回归断言此前也是红的）。
10. **`retro` 草地渐变是 top-anchored** → 草地跑到视口**顶部**，顶栏正下方横一道绿边。改 bottom-anchored。
11. **`mauto`（自适应）已移除但 chip 忘摘** → 点了只剩半截主题，还把 `take_ui=mauto` 写进 localStorage。
    chip 删除 + 整套 mauto CSS 清空 + 白名单提成 `UI_THEMES` 常量并在 `applyUiTheme()` 里每次校验。
12. **`selAll()` 断链**：按钮 `onclick="selAll()"` 调的函数不存在（已改名 `selAllLib`）→ 点即 ReferenceError。
13. **`prunePos()` 从未接线** → `take_pos_*` 键无限增长撑爆 localStorage。接进 `savePos()`。
14. **氛围光 rAF 从页面加载自续到关页** → 播放器没开也 60fps 唤醒。改成"播放器开着才续"，openVideo 点火。
15. **resize 未节流**（两处监听各读一次 clientWidth 强制重排）+ `fxFit` 每次都重设 canvas.width/height
    （重分配 GPU 背板并清空纹理）→ 合并成一个 rAF 节流器 + 尺寸没变就不碰背板。
16. **任务列表每 3 秒无条件重建 DOM** → 打断滚动和点击中的按钮。改成内容没变就不碰 DOM。
17. `partRel()` 死函数删除；`@keyframes pageIn` 重复定义删一份；`retroCloud` 重复块删一份；
    `pipFlick`（pipboy 扫描线闪烁）补回 —— 交接手稿声称"已恢复"，实际代码里没有。
18. 任务状态的 `x.status_code` / `x.status` 补 `esc()`（数字字段目前无害，后端改类型即破）。

### 安装器（install.sh ← sync_install.mjs）
19. **死镜像自愈那条 `sed` 会杀死安装器**：`sources.list.d/` 为空时 glob 不展开 → sed 收到字面路径
    退出码 2 → `set -e` 直接中断，而 `2>/dev/null` 把错误吞了，用户只见脚本"没反应"。改逐文件处理。
20. **"旧目录迁移"块是自我拷贝**：`OLD` 和 `APP` 都是 `~/decache` → `cp -a X X` 报 "are the same file"
    被吞掉，迁移功能实际不存在。整块删除（历史版本从没换过安装目录，升级天然原地覆盖）。
21. **9 个文件全部 `cat >` 直写**，磁盘满/断电留下半截 server.py，面板直接 500 且无 .bak 可回滚
    → 改成先写 `.tmp` 再 `mv`。
22. **图标 base64 解码失败留 0 字节 PNG**（`>` 先创建目标）+ `.b64` 残留 → 解到 `.tmp` → 校验非空 → 才 mv。
23. **包名错了**：Termux 官方仓库里是 `python-yt-dlp`（不是 `yt-dlp`），另有 `yt-dlp-ejs`；
    yt-dlp 2026.06.09 起解 YouTube 还要 Deno≥2.3 / Node≥22。安装器补 `python-yt-dlp yt-dlp-ejs deno`。
24. `pkg install` 补 `procps`（start.sh 用 `pgrep`）；`pm list packages` 加 timeout；
    新增 Termux:API **应用**（com.termux.api）检测 —— 只装 CLI 不装应用，wake-lock/notification 静默失效。
25. `start.sh` 改用 `python3`（Termux 的 python 包不保证有 `python` 这个命令名，缺了 3 秒一轮空转）。

### CI / 测试
26. **CI 的语法检查**：`sed` 管道改成逐块抽取 + `vm.Script`（并修好它必红的问题）。
27. **CI 现在跑 frontcheck（8 闸）+ smoke + chaos + fake_yt_dlp** —— 这四套此前**根本不在 CI 里**。
    闸 8 需要 stylelint，CI 里补装。
28. CI 矩阵加 3.14（Termux 主线当前版本）。
29. **selftest 用 `HOME/"downloads"` 当下载目录**，与平台默认 `~/Downloads/decache` 在 Windows 上
    大小写撞车 → 本地永远红一条、CI 绿。改用 `dlroot`。
30. selftest 隔离 `PROGRESS_FILE` —— 此前测试的 POST /api/progress 会**写脏用户真实的 `_progress.json`**。
31. `.gitignore` 补 `_progress.json`。

### 文档
32. README 的行数（2900/4200 → 3100/4500）、闸门数（7 → 8）、主题数（七套 → 六套）、版本 badge 对上现实。
33. README/诊断端点写明**两级 Python 口径**：面板本体 3.9+，下载引擎 yt-dlp 3.11+。
34. THEMING.md 改成 sceneFx 真元素形态（别再按旧 `body::before` 结构 patch）。
35. HANDOVER.md 的两处 `sed` 语法闸命令同步更新。

## 验证证据（全部实跑，退出码 0）
```
python -m py_compile server.py selftest.py chaos_test.py fake_yt_dlp_test.py   OK
node -e '...vm.Script(全部块拼接)...'                                          OK
python selftest.py        全部通过 ✅   (新增 6 条断言: Range 边界/进度账本/文件名穿越)
python chaos_test.py      全部通过 ✅
python fake_yt_dlp_test.py 全部通过 ✅
node frontcheck.mjs       8 闸全过 ✅ (闸2 从"声明 14 个"变成 479 个 —— 以前只看了第一块)
node smoke.mjs            加载期无异常 + 继续观看 12 项全过 ✅ (以前直接崩)
node sync_install.mjs     9 个文件内嵌
bash -n install.sh        OK, stderr 无 heredoc warning, 9 个终止符各 1 次
```
浏览器实测（ui-preview 8790）：retro 草地已回底部（`bgPos: 0px 100%`），顶栏下方无绿带，布局无空白。

## 待办 / 未做（明确留给下一轮）
- **整页闪**（Mike 报的 1-2 秒整页刷新感）根因**仍未定位** —— 场景动画群已恢复+强化，但整页闪与场景动画无关。
  下轮上 Kiwi USB 调试 adb inspect。
- **真机验收**：Kiwi 上跑一遍切主题/导入本地/播放列表浮层（桌面测不了视频路径）。
- **`inset` 简写 / flex `gap` 的老内核降级**：全文件 40+ 处，老 Chromium 上会整体失效，
  本轮只做了 `:has()` 的 JS 兜底补齐，没做全量降级（工作量大且会污染 CSS）。
- **CSS 降级层**：color-mix 32 处 / backdrop-filter 32 处 / mask-image 6 处，只有 5 处 @supports 兜底。
- **`_fxCare`（60 秒纹理保养）**没有"正在播放"判断，闲置时仍动 GPU。
- **上游兼容性**：yt-dlp 现在要 3.11+，仓库还没有"锁版本 + 真链路冒烟"的 CI job（见调研报告建议 5）。
- **本轮改动未 commit、未 push**（按项目铁律：不主动 push）。

## 环境备忘
- `ui-preview.mjs` 必须用 `pty=true` 起（background=true 非 tty 会秒退："stdin is not a tty"）。
- 改完 index.html 必须重启 ui-preview（它把文件读死进内存）。
- 端口 8790 上可能有**僵尸实例**抢答：`netstat -ano | grep :8790` 找 LISTENING 的 PID，
  `MSYS2_ARG_CONV_EXCL='*' taskkill /PID <pid> /F`（不加这个环境变量，`//PID` 会被 MSYS 吃掉）。
- 本机外网：国外域名 DNS 解析成 fake-ip 198.18.0.0/15，Hermes 需要 `security.fake_ip_ranges`；
  GitHub raw 可通（curl 200）。


---

# 追加：v22.2（2026-11-05 当天第二轮 · 真机反馈修复）

Mike 在手机上（Kiwi + Termux）实测提了 8 个问题，全部修掉。**未 commit、未 push**（按项目铁律）。

## 修了什么
| # | 问题 | 根因 | 修法 |
|---|---|---|---|
| 1 | 播放列表里导入的视频没缩略图 | `plrowHtml` 和分组头都 gate 在 `/^BV/i`，而导入/扫描条目的 bvid 是 `EXT_xxx`/`LOC_xxx` | 改成只要有 bvid 就要封面（服务端懒生成抽帧） |
| 2 | 「继续观看」卡没缩略图 | `renderResume` 的卡片 HTML 里根本没有 img | 补 56×38 封面 + `onerror` 自删 |
| 3 | 卡片封面失败时显示破图 | `<img>` 无 onerror | 加 `onerror="this.style.opacity='0'"` |
| 4 | 顶部页签栏会跟着内容滚走 | v21.9 把 `sticky` 改成了 `relative` | 改回 `sticky`（贴视口顶，切页签不用再滑回去） |
| 5 | 右下角浮球一直悬着盖住卡片 | `#libNav` 是 `position:fixed` | 改 `sticky`（仍在文档流，贴右下跟随，不压内容） |
| 6 | 关播放器后列表面板留在原地 | 面板是全局 fixed 浮层，`closePlayer()` 没收 | `closePlayer()` 里加 `$('listPanel').classList.remove('show')` |
| 7 | 粘贴按钮弹「剪贴板不可用」就完事 | `navigator.clipboard.readText()` 在安卓 WebView/Kiwi 上经常 reject | 失败时聚焦输入框 + 提示"长按输入框粘贴" |
| 8 | 播放器顶栏没跟上主题 | 只有背景渐变是各主题的，文字/按钮是通用色 | 六个主题的 `#phead` 标题/副标题/按钮全部收进各自语言 |
| 9 | 下载失败只给一句英文 | `Invalid data found` 不匹配任何 ERROR_HINTS | 加提示 + 失败时清临时分片（否则补下永远跳过） |
| 10 | 标签页标题还写 `Decache v15.1` | `<title>` 从没更新过 | 改成 `Decache` |

## 验证
- 全套闸门绿：`py_compile` / 语法闸 / `selftest` / `chaos_test` / `fake_yt_dlp_test` / `frontcheck`(8) / `smoke`(12) / `sync_install` + `bash -n`
- 浏览器实测（390×844 移动视口，`Emulation.setDeviceMetricsOverride`）：
  - `.tabbar` = sticky、`#libNav` = sticky（位置 [692,332,38,136]，在媒体库末尾、右对齐、不压卡片）
  - 播放列表分组头 `background-image: url(.../api/cover/EXT_532bb42570...)` ✓
  - 媒体库卡片封面 `naturalWidth=480` ✓
  - `/api/cover/EXT_532bb42570` 返回真实 JPEG（14228 字节，`ÿØÿ`）✓
  - `<title>` = `🐴 Decache` ✓

## 环境备忘（新增）
- 手机上的 Decache 是 **Termux 本机**（地址栏 `127.0.0.1:8765`），不是 PC。改完 `build/` 的代码要**重新在手机上跑 install.sh** 才会生效。
- 测滚动行为一定要先让页面真的能滚：测试库里如果只有一个文件夹，扫描会合并成**一个条目**（多 part），页面根本没高度。


---

# 追加：v22.3（2026-11-05 当天第三轮）

## 修了什么
| # | 问题 | 根因 | 修法 |
|---|---|---|---|
| 1 | 播放列表彻底摸不到 | 只有播放器里的「列表」能开，关了就没了 | 媒体库搜索框旁加常驻按钮 + 统一 `togglePlaylist()`；从媒体库开时先 `buildFlat()`（以前 FLAT 空 → 空面板） |
| 2 | 下载还是失败（`Invalid data found`） | DASH 分离流合并阶段分片是坏的 | 第一次失败自动换**单文件兜底格式** `b[ext=mp4]/b` 重试（`_is_merge_err()`） |
| 3 | 继续观看缩略图不吃主题 | 六个主题的封面滤镜选择器里没有 `.resume .rcov` | 全部补上 |

## 新功能：终端绿屏着色器
设置 → 特效 → **终端绿屏**（对 pipboy 主题做的）。新增 `hs` uniform（P1 磷光绿），
去色→绿磷光 + 扫描线/荫罩/暗角/微曲率/滚动亮带。其余预设 `hs=0` 整段跳过。

## 验证
全套闸门绿 + `sync_install`/`bash -n`。浏览器实测（390×844）：特效下拉有 `term:终端绿屏`；
媒体库有 34×34 列表按钮，点它开出 22 行面板（含分组封面）。

## 还没解决的
- **终端绿屏的着色器在当前无 GPU 的 headless 浏览器里编译不了**（`fxGl` 为 null），
  只做了静态接线核对（uniform 声明/取值/赋值三处齐全、GLSL 语法与相邻块一致）。
  真机上看一眼，如果黑屏就是 GL 上下文没起来，把 `take_fx` 设回 `off` 即可。
- 下载兜底重试只在**引擎输出里带那几句关键词**时触发；真机重跑一遍才知道管不管用。


---

# 追加：v22.4（2026-11-05 当天第四轮）—— 播放列表在播放页终于能看见

## 真因（两个坑叠在一起）
1. **`body.pm-open :not(#pmodal):not(#pmodal *){animation-play-state:paused!important}`**
   把 `#listPanel`/`#qpanel` 也带上了（它们是 `#pmodal` 的兄弟，不是后代）。
   面板进场动画 `panelIn{from{opacity:0}}` + `fill-mode:both` 被暂停在第 0 帧
   → **面板 opacity 永远是 0**。DOM 里 class 在、尺寸位置对、22 行也渲染了，屏幕上什么都没有。
   → 修法：把这两个面板从那条规则里排除。
2. **`#phead` 参与自动隐藏**（`poke()` 3 秒后 `hideCtrl()` 给它加 `.hide` = 透明 + `pointer-events:none`）。
   正在播放时顶栏消失，点「列表」其实点在了画面上（只把顶栏唤回来），要连点两次。
   → 修法：**顶栏不再自动隐藏**，只收底栏；列表面板/队列开着时连底栏也不收。

## 验证
`frontcheck`(8) / `smoke`(12) / `selftest` 全绿。
浏览器实测（390×844，真实点击）：进播放器 → 等 4 秒 → 顶栏仍在（`pointer-events:auto`）→
点「列表」**一次**开出面板：`opacity=1`、`rect=[38,109,340,639]`、`z=200`、22 行、
缩略图与 P 标签齐全（截图人工核对：面板不透明、内容看得清）。

## 教训（写进 skill）
- **"元素打开了但看不见" 先查 animation-play-state / opacity，别查 display**。
  这条 `body.pm-open` 的动画暂停规则是 2026-10 为了省 GPU 加的，
  当时只想到 `#pmodal` 内部，没想到兄弟浮层。
- 真机排查播放器浮层，**必须真的点一次**并看屏幕，只看 DOM class 会被骗
  （我前面几轮就是只看 class 说"能开"，白改三轮）。


---

# 追加：v22.5（2026-11-05 当天第五轮）—— 下载到的是网页

## 真因（真机日志直接给出）
```
P1.html has already been downloaded | [download] 100% of 6.59KiB |
[VideoRemuxer] Remuxing video from html to mp4; Destination: .../P1.mp4 |
ERROR: Postprocessing: Error opening input files: Invalid data found when processing input
```
下回来的是 **6.59 KiB 的 HTML 网页**（B 站反爬/未登录），yt-dlp 当媒体处理，
再让 ffmpeg 把 HTML remux 成 mp4 → 报错。且 `P1.html` 留在盘上 →
重试时引擎 "has already been downloaded" 直接跳过 → 补下永远失败。

## 修法
- `_is_html_bogus(folder, p, reason)`：认出这个真因（`remuxing video from html` 或目录里有 `P{n}.html`）。
- 命中后**第一次就判失败**，不做无意义重试。
- 提示改成：「B站返回的是网页不是视频(反爬/未登录) —— 去设置页『站点凭据』填 B 站 cookie 后重试」。
- `_cleanup_part_files(folder, p, before)`：失败时清掉这一 P 的所有残留（含 .html），但保留 `_before` 里的旧文件。
- **合并两份重复的报错提示清单**（`ERROR_HINTS` / `_ERR_ZH`）—— 之前往 ERROR_HINTS 加的提示
  因为 `friendly_err()` 用的是 `_ERR_ZH` 而根本没生效。

## 真正的解法（要 Mike 做）
**给 B 站填 cookie**：设置页 → 站点凭据 → 填 `SESSDATA=...; bili_jct=...; buvid3=...`
（从已登录的浏览器 DevTools 里复制）。填完再点补下。

## 教训
- **引擎输出里的 `Remuxing ... from html` / `P{n}.html` 是关键证据** ——
  看到 "Invalid data found" 别只想到分片损坏，先想"下回来的是不是根本不是视频"。
- **别让失败文件留在盘上**：引擎的 "has already been downloaded" 会让重试彻底失效，
  必须清掉残留（但别删下载前就存在的好文件）。
- **同一语义的常量别维护两份** —— 两份就一定会只改一份。


---

# 追加：v22.6（2026-11-05 当天第六轮）—— cookie 名写成了 KEY

## 真因（两件事叠加）
1. **cookie 名写成 `KEY`** —— 用户照着输入框提示 "KEY=VALUE" 抄，真把键名写成 `KEY`。
   发出去的是名叫 `KEY` 的 cookie，站点不认。B 站要的是 `SESSDATA` / `bili_jct` / `buvid3`。
2. **值是 URL 编码的** —— DevTools/地址栏复制出来的 SESSDATA 里 `,`→`%2C`、`*`→`%2A`。

## 修法
- `cookie_pairs()` 用 `urllib.parse.unquote()` 还原值。
- 保存时若键名是 `KEY`/`VALUE`/`COOKIE`/`TOKEN`，返回 `warn` 并在界面点破。
- placeholder 改成 `SESSDATA=xxx; bili_jct=xxx; buvid3=xxx`；说明写明「键名必须真实，别写 KEY」。

## 正确的 cookie 填法（给 Mike）
从已登录 B 站的浏览器 F12 → Application → Cookies → 选 `https://www.bilibili.com`，
把这三个的 **Name 和 Value** 一起复制（值里可能有 `,` 和 `*`，直接粘，程序会还原）：
```
SESSDATA=<值>; bili_jct=<值>; buvid3=<值>
```
粘进 设置 → 站点凭据 → 保存，再点补下。

## 安全提醒
- **SESSDATA 等同于 B 站登录态**，别往聊天/截图/公开地方贴。本次对话里已经出现过一次，
  建议用完在 B 站「退出登录」一次让旧 SESSDATA 失效。

## 教训
- **输入框提示里的 "KEY=VALUE" 是占位示例，但用户会照抄** —— 提示语必须写明「键名要真实」。
- **从浏览器复制的值常带 URL 编码**，凡是替用户传 cookie/token 的地方都要考虑还原。
