# Decache UI v8 · 主题系统说明

## 设计依据 (2026-10-24 调研)
- **Glassmorphism 2.0 / 液态玻璃**: 2026 主流, 但规范要求可访问降级(弱对比别依赖透明层)
- **Catppuccin / Tokyo Night**: 程序员社区常年人气配色, 柔和低疲劳
- **Synthwave 复古未来** (StyleShift 流派规范): 深紫黑底(绝不纯黑)、≤3 个霓虹色、
  正文薰衣草紫灰(绝不纯白)、发光只给标题和主按钮、2px 锐角、透视网格+落日为签名场景
- **Vercel Geist 纪律**: shadow-as-border(box-shadow 0 0 0 1px)、圆角 6/8/12、
  字重 ≤600、小标签全大写宽字距、装饰性渐变禁用

## v7 → v8 变化
- refactor → **geist**: 从"换了 indigo 的单色"升级为真 Vercel 纪律(描边阴影/字距/圆角体系)
- 8bit 退役 → **synthwave**: 像素风救不回来, 复古未来是更强的方向(存档值自动迁移)
- 新增 **catppuccin**: Mocha(暗)/Latte(亮) 官方色板, chips 变胶囊
- 每主题补了"组件语言"和 synthwave 的"场景层"(落日/地平线/网格, 纯渐变合成层)
- v7 存档迁移: take_ui 里的 refactor/8bit 自动映射到 geist/synthwave

## 主题清单
| data-ui | 名称 | 基因 |
|---|---|---|
| mono | 单色(默认) | 原版 v6 不动 |
| geist | 极简 | Vercel 式黑白灰+单一蓝 |
| catppuccin | 柔和 | Mocha/Latte 官方色板 |
| synthwave | 复古未来 | 品红/青霓虹, 落日网格场景 |
| retro | 复古 | Win95 硬阴影 |
| pipboy | 终端 | 绿磷光 CRT 扫描线 |

## 结构 (index.html 尾部 v8 段)
1. 令牌层: `--acc --acc-tx --ring --sh --edge --font` (--edge = shadow-as-border)
2. 主题层: 暗 `[data-ui]` + 亮 `[data-ui][data-theme=light]` + 系统亮 media 三件套
3. 场景层: `body::before`(z-index:-1, 主题背景画, 不随滚动重绘)
4. 组件层: 通用重指向, mono 因令牌默认值视觉不变
5. 动效层: transform/opacity only, prefers-reduced-motion 一刀切

## 加新主题 (3 步)
1. 抄一个主题块改名改色值
2. (可选) 加组件语言覆盖 + body::before 场景层
3. 设置页 chips 加一行 + i18n 两个键。完事。

## 预览
preview.html 免启动直接看 6 主题 × 3 明暗。
