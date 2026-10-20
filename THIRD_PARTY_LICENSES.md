# Third-party licenses / 第三方许可

decache **does not bundle** any third-party binary. The following tools are
**external dependencies you install yourself**; their licenses apply to them,
not to this project.

decache **不打包**任何第三方二进制文件。以下工具均为**你自行安装的外部依赖**，
其许可协议属于它们本身，与本项目无关。

| Component | License | Purpose |
|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Unlicense | default download engine (external) |
| [you-get](https://github.com/soimort/you-get) | MIT | optional fallback engine (external) |
| [yutto](https://github.com/yutto-dev/yutto) | GPL-3.0 | optional B站-focused engine (external) || [FFmpeg](https://ffmpeg.org/) | LGPL-2.1+ / GPL (build-dependent) | thumbnails, audio extraction, remux (external) |

`yt-dlp` is licensed under the Unlicense (public domain). `FFmpeg` is
LGPL-2.1+ when built with `--enable-gpl` disabled and `--enable-libx264`
present; distributions shipping FFmpeg binaries must comply with that license
and the patent situation of the codecs they enable. FFmpeg itself is **not
redistributed** by this project.

`yt-dlp` 以 Unlicense（公有领域）授权。FFmpeg 的许可取决于其构建选项
（`--enable-gpl` 与 `--enable-libx264` 会使整体变为 GPL）。分发 FFmpeg 二进制
的人必须自行遵守其许可与所启用编解码器的专利状况。本项目不重新分发 FFmpeg。

See [LEGAL.md](LEGAL.md) for the project's own legal notice and scope
boundaries.
