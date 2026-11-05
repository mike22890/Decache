# Decache v21.9 交接手稿（2026-11-04 14:35 更新）

## 本轮已修（install.sh 530,848 字节已打包待真机验）
1. **切主题视频放大**（复古/复古未来）：v21.1 的盲重插在 Kiwi 上导致画面放大错乱。v21.7 改为：nudgeDecoder → 450ms 后 2D canvas 抓帧验黑 → 全黑才 reattachVideo+fxFit。健康视频零打扰。
2. **导入本地面板位置**：#sheet 从 bottom:78px+transform 改为 inset:0+margin:auto 正中央（老内核无 transform 依赖）。
3. **媒体库顶栏/搜索框固定**：.tabbar 与 .libtop 去 sticky 改 relative，跟随滚动。
4. **播放列表在播放页隐形**：#listPanel 的 color-mix 在 Kiwi 无兜底 → 面板透明隐形。已加 rgba 兜底。
5. **每隔 1-2 秒闪一下（Mike 澄清：不是场景动画，是整页像刷新一样的闪）**：场景动画群已按 Mike 指令**恢复+强化**（见下）。整页闪的根因未定位——v21.8 真机复测，若仍闪，下轮上 Kiwi USB 调试 adb inspect。
6. **导入本地 4 个全败（v21.8 根因修复）**：`/api/import_local` 端点存在，败在 `shutil.move` 于 Android 11+ 共享存储**禁删源文件**——move 必炸。修复：move 抛 PermissionError 自动降级 shutil.copy2（保文件多占空间）。server.py ast 验证通过。
7. **动态效果恢复+强化**：synPulse 天空呼吸（.82→.62 更明显）、synBtn 双色双层辉光 34px+64px、synTwk 星闪 2.4s、pipFlick 扫描线闪烁 5s（幅度 .96 只留质感）、uiblink 终端光标 1.4s、mauBreath 9s、synFloor 地板滚动 2.4s。周期错开不同步闪。
6. **氛围光割裂延迟**：v22.0 双画布 15fps 已是底子，追加中央淡出 mask + brightness .82→.66。
7. **pipboy 下载历史封面穿帮**：.histcard img 纳入绿磷光滤镜（.cov/.pv/.cthumb 原有）。
8. **底部空白区（固定几屏）**：v21.9 加诊断浮层（URL 带 ?dbg=1 顶部绿字实时显示 ver/ui/theme/视频状态/文档高度/高块排行）。桌面实测文档高度正常 → **高度嫌疑指向旧 fixed 伪元素错位病，v21.8 场景层迁真元素后大概率顺带治愈，真机复测确认**。若仍空白：诊断浮层截图发回（含 docH/高块排行），一枪定位。

## 并行会话冲突警告
build/index.html 里混入了**另一个会话的 v22.0 工作**（双画布氛围光 15fps、take_amb 总开关、tabbar 底部改顶部 sticky、pipboy 封面滤镜）。本会话 v21.7 与其共存，frontcheck 八闸全过。**后续改 index.html 前先 grep 'v22.0' 确认最新形态，别按记忆里的旧结构打补丁。**

## v21.9 新增（2026-11-04 14:35）
- **切主题修复换打法**：Kiwi 真机证明 DOM 重插导致画面放大——改为 pause/play 循环重建表面（无 DOM 操作），450ms 后 2D 抓帧验黑，真黑才重插。
- **列表面板/队列面板挪进 #pmodal**（DOM 层面），配 visibility 穿透（#pmodal hidden 时 .show 面板仍可见）——播放页里必定浮在视频上，Kiwi 的跨兄弟 z-index 不可靠问题绕开。
- **导入失败明细**：impGo 失败时 sheet 里逐文件显示 错误信息，截图即可回报根因。
- **诊断浮层**：URL 加 ?dbg=1，顶部绿字 500ms 刷新 ver/ui/theme/视频 readyState+尺寸+错误/stage 尺寸/文档高/高块排行。

## 待真机验收（v21.9）
- 切复古/复古未来主题播视频：应微闪一次→画面正常大小可操控
- 导入本地选 4 个：应全部成功（move 降级 copy）
- 播放器里点「列表」：右侧面板浮在视频上（深色不透明）
- 媒体库滚多深搜索框/顶栏都跟着走
- 动态效果：呼吸/辉光/星闪/地板滚动全部恢复且强化
- 氛围光：更暗更融合，延迟不显眼；设置里有「氛围光」总开关
- 若整页闪仍存在或空白区仍在：Kiwi 版本号 + USB 调试，adb inspect 定位

## 环境
ui-preview.mjs 用 PowerShell detached 起（bash 后台 wrapper 会 tty 死+留孤儿僵尸喡旧版）；杀端口：先 tasklist 找 node.exe 再 Stop-Process。测试工位 chromium 无 H.264（webm/VP9 也不行），视频播放类验证只能真机。
