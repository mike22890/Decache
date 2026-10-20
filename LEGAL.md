# Legal Notice / 法律声明

> This document is a project policy, **not legal advice**.
> 本文件是项目政策，**不是法律意见**。

## 1. What this project is / 本项目是什么

decache is a **self-hosted local media library and video player**. It runs on
your own device, listens only on `127.0.0.1`, stores everything locally, and
ships no accounts, no telemetry, and no cloud services.

decache 是一个**自托管的本地媒体库与视频播放器**。它只在你自己的设备上运行，
只监听 `127.0.0.1`，所有数据留在本地，没有账号体系、没有遥测、没有云服务。

## 2. What it does not do / 本项目不做什么

decache contains **no site-specific parser, extractor, signature reverse
engineering, client hooking, or content-discovery logic**. All media acquisition
is delegated to an **external, general-purpose download engine** (by default
[yt-dlp](https://github.com/yt-dlp/yt-dlp)) that the user installs and configures
on their own machine.

decache **不包含**任何站点专属的解析器、抽取器、签名逆向、客户端 Hook 或内容发现逻辑。
所有媒体获取能力都委托给用户自行安装配置的**外部通用下载引擎**（默认 yt-dlp）。

Specifically, this project does not and will not:

- ship, vendor, or bundle any third-party binary in its releases;
- reverse-engineer or bypass any platform's technical protection measures;
- hook or modify third-party clients;
- collect, document, or redistribute platform API signatures or parameter
  structures;
- assist in obtaining paid, members-only, region-locked, or otherwise
  protected content;
- record or capture live streams, paid courses, or DRM-protected media;
- provide a multi-user service, public library sharing, or online transcoding.

本项目不会也不会:

- 在 Release 中打包或分发任何第三方二进制文件;
- 逆向或绕过任何平台的技术保护措施;
- Hook 或修改第三方客户端;
- 收集、记录或再分发平台接口签名与参数结构;
- 协助获取付费、会员、限区或其他受保护内容;
- 录制直播、付费课程或 DRM 保护内容;
- 提供多用户服务、公开库共享或在线转码。

## 3. Not affiliated / 非官方声明

decache is **not affiliated with, endorsed by, sponsored by, or associated with**
any content platform, video service, or their operators. All product names,
logos, and trademarks referenced in the documentation belong to their respective
owners and are used for identification only.

decache 与任何内容平台、视频服务及其运营方**无隶属、背书、赞助或关联关系**。
文档中出现的所有产品名称、标识与商标归各自权利人所有，仅用于识别。

## 4. Your responsibility / 使用者责任

This project is provided "as is", without warranty of any kind. **You** are
solely responsible for:

- ensuring you have the right to download and keep any content you obtain;
- complying with the terms of service of the sites you access;
- complying with applicable copyright and anti-circumvention law in your
  jurisdiction;
- keeping your own credentials secure (cookies are stored locally in plaintext
  in your own config file and are never transmitted by this project).

本项目按"现状"提供，不作任何担保。**你**需自行负责：确保你对下载和保留的内容
拥有权利；遵守所访问站点的服务条款；遵守所在司法辖区的著作权与反规避法律；
妥善保管自己的凭据（本项目只在你的本地配置文件中以明文保存 cookie，绝不外传）。

The statement below does **not** transfer any liability to the project
maintainers, and does not constitute legal advice:

> 仅供个人学习研究与个人使用。使用者应自行确保其行为合法合规，并自行承担全部责任。
> 该声明不转移使用者的法律责任，也不构成法律意见。

## 5. Copyright / 版权

Respect the rights of content creators. Prefer official channels. If you
believe content hosted or distributed through this project's optional
external-engine workflow infringes your rights, use the official complaint
channel of the platform concerned — or contact the maintainers below.

尊重内容创作者的权利。请优先使用官方渠道。如果你认为经由本项目可选的外部引擎
工作流获取或分发的内容侵犯了你的权利，请使用相关平台的官方投诉渠道，或联系
下面的维护者。

## 6. Infringement reports / 侵权举报

Reports of copyright infringement concerning this **repository** (source code,
documentation, or assets committed here) should be sent to:

```
decache-legal@example.com
```

We commit to acknowledging every report within **48 hours**, and to acting on
substantiated reports within **7 days** — including removing the offending
material, or disabling the repository if necessary.

针对**本仓库**（源代码、文档或已提交的资源）的版权侵权举报请发送至上述邮箱。
我们承诺在 **48 小时**内确认每一条举报，并在 **7 天**内对经核实的举报采取行动
（包括移除侵权内容，必要时停用仓库）。

Note: decache is not the custodian of any third-party download engine. Reports
concerning third-party software should be directed to that project's own
maintainers.

注：decache 不是任何第三方下载引擎的托管方；涉及第三方软件的举报请直接联系其维护者。
