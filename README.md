# Decache

<p align="center">
  <img src="favicon.svg" width="88" alt="Decache logo">
</p>

<h1 align="center">Decache</h1>
<p align="center">
  <strong>Self-hosted local media library and video player.</strong><br>
  自托管的本地媒体库与视频播放器 —— 把"缓存里的东西"变成"你自己的文件"。
</p>

<p align="center">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-green"></a>
  <img alt="platform" src="https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20Linux-blue">
  <img alt="python" src="https://img.shields.io/badge/python-3.9%2B-informational">
  <img alt="tests" src="https://img.shields.io/badge/tests-278%20assertions-success">
  <img alt="deps" src="https://img.shields.io/badge/runtime%20deps-stdlib%20only-orange">
</p>

---

## 这是什么

**Decache 是一个装在你自己设备上的小网站。** 它做两件事：

1. **下载视频** — 粘贴视频链接，视频就存到你自己的硬盘上
2. **播放视频** — 下载好的视频，在浏览器里播放，有进度条、字幕、播放列表、多倍速

**所有文件都在你自己的设备上**，不上传任何服务器，不收钱，不看广告，不收集数据。

**能干什么**：

- ✅ 下载大多数视频站的视频（含 B站）—— 选清晰度，选 480p 省空间
- ✅ 本地播放器：进度条缩略图、章节、A-B 循环、播放列表、画中画、倍速、字幕
- ✅ 媒体库：文件夹浏览、彩色标签、收藏、多选删除、查重、磁盘统计
- ✅ 选清晰度：自动(最优) / 2160 / 1440 / 1080 / 720 / 480 / 360 / 240
- ✅ 仅音频下载：下成 m4a，省空间
- ✅ 手机/平板/电视都能播（下载成 H.264 + AAC，所有设备通用）

## 截图

Real screenshots from an Android phone (Termux), unmodified.

<table>
<tr>
<td align="center" width="50%"><img src="docs/screenshots/library.jpg" width="240"><br><sub>媒体库 · 封面 + 分辨率角标 + 标签</sub></td>
<td align="center" width="50%"><img src="docs/screenshots/download.jpg" width="240"><br><sub>下载页 · 解析 / 清晰度 / 设置</sub></td>
</tr>
<tr>
<td align="center" width="50%"><img src="docs/screenshots/tasks.jpg" width="240"><br><sub>任务页 · 实时进度</sub></td>
<td align="center" width="50%"><img src="docs/screenshots/folders.jpg" width="240"><br><sub>文件夹 · 直接浏览目录</sub></td>
</tr>
</table>

## 怎么安装

### 安卓手机（Termux）

```bash
pkg install python ffmpeg
bash install.sh          # 一键安装/升级
bash ~/decache/start.sh
```

打开浏览器 → `http://127.0.0.1:8765`

### Windows / Mac / Linux

1. 装 Python 3.9+ 和 ffmpeg
2. 下载这个仓库解压
3. 双击 `start.bat`（Windows）或运行 `bash start.sh`（Mac/Linux）
4. 浏览器打开 `http://127.0.0.1:8765`

### 手机访问电脑上的视频库

把 config.ini 里的 `bind = 127.0.0.1` 改成 `bind = 0.0.0.0`，重启。
手机和电脑在同一 WiFi 下，手机浏览器打开 `http://电脑的IP:8765`。

## 怎么用

### 下载一个视频

1. 打开 **下载** 页
2. 粘贴视频链接，点"解析"
3. 勾选想下的分P，选清晰度，点"下载所选"
4. 去 **任务** 页看进度

### 看下载好的视频

1. 打开 **媒体库** 页
2. 点视频封面 → 播放器打开
3. 点画面 → 控制条出现（6 秒后自动消失）

### 其他功能

- **标签**：卡片上点"标签" chip，选颜色
- **多选删除**：工具栏"多选" → 勾选 → 底部"删除"
- **播放列表**：播放器顶栏 ≡ 按钮，看所有视频并切换
- **章节**：播放器顶栏 "章节" 按钮，视频有章节的话自动显示
- **字幕**：播放器顶栏 CC 按钮，自动找同目录的 srt/vtt
- **画质切换**：播放器里点 "生成通用版" 把 HEVC/AV1/MKV 转成全平台通吃的 MP4

## 常见问题

**Q: 下载失败怎么办？**
打开 **任务** 页，失败的 P 旁边有"补下"按钮。或者去 **日志** 页看具体原因（中文翻译）。

**Q: 视频在手机相册/文件管理器里找不到？**
下载目录默认是 `~/storage/downloads/decache`（Termux）或 `~/Downloads/decache`（电脑）。用手机文件管理器去那里找。或者在 **磁盘** 页看占了多少空间、在哪里。

**Q: iOS Safari 播不了？**
iOS 只支持 MP4 + H.264 + AAC。下载时选"自动(最优)"会自动选这个组合；如果是 HEVC/MKV，点播放器里的"生成通用版"转换一下。

**Q: 重新下载 / 删掉视频？**
- 重新下：媒体库卡片的 ↻ 按钮
- 删掉整个视频：🗑 按钮（会删磁盘上的文件，不可恢复）
- 删一个分P：展开分P列表里的 🗑

## 合法声明

仅供个人学习研究与个人使用。请自行确保遵守所访问站点的服务条款与所在司法辖区的著作权法律。本项目不提供任何站点专属解析器，也不协助获取付费或受保护内容。

## License

MIT — see [LICENSE](LICENSE).

## Documentation / 文档

- `HANDOVER.md` — architecture, design decisions, compatibility matrix,
  known limitations, and the blood-stained lessons (read before editing)
- `LEGAL.md` — legal notice, scope boundaries, infringement report process
- `THIRD_PARTY_LICENSES.md` — attribution for external dependencies

<!-- TEST MARKER -->
