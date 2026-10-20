// make-icons.mjs — 生成 PWA 图标(纯 Node, 无依赖): 深底 + 取景框 + 播放三角
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
  const bg = [9, 9, 11];
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
  // 取景框四角(视频感)
  const fw = Math.max(2, Math.round(S * 0.035));
  const bx = pad + S * 0.16, by = pad + S * 0.20;
  const bw = S - 2 * bx, bh = S - 2 * by;
  const arm = bw * 0.24;
  const rect = (x0, y0, x1, y1) => {           // 坐标取整: put() 要整数索引
    for (let y = Math.floor(y0); y < Math.ceil(y1); y++)
      for (let x = Math.floor(x0); x < Math.ceil(x1); x++) put(x, y, fg[0], fg[1], fg[2], 255);
  };
  rect(bx, by, bx + arm, by + fw); rect(bx, by, bx + fw, by + arm);
  rect(bx + bw - arm, by, bx + bw, by + fw); rect(bx + bw - fw, by, bx + bw, by + arm);
  rect(bx, by + bh - fw, bx + arm, by + bh); rect(bx, by + bh - arm, bx + fw, by + bh);
  rect(bx + bw - arm, by + bh - fw, bx + bw, by + bh); rect(bx + bw - fw, by + bh - arm, bx + bw, by + bh);
  // 播放三角(居中)
  const triL = S * 0.36, triR = S * 0.60, triT = S * 0.36, triB = S * 0.64;
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
