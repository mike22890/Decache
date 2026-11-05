#!/usr/bin/env node
/**
 * sync_install.mjs — 重新生成自包含安装器 install.sh
 * ---------------------------------------------------------------
 * 痛点: install.sh 用 heredoc 内嵌全部文件, 过去靠手工粘贴同步,
 * Kimi 时代已经把 start.bat 重复追加了 6 遍(后段覆盖前段, 中间全是尸体)。
 * 本脚本从当前文件一键重组, 以后改任何文件跑一遍即可:
 *   node sync_install.mjs
 * 顺序: server.py → index.html → start.sh → start.bat → HANDOVER.md
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const base = dirname(fileURLToPath(import.meta.url));
const read = f => { const b = readFileSync(join(base, f), 'utf8').replace(/\r\n/g, '\n'); return b.endsWith('\n') ? b.replace(/\n+$/, '\n') : b + '\n'; };

const files = [
  ['server.py',   'PYEOF'],
  ['index.html',  'HTMLEOF'],
  ['start.sh',    'SHEOF'],
  ['boot.sh',     'BOOTEOF'],
  ['start.bat',   'BATEOF'],
  ['selftest.py', 'PYEOF2'],
  ['HANDOVER.md', 'MDEOF'],
  ['manifest.json', 'MJSON'],
  ['sw.js',       'SWEOF'],
];

/* 图标是二进制, heredoc 装不进去 → base64 内嵌, 安装时解码写出 */
const iconDir = join(base, 'icons');
const icons = ['icon-192.png', 'icon-512.png', 'icon-maskable-512.png', 'apple-touch-icon.png']
  .filter(f => existsSync(join(iconDir, f)))
  .map(f => ({
    name: f,
    b64: readFileSync(join(iconDir, f)).toString('base64').replace(/(.{76})/g, '$1\n'),
  }));
if (!icons.length) console.warn('⚠ icons/ 是空的, PWA 图标将缺失(跑 node tools/make-icons.mjs 生成)');

for (const [name, eof] of files) {
  const body = read(name);
  if (body.includes(`\n${eof}\n`) || body.startsWith(`${eof}\n`))
    throw new Error(`${name} 内容里出现了 heredoc 终止符 ${eof}, 换一个标记`);
}

const head = `#!/data/data/com.termux/files/usr/bin/bash
# decache · 一键安装/升级(自包含, Termux)
# 本文件由 sync_install.mjs 生成 — 手工编辑会被下一次同步覆盖
# CRLF self-heal: transfers sometimes rewrite LF as CRLF; heredoc terminators then never match
if grep -q $'\\r' "$0" 2>/dev/null; then
  echo "⚠ CRLF detected (transfer corruption), cleaning and re-executing..."
  tr -d '\\r' < "$0" > "$HOME/.install_clean.sh" && exec bash "$HOME/.install_clean.sh"
fi
set -e; cd ~
APP=~/decache
# v22.1: 原来还有 OLD=~/decache 的"旧目录迁移"块 —— 它和 APP 是同一个目录,
#   cp -a X X 只会报 "are the same file" 然后被 2>/dev/null 吞掉(迁移功能根本不存在)。
#   历史版本从没换过安装目录, 升级天然是原地覆盖(配置/媒体库不动), 整块删掉。
echo "════ 1/4 依赖 ════"
# 死镜像自愈: librehat 等镜像仓库停在 2021, 拉新版 ffmpeg 却拉不到配套 libplacebo → 链接断裂
if grep -rq "termux.librehat.com" "$PREFIX/etc/apt/sources.list" "$PREFIX/etc/apt/sources.list.d/" 2>/dev/null; then
  # v22.1: 目录为空时 glob 不展开 → sed 收到字面路径退出码 2 → set -e 直接杀掉安装器。
  #   改成逐个文件处理 + || true, 不再让这条"自愈"变成杀死安装器的那一刀。
  sed -i 's|termux.librehat.com|packages.termux.dev|g' "$PREFIX/etc/apt/sources.list" 2>/dev/null || true
  for _lf in "$PREFIX"/etc/apt/sources.list.d/*.list; do
    [ -f "$_lf" ] && sed -i 's|termux.librehat.com|packages.termux.dev|g' "$_lf" 2>/dev/null || true
  done
  echo "  ✓ 检测到过时镜像(librehat), 已切回官方源"
fi
# 网络自愈: 主源为空或探测不通 → 自动切清华 TUNA(国内直连快), 不让用户干等 apt 摸死镜像
_m="$PREFIX/etc/apt/sources.list"
[ -s "$_m" ] || { echo "deb https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main stable main" > "$_m"; echo "  ✓ 主源为空, 已写入清华 TUNA 镜像"; }
_src=$(grep -m1 '^deb ' "$_m" 2>/dev/null | sed 's|.*://||; s|/.*||')
if [ -n "$_src" ] && [ "$_src" != "mirrors.tuna.tsinghua.edu.cn" ] && ! curl -sI --connect-timeout 6 --max-time 10 "https://$_src" >/dev/null 2>&1; then
  cp "$_m" "$_m.bak" 2>/dev/null
  echo "deb https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main stable main" > "$_m"
  echo "  ⚠ 原源($_src)探测不通, 已切清华 TUNA 镜像(原配置备份为 sources.list.bak)"
fi
pkg update -y >/dev/null 2>&1 || pkg update -y
# 半残依赖自愈: 部分升级留下的 broken 状态全量补齐, 失败不中断安装
pkg upgrade -y >/dev/null 2>&1 || apt-get -f install -y >/dev/null 2>&1 || true
# v22.1: 补 procps —— start.sh 用 pgrep 判断服务是否活着, 缺了会 3 秒一轮空转
pkg install -y python ffmpeg termux-api procps || {
  echo "  ⚠ 依赖装失败, 尝试修复断裂依赖后重试..."
  apt-get -f install -y || true
  pkg install -y python ffmpeg termux-api procps
}
# nodejs: yt-dlp 解析部分站点(尤其 YouTube)需要 JS runtime, 缺了会报解析失败
command -v node >/dev/null 2>&1 || pkg install -y nodejs || echo "  ⚠ nodejs 没装上(某些站点解析可能失败)"
echo "════ 2/4 引擎 ════"
# v22.1: Termux 官方仓库里的包名是 python-yt-dlp(不是 yt-dlp), 另有 yt-dlp-ejs。
#   yt-dlp 2026.06.09 起解 YouTube 还要 Deno>=2.3 / Node>=22。
pkg install -y python-yt-dlp yt-dlp-ejs deno 2>/dev/null || true
command -v yt-dlp >/dev/null 2>&1 || pip install -q --upgrade yt-dlp || {
  echo "  ❌ yt-dlp 没装上(Termux 包名是 python-yt-dlp, 也可 pip install yt-dlp)"
}
pip install -q --upgrade you-get || true
pip install -q --upgrade yutto || true
if command -v yt-dlp >/dev/null 2>&1; then
  echo "  ✓ yt-dlp 就绪($(yt-dlp --version 2>/dev/null | head -1))"
else
  echo "  ⚠ yt-dlp 没装上(可改 config.ini 的 engine)"
fi
echo "════ 3/4 面板文件(保留媒体库/配置/已下载内容) ════"
mkdir -p "$APP" ~/.shortcuts ~/.termux/boot
`;

const tail = `
echo "════ 4/4 完成 ════"
# 开机自启(Termux:Boot): 装了 Termux:Boot 就自动配, 没装就提示一句
# v22.1: pm 加 timeout —— pm 慢/挂住时会把安装器卡在这一步出不来
if timeout 20 pm list packages 2>/dev/null | grep -q "com.termux.boot"; then
  cp "$APP/boot.sh" ~/.termux/boot/decache-boot.sh && chmod +x ~/.termux/boot/decache-boot.sh
  echo "  ✓ 已配置开机自启(~/.termux/boot/decache-boot.sh)"
else
  echo "  · 想开机自启: 装 Termux:Boot(F-Droid), 再跑一次本脚本"
fi
# 桌面小部件(Termux:Widget): 点一下就开面板
if timeout 20 pm list packages 2>/dev/null | grep -q "com.termux.widget"; then
  mkdir -p ~/.shortcuts
  printf '%s\\n' '[{"name":"Decache 媒体库","cmd":"bash ~/decache/start.sh","icon":"terminal","bg":"#09090B","terms":["bash","-c","bash ~/decache/start.sh; sleep 1; termux-open http://127.0.0.1:8765"]}]' > ~/.shortcuts/decache.json
  echo "  ✓ 已生成桌面小部件(Termux:Widget 里可见)"
fi
# v22.1: Termux:API 是**应用**(com.termux.api), termux-api 只是它的 CLI 包。
#   只装 CLI 不装应用 → wake-lock/notification 全部静默失效, Android 12+ 会杀后台。
if timeout 20 pm list packages 2>/dev/null | grep -q "com.termux.api"; then
  echo "  ✓ Termux:API 应用已装(休眠锁/通知可用)"
else
  echo "  · 想要后台保活: 另装 Termux:API 应用(F-Droid), 再跑一次本脚本"
fi
echo ""
echo "启动:   bash ~/decache/start.sh"
echo "升级位: ~/decache  (配置与媒体库已保留)"
echo "手机装桌面: 浏览器打开后 → 菜单「添加到主屏幕」"
echo "自启:   Termux:Boot + Termux:Widget(F-Droid) → 重跑一次 install.sh"
`;

const out = [head];
for (const [name, eof] of files) {
  // v22.1: 先写 .tmp 再 mv —— 磁盘满/断电/Ctrl-C 时留下的是半截 .tmp,
  //   原来的 server.py 还在(面板至少能起来报错), 而不是被截断的正式文件。
  out.push(`cat > "$APP"/${name}.tmp <<'${eof}'\n${read(name)}${eof}\nmv -f "$APP"/${name}.tmp "$APP"/${name}`);
}
if (icons.length) {
  out.push(`mkdir -p "$APP/icons"`);
  for (const ic of icons) {
    // v22.1: decode 到 .tmp → 校验非空 → 才 mv 到位。
    //   以前 `base64 -d ... > icon.png` 先创建目标, 解码失败就留下 0 字节图标(PWA 图标烂掉),
    //   而且 .b64 也留在盘上。
    out.push(`cat > "$APP/icons/${ic.name}.b64" <<'I${ic.name}B64'\n${ic.b64}\nI${ic.name}B64\nif base64 -d "$APP/icons/${ic.name}.b64" > "$APP/icons/${ic.name}.tmp" 2>/dev/null && [ -s "$APP/icons/${ic.name}.tmp" ]; then mv -f "$APP/icons/${ic.name}.tmp" "$APP/icons/${ic.name}"; rm -f "$APP/icons/${ic.name}.b64"; else echo "  ⚠ 图标 ${ic.name} 解码失败, PWA 图标可能缺失"; rm -f "$APP/icons/${ic.name}.tmp" "$APP/icons/${ic.name}.b64"; fi`);
  }
}
out.push(tail);

writeFileSync(join(base, 'install.sh'), out.join('\n'), 'utf8');
console.log(`install.sh 重新生成: ${files.length} 个文件已内嵌`);
