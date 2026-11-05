// frontcheck.mjs —— 前端静态闸(改完 index.html 必跑, 退出码 0 = 干净)
// 三道闸, 每道都对应踩过的坑:
//   1) id 悬空:  $('x') 引用的 id 在 HTML 里没了 → 整页 JS 静默停摆
//   2) 未声明标识符: 少写一行 const → ReferenceError → 整页 JS 静默停摆
//   3) 模板串泄漏: 纯 HTML 区里出现 ${...} → 界面上直接显示 ${t('x')} 字面量
// 注: 语法闸(node --check)只能查语法, 上面三道它一个都查不出来。
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const base = dirname(fileURLToPath(import.meta.url));
/* v20.0: normalize CRLF (gate-7 regex ate trailing CR on Windows files) */
const src = readFileSync(join(base, "index.html"), "utf8").split(String.fromCharCode(13)+String.fromCharCode(10)).join(String.fromCharCode(10))
/* v22.1: index.html 现在有多个 <script> 块(v21.9 加了诊断浮层)。
   原来只取第一块 → 主脚本 2600 行根本没进闸, 闸4/闸6/闸7 形同虚设。
   现在把所有块拼起来再查 —— 拼接点是 ';' , 语法上等价于多个 script 顺序执行。 */
const _blocks = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
const JS = _blocks.length ? _blocks.join("\n;\n") : src;
let bad = 0;

/* ── 闸 1: id 悬空 ── */
{
  const ids = new Set([...src.matchAll(/\bid="([A-Za-z0-9_-]+)"/g)].map(m => m[1]));
  const used = [...src.matchAll(/\$\('([A-Za-z0-9_-]+)'\)/g)].map(m => m[1]);
  const missing = [...new Set(used.filter(u => !ids.has(u)))];
  if (missing.length) { bad++; console.log('❌ 闸1 id 悬空: ' + missing.join(', ')); }
  else console.log('✅ 闸1 id 悬空: 无 (HTML 定义 ' + ids.size + ' 个 id)');
}

/* ── 闸 2: 未声明标识符 ── */
{
  const js = JS;   // v22.1: 用拼接后的全部 script 块(原来只取第一块 37 行, 主脚本 2600 行根本没进闸)
  const KNOWN = new Set([
    'window','document','console','self','globalThis','navigator','location','history','localStorage','sessionStorage',
    'Object','Array','String','Number','Boolean','Math','JSON','Date','Promise','Set','Map','WeakMap','WeakSet','Symbol',
    'RegExp','Error','TypeError','RangeError','SyntaxError','ReferenceError','Intl','Proxy','Reflect','BigInt',
    'URL','URLSearchParams','Blob','File','FileReader','FormData','Headers','Request','Response','AbortController',
    'TextEncoder','TextDecoder','ArrayBuffer','Uint8Array','Int8Array','Float32Array','Float64Array','DataView',
    'Event','CustomEvent','EventTarget','HTMLElement','HTMLImageElement','HTMLVideoElement','HTMLAudioElement',
    'HTMLCanvasElement','Element','Node','NodeList','MutationObserver','ResizeObserver','IntersectionObserver',
    'Image','Audio','MediaSource','SourceBuffer','XMLHttpRequest','WebSocket','Worker','SharedWorker',
    'fetch','setTimeout','setInterval','clearTimeout','clearInterval','requestAnimationFrame','cancelAnimationFrame',
    'requestIdleCallback','queueMicrotask','structuredClone','crypto','performance','alert','confirm','prompt',
    'parseInt','parseFloat','isNaN','isFinite','encodeURIComponent','decodeURIComponent','encodeURI','decodeURI',
    'escape','unescape','atob','btoa','matchMedia','getComputedStyle','scrollTo','scrollBy','open','close','print',
    'this','arguments','undefined','null','true','false','NaN','Infinity','void','typeof','instanceof','in','of',
    'function','return','if','else','for','while','do','switch','case','break','continue','const','let','var','class',
    'async','await','try','catch','finally','throw','delete','new','yield','super','extends','static','get','set',
    'import','export','default','from','as','keyof','globalThis','MediaMetadata','MediaImage'
  ]);
  // 字符串/注释扫描(嵌套模板必须手工处理, 正则会漏)
  function stripLiterals(s) {
    let out = '', i = 0; const n = s.length;
    const skipQuote = (q) => { i++; while (i < n && s[i] !== q) { if (s[i] === '\\') i++; i++; } i++; };
    const skipTemplate = () => {
      i++; let depth = 0;
      while (i < n) {
        const c = s[i];
        if (c === '\\') { i += 2; continue; }
        if (c === '`' && depth === 0) { i++; return; }
        if (c === '$' && s[i + 1] === '{') { depth++; i += 2; continue; }
        if (c === '}' && depth > 0) { depth--; i++; continue; }
        if (depth > 0 && (c === '"' || c === "'")) { skipQuote(c); continue; }
        if (depth > 0 && c === '`') { skipTemplate(); continue; }
        i++;
      }
    };
    const prevNonSpace = (str) => { for (let k = str.length - 1; k >= 0; k--) if (!/\s/.test(str[k])) return str[k]; return ''; };
    while (i < n) {
      const c = s[i];
      if (c === '/' && s[i + 1] === '/') { while (i < n && s[i] !== '\n') i++; continue; }
      if (c === '/' && s[i + 1] === '*') { i += 2; while (i < n && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; continue; }
      if (c === '/' && !/[\w$)\]]/.test(prevNonSpace(out))) {         // 正则字面量
        i++; let inClass = false;
        while (i < n) {
          if (s[i] === '\\') { i += 2; continue; }
          if (s[i] === '[') inClass = true;
          else if (s[i] === ']') inClass = false;
          else if (s[i] === '/' && !inClass) { i++; break; }
          else if (s[i] === '\n') break;
          i++;
        }
        continue;
      }
      if (c === '"' || c === "'") { skipQuote(c); out += ' '; continue; }
      if (c === '`') { skipTemplate(); out += ' '; continue; }
      out += c; i++;
    }
    return out;
  }
  const declared = new Set();
  for (const re of [/\bfunction\s*\*?\s*([A-Za-z_$][\w$]*)/g, /\bclass\s+([A-Za-z_$][\w$]*)/g,
                    /\bcatch\s*\(\s*([A-Za-z_$][\w$]*)/g]) {
    let mm; while ((mm = re.exec(js))) declared.add(mm[1]);
  }
  for (const mm of js.matchAll(/\b(?:const|let|var)\s+([^;\n]+)/g)) {
    let depth = 0, cur = ''; const parts = [];
    for (const ch of mm[1]) {
      if ('([{'.includes(ch)) depth++;
      else if (')]}'.includes(ch)) depth--;
      if (ch === ',' && depth === 0) { parts.push(cur); cur = ''; } else cur += ch;
    }
    parts.push(cur);
    for (const p of parts) {
      const id = p.split('=')[0].trim().replace(/^\.\.\./, '').replace(/[{}[\]]/g, '').trim();
      if (/^[A-Za-z_$][\w$]*$/.test(id)) declared.add(id);
      else if (id.includes(':')) {
        const b = id.split(':').pop().trim().replace(/[{}[\]]/g, '').trim();
        if (/^[A-Za-z_$][\w$]*$/.test(b)) declared.add(b);
      }
    }
  }
  for (const mm of js.matchAll(/(?:function\s*\*?\s*[A-Za-z_$][\w$]*\s*|\))\s*(\([^)]*\))/g)) {
    mm[1].replace(/[()]/g, '').split(',').forEach(p => {
      const id = p.split('=')[0].trim().replace(/^\.\.\./, '');
      if (/^[A-Za-z_$][\w$]*$/.test(id)) declared.add(id);
    });
  }
  for (const mm of js.matchAll(/(?:^|[=(,;\s])([A-Za-z_$][\w$]*)\s*=>/g)) declared.add(mm[1]);
  const work = stripLiterals(js)
    .replace(/<[^>]*>/g, ' ')
    .replace(/[a-z-]+="[^"]*"/g, ' ')
    .replace(/\.[A-Za-z_$][\w$]*/g, ' ')
    .replace(/[{,]\s*[A-Za-z_$][\w$]*\s*:/g, '{,')
    .replace(/[{,]\s*[A-Za-z_$][\w$]*\s*\(/g, '{(,');
  const used = new Map();
  for (const mm of work.matchAll(/\b([A-Za-z_$][\w$]*)\b/g)) {
    const w = mm[1];
    if (KNOWN.has(w) || declared.has(w)) continue;
    used.set(w, (used.get(w) || 0) + 1);
  }
  const suspects = [...used.entries()].filter(([w]) => !/^[A-Z][A-Z0-9_]*$/.test(w)).sort((a, b) => b[1] - a[1]);
  if (suspects.length) { bad++; console.log('❌ 闸2 未声明标识符: ' + suspects.slice(0, 12).map(x => x[0]).join(', ')); }
  else console.log('✅ 闸2 未声明标识符: 无 (已声明 ' + declared.size + ' 个)');
}

/* ── 闸 3: 模板串泄漏到纯 HTML ── */
{
  const htmlPart = src.split(/<script>/)[0];
  const leaks = htmlPart.split('\n').map((l, i) => [i + 1, l]).filter(([, l]) => l.includes('${'));
  if (leaks.length) {
    bad++;
    console.log('❌ 闸3 模板串泄漏(纯 HTML 区不该出现 ${...}):');
    leaks.slice(0, 8).forEach(([i, l]) => console.log('   行' + i + ': ' + l.trim().slice(0, 90)));
  } else console.log('✅ 闸3 模板串泄漏: 无');
}

/* ── 闸 4: 语法 ── */
{
  const tmp = join(base, '.frontcheck.tmp.js');
  try {
    writeFileSync(tmp, JS, 'utf8');
    new vm.Script(JS, { filename: 'index.html<script>' });   // 只查语法
    console.log('✅ 闸4 语法: 通过 (' + _blocks.length + ' 个 script 块)');
  } catch (e) {
    bad++;
    console.log('❌ 闸4 语法: ' + e.message);
  }
}

/* ── 闸 5: 图标引用了不存在的 symbol(界面上就是一个空框) ── */
{
  const defs = new Set([...src.matchAll(/<symbol[^>]*\bid="([^"]+)"/g)].map(m => m[1]));
  const used = new Set([...src.matchAll(/<use[^>]*href="#([^"]+)"/g)].map(m => m[1]));
  const missing = [...used].filter(u => !defs.has(u));
  if (missing.length) { bad++; console.log('❌ 闸5 缺图标 symbol: ' + missing.join(', ')); }
  else console.log('✅ 闸5 图标 symbol: ' + used.size + ' 个引用全部有定义');
}

/* ── 闸 6: 同名函数声明(后定义覆盖前定义 → 某个按钮变成空操作) ── */
{
  const names = [...JS.matchAll(/^function\s+([A-Za-z_$][\w$]*)\s*\(/gm)].map(x => x[1]);
  const dup = [...new Set(names.filter((n, i) => names.indexOf(n) !== i))];
  if (dup.length) { bad++; console.log('❌ 闸6 同名函数声明(后者覆盖前者): ' + dup.join(', ')); }
  else console.log('✅ 闸6 同名函数声明: 无 (' + names.length + ' 个函数)');
}

/* ── 闸 7: 块级变量遮蔽全局函数(比如 const t = ... 把 i18n 的 t() 遮掉) ── */
{
  const globals = new Set([...JS.matchAll(/^function\s+([A-Za-z_$][\w$]*)\s*\(/gm)].map(x => x[1]));
  // 顶层 let/const 声明的全局名字
  const topDecl = new Set([...JS.matchAll(/^(?:let|const|var)\s+([A-Za-z_$][\w$]*)/gm)].map(x => x[1]));
  const hits = [];
  for (const mm of JS.matchAll(/^\s{2,}(?:let|const)\s+([A-Za-z_$][\w$]*)\s*=/gm)) {
    const nm = mm[1];
    if (globals.has(nm) || topDecl.has(nm)) hits.push(nm);
  }
  const uniq = [...new Set(hits)];
  if (uniq.length) {
    bad++;
    console.log('❌ 闸7 块级变量遮蔽了同名全局: ' + uniq.join(', ') +
      ' (会被后定义的同名标识符顶掉, 例如 const t = ... 把 i18n 的 t() 遮没)');
  } else console.log('✅ 闸7 变量遮蔽: 无');
}

/* 闸8: stylelint CSS 校验 — 2026-11-03 实锤 fuzzy patch 把 backdrop-filter 撕成
   「ba + 注释 + ckdrop-filter」粘成一行, 七道闸全放行进了包。属性级断裂只有真正的
   CSS 解析器能抓。依赖: npm i -g stylelint postcss-html + .stylelintrc.json */
try {
  const { execSync } = await import('node:child_process');
  let out = '';
  try {
    out = execSync('stylelint index.html --custom-syntax postcss-html', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) { out = (e.stdout || '') + (e.stderr || ''); }
  const hits = out.split('\n').filter(l => /✖|Error/.test(l) && !/Duplicate property/.test(l) && !/problems \(|problems\(/.test(l));
  if (hits.length) {
    bad++;
    console.log('❌ 闸8 CSS 语法/属性: ' + hits.length + ' 处 — ' + hits.slice(0, 4).map(s => s.trim()).join(' | '));
  } else console.log('✅ 闸8 CSS 语法/属性: 无断裂 (重复属性等历史噪音已豁免)');
} catch (e) {
  console.log('⚠ 闸8 跳过: stylelint 不可用 (npm i -g stylelint postcss-html)');
}

console.log(bad ? `\n${bad} 道闸没过` : '\n前端静态闸全过 ✅');
process.exit(bad ? 1 : 0);
