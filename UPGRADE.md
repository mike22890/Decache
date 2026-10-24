# Decache v6.18 · 全方面体检与升级报告 (2026-10-24)

## 一、体检结论
底子很好: 线程模型正确、子进程全 list 参数、出站全带超时、删除双保险、并发写单锁。
selftest / frontcheck 基线即全过。本版动的东西全部可回退(纯增量)。

## 二、修复 (2 项, 均已活体验证)
| # | 问题 | 严重度 | 修法 | 验证 |
|---|---|---|---|---|
| 1 | 自定义标签存储型 XSS: /api/tag 零校验 + 前端裸插 innerHTML | 低危(本机/LAN) | 服务端拒含 `<>"'&` 的 tag(400); 前端渲染改 `esc()` | 活体 POST `<script>` → 400 ✅ |
| 2 | HTTP/1.0 无 keep-alive, 轮询每次新建 TCP | 性能 | handler 加 `protocol_version="HTTP/1.1"` | 13 出口 CL 全核; 同连接两次 GET 复用 ✅ |

## 三、UI v7 · 五主题系统 (上版已交付, 本版合入)
- mono / refactor / retro / 8bit / pipboy, 各带亮/暗双色板, data-theme 三态兼容
- 纯 CSS 变量换肤, 业务 JS 零改动; 动效尊重 prefers-reduced-motion
- 播放器进度条/字幕颜色全部主题化

## 四、复查过没问题的"嫌疑犯"(省得下次重查)
- tagpop 的 `<i>`/凭据行/placeholder SVG/toast/任务标题: 转义到位或 textContent
- shell=True: 仅出现在注释里; 日志: 内存封顶 200 条
- placeholder_svg: 文本节点转义 `<` 和 `&` 已足够
- 13 个响应出口: 12 个带 Content-Length, 唯一的 304 按 RFC 本来就该无体

## 五、回退方法
- 主题系统: 删 index.html 里 `UI v7 · 主题包与动效层` 注释段 + `applyUiTheme` 段即可, 前端其余无依赖
- 修复①②: git revert 或按 HANDOVER.md §12 反向操作
