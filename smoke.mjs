// smoke.mjs —— 前端加载期冒烟测试
// 背景: 少写一行 const 就能让整个 <script> 抛 ReferenceError, 页面全白,
//       而 node --check 只查语法, 查不到这个。2026-10-21 就这么炸过 3 次。
// 做法: 用极简 DOM 桩把 index.html 里的脚本真跑一遍, 谁在加载期抛错就报谁。
// 用法: node smoke.mjs   (退出码 0 = 干净, 1 = 有加载期异常)
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const base = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(base, 'index.html'), 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.error('index.html 里找不到 <script> 块'); process.exit(1); }
const code = m[1];

const errors = [];
const warnings = [];

/* ── 极简 DOM 桩: 任何 id 都返回一个万能假元素 ── */
function makeEl(tag = 'div') {
  const store = {};
  const el = {
    tagName: tag.toUpperCase(),
    style: new Proxy({ setProperty() {}, removeProperty() {}, getPropertyValue: () => '' },
      { get: (t, k) => (k in t ? t[k] : (t[k] ?? '')), set: (t, k, v) => (t[k] = v, true) }),
    dataset: {},
    classList: {
      _s: new Set(),
      add(...c) { c.forEach(x => this._s.add(x)); },
      remove(...c) { c.forEach(x => this._s.delete(x)); },
      toggle(c, f) { f ? this._s.add(c) : this._s.delete(c); },
      contains(c) { return this._s.has(c); }
    },
    children: [], childNodes: [], value: '', innerHTML: '', textContent: '',
    _handlers: {},
    addEventListener(ev, fn) { (this._handlers[ev] ||= []).push(fn); },
    removeEventListener() {}, dispatchEvent() { return true; },
    setAttribute() {}, removeAttribute() {}, getAttribute() { return null; },
    appendChild(c) { this.children.push(c); return c; },
    removeChild(c) { return c; },
    insertBefore(c) { this.children.push(c); return c; },
    remove() {}, focus() {}, blur() {}, click() {},
    querySelector() { return makeEl(); }, querySelectorAll() { return []; },
    getBoundingClientRect() { return { left: 0, top: 0, width: 320, height: 240, right: 320, bottom: 240, x: 0, y: 0 }; },
    cloneNode() { return makeEl(tag); },
    contains() { return false; },
    closest() { return null; },
    matches() { return false; },
    scrollIntoView() {},
    play() { return Promise.resolve(); }, pause() {}, load() {}
  };
  // 未知属性访问 -> 返回一个万能函数(避免桩自己先炸)
  return new Proxy(el, {
    get(t, k) {
      if (k in t) return t[k];
      if (typeof k === 'symbol') return undefined;
      return (...a) => (k === 'getBoundingClientRect' ? t.getBoundingClientRect() : undefined);
    },
    set(t, k, v) { t[k] = v; return true; }
  });
}

/* 真·内存版 localStorage: 空的时候照样返回 null(冷启动路径不变),
   但写进去能读回来 —— 「继续观看」的回归测试要靠它 */
function makeLS() {
  const m = new Map();
  return {
    getItem: k => (m.has(String(k)) ? m.get(String(k)) : null),
    setItem: (k, v) => m.set(String(k), String(v)),
    removeItem: k => m.delete(String(k)),
    clear: () => m.clear(),
    key: i => [...m.keys()][i] ?? null,
    get length() { return m.size; }
  };
}
const __els = {};      // 同一个 id 永远拿到同一个假元素(不然写完读不回来)

const doc = {
  getElementById: (id) => (__els[id] ||= makeEl()),
  querySelector: () => makeEl(),
  querySelectorAll: () => [],
  createElement: (t) => makeEl(t),
  createTextNode: (t) => ({ textContent: t }),
  body: makeEl('body'),
  head: makeEl('head'),
  documentElement: makeEl('html'),
  addEventListener() {}, removeEventListener() {},
  createRange: () => ({ setStart() {}, setEnd() {}, selectNodeContents() {} })
};

const sandbox = {
  console: { log() {}, warn: (...a) => warnings.push(a.join(' ')), error: (...a) => warnings.push(a.join(' ')), info() {}, debug() {} },
  document: doc,
  addEventListener() {}, removeEventListener() {},   // 全局级监听(window.addEventListener)
  dispatchEvent() { return true; },
  navigator: { userAgent: 'node-smoke', language: 'zh-CN', mediaSession: { metadata: null, setActionHandler() {} }, share() {} },
  location: { href: 'http://127.0.0.1:8790/', protocol: 'http:', host: '127.0.0.1:8790', origin: 'http://127.0.0.1:8790', pathname: '/', search: '', hash: '' },
  history: { pushState() {}, replaceState() {} },
  localStorage: makeLS(),
  sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  window: null,
  self: null,
  fetch: (url) => {
    const u = String(url);
    // 按真实接口形状给桩, 不然会造出"代码有 bug"的假象
    let body = {};
    if (/\/api\/(tasks|dupes|queue\/items)/.test(u)) body = [];
    else if (/\/api\/lib/.test(u)) body = { videos: [], loose: [] };
    else if (/\/api\/queue(\?|$)/.test(u)) body = { items: [] };
    else if (/\/api\/tags/.test(u)) body = { tags: {}, fav: 0 };
    else if (/\/api\/health/.test(u)) body = { ok: true, bad: [] };
    return Promise.resolve({
      ok: true, status: 200, headers: { get: () => null },
      json: () => Promise.resolve(body), text: () => Promise.resolve(''),
      blob: () => Promise.resolve(new Uint8Array())
    });
  },
  setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
  requestAnimationFrame: () => 0, cancelAnimationFrame() {},
  matchMedia: () => ({ matches: false, addEventListener() {}, addListener() {} }),
  getComputedStyle: () => ({ getPropertyValue: () => '' }),
  performance: { now: () => 0 },
  crypto: { getRandomValues: (a) => a },
  URL, URLSearchParams,
  Blob: globalThis.Blob || function () {}, File: globalThis.File || function () {},
  FileReader: function () {}, FormData: function () {},
  Headers: globalThis.Headers || function () {},
  Request: globalThis.Request || function () {}, Response: globalThis.Response || function () {},
  AbortController, TextEncoder, TextDecoder, Image: function () { return makeEl('img'); },
  Audio: function () { return makeEl('audio'); },
  Event: function () {}, CustomEvent: function () {},
  MutationObserver: function () { return { observe() {}, disconnect() {} }; },
  ResizeObserver: function () { return { observe() {}, disconnect() {} }; },
  IntersectionObserver: function () { return { observe() {}, disconnect() {} }; },
  MediaMetadata: function () {},
  alert() {}, confirm: () => true, prompt: () => null,
  atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
  parseInt, parseFloat, isNaN, isFinite, encodeURIComponent, decodeURIComponent,
  structuredClone: (o) => JSON.parse(JSON.stringify(o ?? null)),
  queueMicrotask: (f) => f(),
  Intl, Date, Math, JSON, Promise, Map, Set, WeakMap, WeakSet, Symbol, RegExp, Error, TypeError, RangeError, Object, Array, String, Number, Boolean, Proxy, Reflect, BigInt, undefined
};
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;

process.on('unhandledRejection', (e) => { errors.push('unhandledRejection: ' + (e && e.message ? e.message : e)); });

try {
  vm.createContext(sandbox);
  vm.runInContext(code, sandbox, { filename: 'index.html<script>', timeout: 20000 });
} catch (e) {
  errors.push(`${e.name}: ${e.message}${e.stack ? '  @ ' + String(e.stack).split('\n')[1] : ''}`);
}

// 等一拍, 让 loadLib() 之类的异步初始化跑起来
await new Promise(r => setTimeout(r, 300));

if (errors.length) {
  console.log('❌ 加载期异常 ' + errors.length + ' 处:');
  errors.forEach(e => console.log('  ' + e));
  process.exit(1);
}
console.log('✅ 加载期无异常(脚本跑通, 桩环境)');
if (warnings.length) {
  console.log('  (控制台警告 ' + warnings.length + ' 条, 桩环境噪音可忽略)');
}
/* ═══ 回归: 「继续观看」卡片 ═══
   旧 bug(用户报的): 卡片按 **pos 秒数最大** 选, 上次看 40 分钟的老片永远压过
   今天看 2 分钟的新片 → "继续播放不是前一次的, 而是好几次前的"。
   现在按观看时间戳选, 看完的跳过。这几条断言就是钉住这个行为。 */
const LS = sandbox.localStorage;
const bad = [];
let cnt = 0;
const check = (name, got, want) => {
  cnt++;
  if (got !== want) bad.push(name + ' → ' + JSON.stringify(got) + ' (期望 ' + JSON.stringify(want) + ')');
};
const setLib = arr => vm.runInContext('LIB = ' + JSON.stringify({ videos: arr, loose: [] }), sandbox);
setLib([
  { folder: 'a', title: 'A-old', parts: [{ p: 1, file: 'P1.mp4' }] },
  { folder: 'b', title: 'B-new', parts: [{ p: 1, file: 'P1.mp4' }] },
  { folder: 'c', title: 'C-done', parts: [{ p: 1, file: 'P1.mp4' }] }
]);
const now = Date.now();
const card = () => { sandbox.renderResume(); return __els.resumeSlot.innerHTML; };

LS.setItem('take_hist_v1', JSON.stringify([
  { r: 'b/P1.mp4', t: 120, d: 1800, at: now - 60000 },
  { r: 'a/P1.mp4', t: 2400, d: 3600, at: now - 3 * 86400000 }
]));
check('最近看的赢, 不是秒数最大', card().includes('B-new'), true);
check('卡片显示百分比', card().includes('7%'), true);
check('卡片有进度细线', card().includes('class="rprog"'), true);

LS.setItem('take_hist_v1', JSON.stringify([
  { r: 'c/P1.mp4', t: 1795, d: 1800, at: now },
  { r: 'a/P1.mp4', t: 2400, d: 3600, at: now - 86400000 }
]));
check('看完的自动跳过', card().includes('A-old'), true);

LS.setItem('take_hist_v1', JSON.stringify([{ r: 'c/P1.mp4', t: 1795, d: 1800, at: now }]));
check('全看完 = 卡片空', card().trim(), '');

LS.setItem('take_hist_v1', '[]');
sandbox.savePos('a/P1.mp4', 400, 1200);
sandbox.savePos('b/P1.mp4', 90, 600);
const h = JSON.parse(LS.getItem('take_hist_v1'));
check('账本按新到旧', h.map(x => x.r).join(','), 'b/P1.mp4,a/P1.mp4');
check('老进度键照写', LS.getItem('take_pos_b/P1.mp4'), '90');
sandbox.savePos('b/P1.mp4', 300, 600);
const h2 = JSON.parse(LS.getItem('take_hist_v1'));
check('同一集只留一条', h2.filter(x => x.r === 'b/P1.mp4').length, 1);
check('进度刷新到 300', h2[0].t, 300);

LS.setItem('take_hist_v1', '[]');
LS.setItem('take_pos_c/P1.mp4', '500');
check('空账本+旧键 = 兜底仍出卡', card().includes('C-done'), true);

/* 老用户升级路径: 没有账本键, 只有旧进度键 → 自动搬进账本, 卡片不能空掉 */
LS.removeItem('take_hist_v1');
LS.setItem('take_pos_a/P1.mp4', '900');
check('旧进度键自动搬进账本', card().includes('A-old'), true);
check('搬完账本真写进去了', (JSON.parse(LS.getItem('take_hist_v1')) || []).length, 3);

if (bad.length) {
  console.log('❌ 继续观看 失败 ' + bad.length + '/' + cnt + ':');
  bad.forEach(b => console.log('  ' + b));
  process.exit(1);
}
console.log('✅ 继续观看 ' + cnt + ' 项全过');

process.exit(0);
