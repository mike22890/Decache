// make-icons.mjs — 生成 PWA 图标(纯 Node, 无依赖): 深底 + 缓存槽 + 播放键
// (和顶栏 logo 同一个图形: U 形槽里躺一个粉色播放三角 = 媒体存在本地)
// 用法: node tools/make-icons.mjs
import { writeFileSync, mkdirSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const base = join(dirname(fileURLToPath(import.meta.url)), '..');
const outDir = join(base, 'icons');
mkdirSync(outDir, { recursive: true });

const crcTable = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(w, h, rgba) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;                    // filter: none
    rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function drawIcon(size, { maskable = false } = {}) {
  const buf = Buffer.alloc(size * size * 4);
  const put = (x, y, r, g, b, a) => {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    const i = (y * size + x) * 4;
    const sa = a / 255;
    buf[i] = Math.round(buf[i] * (1 - sa) + r * sa);
    buf[i + 1] = Math.round(buf[i + 1] * (1 - sa) + g * sa);
    buf[i + 2] = Math.round(buf[i + 2] * (1 - sa) + b * sa);
    buf[i + 3] = Math.max(buf[i + 3], a);
  };
  const S = size;
  const pad = maskable ? S * 0.18 : 0;          // maskable 需要安全区
  const radius = maskable ? 0 : S * 0.22;        // 圆角
  const bg = [13, 13, 16];
  const fg = [251, 114, 153];                     // 品牌粉
  // 背景(圆角矩形)
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    let inside = true;
    if (radius > 0) {
      const cx = Math.min(Math.max(x, radius), S - radius);
      const cy = Math.min(Math.max(y, radius), S - radius);
      const d = Math.hypot(x - cx, y - cy);
      if (d > radius) inside = false;
    }
    if (inside) put(x, y, bg[0], bg[1], bg[2], 255);
  }
  const rect = (x0, y0, x1, y1, c) => {       // 坐标取整: put() 要整数索引
    for (let y = Math.floor(y0); y < Math.ceil(y1); y++)
      for (let x = Math.floor(x0); x < Math.ceil(x1); x++) put(x, y, c[0], c[1], c[2], 255);
  };
  // ── 缓存槽(U 形): 左右两壁 + 底 ──
  const w = Math.max(2, Math.round(S * 0.075));           // 线宽
  const ux0 = pad + S * 0.20, ux1 = S - pad - S * 0.20;  // 槽左右
  const uTop = pad + S * 0.355, uBot = pad + S * 0.735;  // 槽开口/底
  const white = [250, 250, 250];
  rect(ux0, uTop, ux0 + w, uBot - w * 0.6, white);       // 左壁
  rect(ux1 - w, uTop, ux1, uBot - w * 0.6, white);       // 右壁
  rect(ux0 + w * 0.4, uBot - w, ux1 - w * 0.4, uBot, white);  // 底
  // ── 播放键(粉色三角, 躺在槽里) ──
  const triL = pad + S * 0.375, triR = pad + S * 0.625;
  const triT = uTop + S * 0.055, triB = uBot - S * 0.095;
  for (let y = Math.floor(triT); y < triB; y++) {
    const t = (y - triT) / (triB - triT);
    const xEnd = triL + (triR - triL) * t;
    for (let x = Math.floor(triL); x < xEnd; x++) put(x, y, fg[0], fg[1], fg[2], 255);
  }
  return buf;
}

for (const [name, size, opt] of [
  ['icon-192.png', 192, {}],
  ['icon-512.png', 512, {}],
  ['icon-maskable-512.png', 512, { maskable: true }],
  ['apple-touch-icon.png', 180, {}],
]) {
  writeFileSync(join(outDir, name), png(size, size, drawIcon(size, opt)));
  console.log('  ' + name + ' (' + size + 'px)');
}
console.log('图标已生成 → icons/');
