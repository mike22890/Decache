## 请先读 [CONTRIBUTING.md](../CONTRIBUTING.md) 的硬性边界

**以下内容请勿贴进 issue：**

- 任何 cookie / 登录凭据 / session token
- 需要登录才能访问的私密链接
- 付费、会员、限区内容的链接
- 大批量链接（一次贴几百条）
- 你自己媒体文件的完整路径（可脱敏为 `~/Movies/xxx`）

**请先贴这些信息**（不含任何凭据）：

- 平台与系统：`Android Termux` / `Windows 11` / `macOS 15` / `Ubuntu 24.04` …
- Python 版本：`python3 --version`
- 下载引擎与版本：`yt-dlp --version`
- ffmpeg 是否就绪：`ffmpeg -version | head -1`
- decache 版本：界面右上角显示的 `v6.x`
- 复现步骤：做了什么 → 期望什么 → 实际什么
- 相关报错原文（完整贴，不要只贴最后一行）

## 关于下载失败

decache 不内置站点解析器，解析与下载完全交给外部通用引擎。
请优先用该引擎自己的 issue 区报告**具体站点的解析/下载问题**，并在这里附上
`yt-dlp --verbose` 的输出片段 —— 这样维护者能判断是引擎问题还是本项目问题。
