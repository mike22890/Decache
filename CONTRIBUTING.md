# Contributing / 参与开发

**中文** — 感谢你来帮忙。这个项目刻意做得小、零依赖，请保持这样。

**English** — Thanks for helping. This project is deliberately small and
dependency-free — please keep it that way.

## Hard boundaries / 硬性边界

**中文** — 引入下列任何一项的 PR 一律拒绝，因为它们会把项目推出 `LEGAL.md` 划定的风险边界：

- 站点专属解析器、抽取器或接口文档 / site-specific parsers, extractors, or API documentation
- 签名逆向、协议改写或客户端 Hook / signature reverse engineering, protocol rewriting, or client hooking
- 任何协助获取付费、会员、限区内容的实现 / anything that assists with paid / members-only / region-locked content
- 直播录制、DRM 绕过、受保护流解密 / live-stream recording, DRM circumvention, or decryption of protected streams
- 把第三方二进制打包进仓库 / bundling or vendoring third-party binaries into the repository
- 多用户账号、公开库共享、在线转码 / multi-user accounts, public library sharing, or online transcoding
- 遥测、分析，或任何本地数据外发 / telemetry, analytics, or any outbound transmission of local data

**English** — Pull requests that add any of the above **will be rejected**,
because they push the project outside the risk boundary documented in
`LEGAL.md`.

**中文** — 支持新站点的正确做法是让**外部下载引擎**去处理，而不是在这里加入站点知识。

**English** — The right way to add support for a new site is to make sure the
**external download engine** handles it. Do not add site knowledge here.

## Style / 风格

**中文**

- **后端**：只用 Python 标准库，不引第三方包
- **前端**：原生 HTML/CSS/JS，无构建步骤、无外部资源、无 CDN 链接，全部在 `index.html` 一个文件里
- **i18n**：每条用户可见文案必须在 `I18N` 表里**中英都有**，标记和逻辑里不许硬编码中文
- **双语正确性**：切换语言后，用户可见文案**零漏译**（占位符也算）
- 注释可以用任意语言；用户可见文案不行

**English**

- **Backend**: Python standard library only. No third-party imports.
- **Frontend**: vanilla HTML/CSS/JS, no build step, no external assets, no CDN
  links. One file (`index.html`).
- **i18n**: every user-visible string must exist in **both** `zh` and `en` in
  the `I18N` table. No hard-coded Chinese in markup or logic.
- **Bilingual correctness**: switching language must leave **zero**
  untranslated user-visible strings. Placeholders included.
- **Comments** may be in either language; user-visible text may not.

## Before you push / 提交前必做

**中文** — 跑完这三步再推：

```bash
# 1. 语法闸
python3 -m py_compile server.py selftest.py chaos_test.py fake_yt_dlp_test.py
# 前端: 抽出 <script> 块做语法检查
sed -n '/<script>/,/<\/script>/p' index.html | sed '1d;$d' > /tmp/check.js
node --check /tmp/check.js

# 2. 三套离线自测(共 278 条断言, 不联网)
python3 selftest.py          # 190 条: 端点/白名单/数据安全/封面/批量/清晰度
python3 chaos_test.py        # 71 条: 脏数据/并发/死锁/穿越/注入/SSRF
python3 fake_yt_dlp_test.py  # 17 条: 假引擎端到端

# 3. 前端静态闸 + 加载期冒烟(少写一行 const 就能让整页 JS 死掉, 这两道闸专治它)
node frontcheck.mjs   # 7 道: id 悬空/未声明标识符/模板串泄漏/语法/图标/重名函数/变量遮蔽
node smoke.mjs        # DOM 桩里真跑一遍脚本, 抓加载期异常

# 4. 重新生成自包含安装器
node sync_install.mjs
```

**English** — Run all of these before you push:

```bash
python3 -m py_compile server.py selftest.py chaos_test.py fake_yt_dlp_test.py
sed -n '/<script>/,<\/script>/p' index.html | sed '1d;$d' > /tmp/check.js
node --check /tmp/check.js
python3 selftest.py
python3 chaos_test.py
python3 fake_yt_dlp_test.py
node frontcheck.mjs
node smoke.mjs
node sync_install.mjs
```

`install.sh` 是**生成物**，永远不要手改。
`install.sh` is **generated** — never edit it by hand.

## Commit messages / 提交信息

**中文** — 简短祈使句主题，例如 `player: fix chapter marker offset on reload`。

**English** — Short imperative subject, e.g. `player: fix chapter marker offset on reload`.
