# Security Policy / 安全策略

## Supported versions / 支持版本

Only the latest `main` is supported. This is a personal-scale tool; there are
no LTS branches.

仅支持最新的 `main` 分支。

## Reporting a vulnerability / 报告安全问题

Please report privately via GitHub **Security Advisories** on this repository
rather than opening a public issue.

请通过本仓库的 GitHub **Security Advisories** 私下报告，不要开公开 issue。

We aim to acknowledge within **7 days** and to ship a fix or mitigation plan
within **30 days** of a confirmed report.

我们力争在 **7 天**内确认，在确认后 **30 天**内给出修复或缓解方案。

## Threat model / 威胁模型

decache is designed to run as a **single-user, loopback-only** service:

- it binds `127.0.0.1` by default and exposes **no** authentication (there is
  nothing to authenticate against — it is your machine);
- it stores your cookie **in plaintext in your own `config.ini`** — treat that
  file as a secret and keep it out of version control;
- it writes `library.json`, `playlist.json`, and `tasks.json` next to the
  script; they contain **titles, filenames, and local paths** of your media;
- it makes **no outbound requests** of its own beyond the download engine and
  thumbnail extraction, and it sends **no telemetry**.

Do **not** expose it to a public network. If you must reach it from another
device, put it behind your own tunnel or reverse proxy with authentication.

decache 设计为**单用户、仅回环**的服务：

- 默认只绑 `127.0.0.1`，**无鉴权**（它跑在你的机器上，没有可鉴权的对象）；
- cookie 以**明文**存放在你自己的 `config.ini` 里 —— 请把它当机密，别提交进版本库；
- `library.json` / `playlist.json` / `tasks.json` 存在脚本旁，含媒体标题、
  文件名与本地路径；
- 除下载引擎与缩略图抽取外，本项目**不主动发起任何外发请求**，**无遥测**。

**不要**把它暴露到公网。必须跨设备访问时，请套你自己的隧道或带鉴权的反代。

## Path handling / 路径处理

All filesystem access is funnelled through whitelist checks
(`safe_media_path` / `safe_dir_path`) that resolve the target and compare
**path components**, not string prefixes. Keep it that way — do not
reintroduce prefix matching.

所有文件访问都走白名单校验（`safe_media_path` / `safe_dir_path`），
按**路径组件**比较而非字符串前缀匹配。改动时务必保持这一点。

## Secrets / 密钥

- Never commit `config.ini`, `cookies.txt`, `library.json`, `playlist.json`,
  `tasks.json`, `covers/`, or `thumbs/`. `.gitignore` already covers them.
- Issues and PRs must **not** contain cookies, session tokens, or private
  links.
