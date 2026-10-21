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
  <a href="https://github.com/mike22890/Decache/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mike22890/Decache/actions/workflows/ci.yml/badge.svg"></a>
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

### 第 0 步：文件在哪（先下这个）

不知道下哪个？**就点这个按钮**：

> **[⬇ 下载最新版安装包 (take-bundle.tar.gz)](https://github.com/mike22890/Decache/releases/latest/download/take-bundle.tar.gz)**

其他拿法：

| 你想要什么 | 去哪拿 |
|---|---|
| 完整安装包（解压即用） | [Releases 页面](https://github.com/mike22890/Decache/releases) → `take-bundle.tar.gz` |
| 只要一个安装脚本 | [install.sh 直接下载](https://raw.githubusercontent.com/mike22890/Decache/main/install.sh) |
| 想看源码 | [Code → Download ZIP](https://github.com/mike22890/Decache/archive/refs/heads/main.zip) |

### 安卓手机（Termux）

**第 1 步**：装 [Termux](https://f-droid.org/packages/com.termux/)（Play 商店里那个版本太老，别用）

**第 2 步**：打开 Termux，把下面这行**整行复制粘贴**进去，回车（装依赖，几分钟）：

```bash
pkg install python ffmpeg
```

**第 3 步**：给存储权限（**只做一次**；不做的话下载的文件在 Termux 私有目录里，手机文件管理器根本看不到）：

```bash
termux-setup-storage
```

（弹出权限框 → 点"允许" → 自动跳回 Termux）

**第 4 步**：下载并安装（还是整行粘贴，回车）：

```bash
curl -L -o install.sh https://raw.githubusercontent.com/mike22890/Decache/main/install.sh && bash install.sh
```

> 不会用命令行？去 [Releases 页面](https://github.com/mike22890/Decache/releases) 下载 `take-bundle.tar.gz`，
> 用 ZArchiver 之类的解压工具解开，进到那个文件夹里运行 `bash install.sh`（一样效果）。

**第 5 步**：启动：

```bash
bash ~/decache/start.sh
```

看到 "面板已启动" 就行了。**别关掉这个窗口**（关了服务就停了；想放到后台跑就用 `tmux` 或 `nohup`）。

**第 6 步**：手机浏览器打开 → `http://127.0.0.1:8765`

### Windows / Mac / Linux

**第 1 步**：装两个东西

- Python 3.9 或更高：[python.org/downloads](https://www.python.org/downloads/)
  （Windows 安装时**一定要勾上 "Add Python to PATH"**）
- ffmpeg：[ffmpeg.org/download.html](https://ffmpeg.org/download.html)（Windows 选 "essentials" 那个 zip，解压后把 `bin` 目录加进 PATH）

**第 2 步**：下载安装包 → [⬇ take-bundle.tar.gz](https://github.com/mike22890/Decache/releases/latest/download/take-bundle.tar.gz)，解压到任意文件夹

**第 3 步**：启动

- **Windows**：双击 `start.bat`
- **Mac / Linux**：在这个文件夹里打开终端，运行 `bash start.sh`

**第 4 步**：浏览器打开 → `http://127.0.0.1:8765`

### 手机访问电脑上的视频库

把 config.ini 里的 `bind = 127.0.0.1` 改成 `bind = 0.0.0.0`，重启服务。
手机和电脑在同一 WiFi 下，手机浏览器打开 `http://电脑的IP:8765`（电脑 IP 在设置页「手机访问与安装」里有显示）。

### 装完还是打不开？

| 现象 | 原因和办法 |
|---|---|
| 浏览器说"无法访问" | 服务没起来。看终端窗口里的报错；端口被占用就改 `config.ini` 里的 `port` |
| 一直转圈 / 视频播不了 | ffmpeg 没装好。打开设置页看 "ffmpeg:" 那一行显示的是不是路径 |
| 找不到下载的视频 | 手机上要去 `termux-setup-storage` 授权过；下载目录是 `~/storage/downloads/decache` |
| 提示要登录 | 有些站要 cookie，在设置页填一下（格式 `KEY=VALUE; ...`）|

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