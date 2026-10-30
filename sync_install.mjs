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
OLD=~/decache
echo "════ 1/4 依赖 ════"
# 死镜像自愈: librehat 等镜像仓库停在 2021, 拉新版 ffmpeg 却拉不到配套 libplacebo → 链接断裂
if grep -rq "termux.librehat.com" "$PREFIX/etc/apt/sources.list" "$PREFIX/etc/apt/sources.list.d/" 2>/dev/null; then
  sed -i 's|termux.librehat.com|packages.termux.dev|g' "$PREFIX/etc/apt/sources.list" "$PREFIX/etc/apt/sources.list.d/"* 2>/dev/null
  echo "  ✓ 检测到过时镜像(librehat), 已切回官方源"
fi
pkg update -y >/dev/null 2>&1 || pkg update -y
# 半残依赖自愈: 部分升级留下的 broken 状态全量补齐, 失败不中断安装
pkg upgrade -y >/dev/null 2>&1 || apt-get -f install -y >/dev/null 2>&1 || true
pkg install -y python ffmpeg termux-api || {
  echo "  ⚠ 依赖装失败, 尝试修复断裂依赖后重试..."
  apt-get -f install -y || true
  pkg install -y python ffmpeg termux-api
}
# nodejs: yt-dlp 解析部分站点(尤其 YouTube)需要 JS runtime, 缺了会报解析失败
command -v node >/dev/null 2>&1 || pkg install -y nodejs || echo "  ⚠ nodejs 没装上(某些站点解析可能失败)"
echo "════ 2/4 引擎 ════"
pkg install -y yt-dlp 2>/dev/null || pip install -q --upgrade yt-dlp || true
pip install -q --upgrade you-get || true
pip install -q --upgrade yutto || true
command -v yt-dlp >/dev/null 2>&1 && echo "  ✓ yt-dlp 就绪" || echo "  ⚠ yt-dlp 没装上(可改 config.ini 的 engine)"
echo "════ 3/4 面板文件(保留媒体库/配置/已下载内容) ════"
mkdir -p "$APP" ~/.shortcuts ~/.termux/boot
# 旧目录迁移(一次性): 把配置/媒体库搬到新目录, 避免升级后新旧并存
if [ -d "$OLD" ] && [ ! -f "$APP/config.ini" ]; then
  for f in config.ini library.json playlist.json tasks.json cookies.txt; do
    [ -f "$OLD/$f" ] && cp -a "$OLD/$f" "$APP/$f" && echo "  迁移 $f"
  done
  [ -d "$OLD/covers" ] && cp -a "$OLD/covers" "$APP/" 2>/dev/null && echo "  迁移 covers/"
fi
`;

const tail = `
echo "════ 4/4 完成 ════"
# 开机自启(Termux:Boot): 装了 Termux:Boot 就自动配, 没装就提示一句
if pm list packages 2>/dev/null | grep -q "com.termux.boot"; then
  cp "$APP/boot.sh" ~/.termux/boot/decache-boot.sh && chmod +x ~/.termux/boot/decache-boot.sh
  echo "  ✓ 已配置开机自启(~/.termux/boot/decache-boot.sh)"
else
  echo "  · 想开机自启: 装 Termux:Boot(F-Droid), 再跑一次本脚本"
fi
# 桌面小部件(Termux:Widget): 点一下就开面板
if pm list packages 2>/dev/null | grep -q "com.termux.widget"; then
  mkdir -p ~/.shortcuts
  printf '%s\\n' '[{"name":"Decache 媒体库","cmd":"bash ~/decache/start.sh","icon":"terminal","bg":"#09090B","terms":["bash","-c","bash ~/decache/start.sh; sleep 1; termux-open http://127.0.0.1:8765"]}]' > ~/.shortcuts/decache.json
  echo "  ✓ 已生成桌面小部件(Termux:Widget 里可见)"
fi
echo ""
echo "启动:   bash ~/decache/start.sh"
echo "升级位: ~/decache  (配置与媒体库已保留)"
echo "手机装桌面: 浏览器打开后 → 菜单「添加到主屏幕」"
echo "自启:   Termux:Boot + Termux:Widget(F-Droid) → 重跑一次 install.sh"
`;

const out = [head];
for (const [name, eof] of files) {
  out.push(`cat > "$APP"/${name} <<'${eof}'\n${read(name)}${eof}\n`);
}
if (icons.length) {
  out.push(`mkdir -p "$APP/icons"`);
  for (const ic of icons) {
    out.push(`cat > "$APP/icons/${ic.name}.b64" <<'I${ic.name}B64'\n${ic.b64}\nI${ic.name}B64\nbase64 -d "$APP/icons/${ic.name}.b64" > "$APP/icons/${ic.name}" 2>/dev/null && rm -f "$APP/icons/${ic.name}.b64"`);
  }
}
out.push(tail);

writeFileSync(join(base, 'install.sh'), out.join('\n'), 'utf8');
console.log(`install.sh 重新生成: ${files.length} 个文件已内嵌`);
