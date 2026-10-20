# Decache

**Self-hosted local media library and video player.**
自托管的本地媒体库与视频播放器。
把"缓存里的东西"变成"你自己的文件"——下载一次，任何设备直接播。

<p align="center">
  <em>One folder. One command. Your files stay on your machine.</em><br>
  <em>一个文件夹，一条命令，文件全在你自己的机器上。</em>
</p>

---

## What it is / 是什么

A single-folder web app that turns your device into a personal media library
and a decent video player. It runs on **Android (Termux) / Windows / macOS /
Linux** with nothing but a Python 3 interpreter and `ffmpeg`.

一个"单文件夹"的 Web 应用，把你的设备变成私人媒体库 + 视频播放器。
只需要 Python 3 和 `ffmpeg`，在 **Android(Termux) / Windows / macOS / Linux** 上都能跑。

- **Local library** — scan folders, browse a directory tree, tag with colors,
  star favourites, build a play queue, export/import `.m3u`
- **Player** — seek-bar thumbnail previews, chapter markers, A–B loop, Up Next
  card, external subtitles with style control, PiP, audio mode, 4 play modes
- **Import** — paste a link; an **external general-purpose download engine**
  (yt-dlp by default) does the fetching. decache itself ships **no parser**
  for any specific site.
- **Runs anywhere** — pure Python standard library backend, zero-build
  single-page frontend, no external assets, no accounts, no telemetry
- **Installable as an app** — PWA: "Add to Home Screen" gives you a desktop
  icon, no terminal required
- **Plays everywhere** — downloads prefer H.264 + AAC in MP4, the one format
  every phone, tablet, TV and browser understands; anything else can be
  converted on demand

## Quick start / 快速开始

### Android (Termux)

```bash
pkg install python ffmpeg
bash install.sh          # 一键安装/升级
bash ~/decache/start.sh
```

### Windows / macOS / Linux

```bash
python3 server.py
```

Open `http://127.0.0.1:8765`.

### Universal playback / 全平台通用播放

The format selector prefers **H.264 (avc1) + AAC (mp4a) in MP4** over
higher-efficiency codecs, because that combination is the only one every
platform accepts out of the box:

| | iPhone/Safari | Android | Windows/macOS | Smart TV |
|---|---|---|---|---|
| MP4 + H.264 + AAC | ✅ | ✅ | ✅ | ✅ |
| MP4 + HEVC | ✅ (A10+) | ⚠️ | ⚠️ | ❌ |
| MP4 + AV1 | ⚠️ (iPhone 15 Pro/16+, M3+) | ✅ | ✅ | ❌ |
| WebM (VP8/VP9) | ✅ (Safari 14.1+) | ✅ | ✅ | ❌ |
| MKV | ❌ | ⚠️ | ✅ (Firefox 145+) | ❌ |

If a video only exists in HEVC/AV1 or a non-MP4 container, the per-part
**"生成通用版"** button converts it. It only remuxes (container swap, seconds,
lossless) when that is genuinely enough — H.264 in 8-bit 4:2:0 with AAC —
and re-encodes otherwise (10-bit/4:2:2 H.264, HEVC, AV1, Opus audio all need
it). The server also detects Safari/iOS clients — including Chrome and Firefox
on iOS, which are WebKit under the hood — and serves the compatible copy
automatically.

### Download engine / 下载引擎

decache calls an external engine. Install it yourself — it is not bundled:

| Engine | Install | Note |
|---|---|---|
| **yt-dlp** (default) | `pip install -U yt-dlp` / `pkg install yt-dlp` / [releases](https://github.com/yt-dlp/yt-dlp/releases) | actively maintained, supports most sites |
| you-get | `pip install -U you-get` | fallback, upstream mostly dormant |
| yutto | `pip install -U yutto` | another B站-focused engine; may fail to build on Android (Rust extension) |

Set it in `config.ini`:

```ini
[panel]
engine = yt-dlp
cookie =                 ; optional site login cookie: "KEY=VALUE; K2=V2"
```

The cookie domain is inferred automatically from the link you paste.

## Configuration / 配置

Everything lives in `config.ini` next to `server.py` — never overwritten by
upgrades.

```ini
[panel]
port = 8765
engine = yt-dlp
cookie =
delay = 4
download_dir = ~/storage/downloads/decache
scan_dirs = ~/storage/downloads,~/storage/Movies
exclude_dirs =
hang_timeout = 180
```

You can also set the cookie from the web UI (**设置** tab).

## Testing / 自测

```bash
python3 selftest.py       # 70 assertions, isolated temp HOME, no network
```

## Documentation / 文档

- `HANDOVER.md` — architecture, design decisions, compatibility matrix,
  known limitations, and the blood-stained lessons (read before editing)
- `LEGAL.md` — legal notice, scope boundaries, infringement report process
- `THIRD_PARTY_LICENSES.md` — attribution for external dependencies

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer / 免责声明

For personal study, research and personal use only. You are responsible for
complying with the terms of service of the sites you access and with the
copyright law of your jurisdiction. This project provides **no** site-specific
parser, and does not assist with obtaining paid or protected content.

The authors are not liable for any consequences of your use.

仅供个人学习研究与个人使用。请自行确保遵守所访问站点的服务条款与所在司法辖区的
著作权法律。本项目不提供任何站点专属解析器，也不协助获取付费或受保护内容。
作者不对使用后果承担责任。本声明不构成法律意见。
