# Contributing / 参与开发

Thanks for helping. This project is deliberately small and dependency-free —
please keep it that way.

## Hard boundaries / 硬性边界

Pull requests that add any of the following **will be rejected**, because they
push the project outside the risk boundary documented in `LEGAL.md`:

以下 PR 一律拒绝，因为它们会把项目推出 `LEGAL.md` 划定的风险边界：

- site-specific parsers, extractors, or API documentation
  （站点专属解析器、抽取器、接口文档）
- signature reverse engineering, protocol rewriting, or client hooking
  （签名逆向、协议改写、客户端 Hook）
- anything that assists with paid / members-only / region-locked content
  （任何协助获取付费、会员、限区内容的实现）
- live-stream recording, DRM circumvention, or decryption of protected streams
  （直播录制、DRM 绕过、受保护流解密）
- bundling or vendoring third-party binaries into the repository
  （把第三方二进制打包进仓库）
- multi-user accounts, public library sharing, or online transcoding
  （多用户账号、公开库共享、在线转码）
- telemetry, analytics, or any outbound transmission of local data
  （遥测、分析、任何本地数据外发）

The right way to add support for a new site is to make sure the **external
download engine** handles it. Do not add site knowledge here.

支持新站点的正确做法是让**外部下载引擎**去处理，而不是在这里加入站点知识。

## Style / 风格

- **Backend**: Python standard library only. No third-party imports.
- **Frontend**: vanilla HTML/CSS/JS, no build step, no external assets,
  no CDN links. One file (`index.html`).
- **i18n**: every user-visible string must exist in **both** `zh` and `en`
  in the `I18N` table. No hard-coded Chinese in markup or logic.
- **Bilingual correctness**: switching language must leave **zero** untranslated
  user-visible strings. Placeholders included.
- **Comments** may be in either language; user-visible text may not.

## Before you push / 提交前必做

```bash
# 1. syntax gates
python3 -m py_compile server.py
# 前端: 抽出 <script> 块做语法检查
sed -n '/<script>/,/<\/script>/p' index.html | sed '1d;$d' > /tmp/check.js
node --check /tmp/check.js

# 2. self test (70 assertions, no network)
python3 selftest.py

# 3. regenerate the self-contained installer
node sync_install.mjs
```

`install.sh` is **generated** — never edit it by hand.

## Commit messages

Short imperative subject, e.g. `player: fix chapter marker offset on reload`.
