// decache-ui-preview.mjs — 临时 mock: 起在 8790, 让 index.html 的 UI 在无 Python/无 Python 环境下可看
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const base = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(base, 'index.html'), 'utf8');

const svgCover = (t, c1, c2) => Buffer.from(
  `<svg xmlns="http://www.w3.org/2000/svg" width="480" height="300">
   <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
   <stop offset="0" stop-color="${c1}"/><stop offset="1" stop-color="${c2}"/></linearGradient></defs>
   <rect width="480" height="300" fill="url(#g)"/>
   <text x="240" y="175" font-size="88" text-anchor="middle" fill="rgba(255,255,255,.3)"
    font-family="sans-serif">${t}</text></svg>`);

const covers = { BV1mock001:['深',' #232a52','#0f3145'], BV1mock002:['海','#3b2a52','#0f3145'],
  BV1mock003:['山','#1f3a35','#233a52'], BV1mock004:['云','#3a2a2a','#2a2a3a'],
  BV1mock005:['风','#2a3a2a','#1f3a35'], BV1mock006:['夜','#22223a','#0f3145'] };

const mkParts = (n) => Array.from({length:n},(_,i)=>({p:i+1, name:`第${i+1}话`, file:`P${i+1}.mp4`, size: 120+i*35}));

const LIB = { videos: [
  {bvid:'BV1mock001', title:'【4K60帧】深夜城市漫游 · 从霓虹到清晨的天台', folder:'深夜城市漫游', owner:'某UP', seq:1, updated: Date.now()/1000-3600, parts: mkParts(4)},
  {bvid:'BV1mock002', title:'把一台 1997 年的掌机拆到最后一颗螺丝', folder:'掌机拆解', owner:'拆东西的', seq:2, updated: Date.now()/1000-86400, parts: mkParts(2)},
  {bvid:'BV1mock003', title:'山之间 —— 三个月徒步纵走的全部影像', folder:'山之间', owner:'山里人', seq:3, updated: Date.now()/1000-86400*3, parts: mkParts(1)},
  {bvid:'BV1mock004', title:'云是什么 · 一场讲给成年人的气象课', folder:'云是什么', owner:'气象台', seq:4, updated: Date.now()/1000-86400*5, parts: mkParts(3)},
  {bvid:'BV1mock005', title:'风力发电机的叶片是怎么造出来的', folder:'风电机叶片', owner:'工业审美', seq:5, updated: Date.now()/1000-86400*8, parts: mkParts(2)},
  {bvid:'BV1mock006', title:'夜航西飞 · 机场塔台通讯实录(搬运)', folder:'夜航西飞', owner:'航空狗', seq:6, updated: Date.now()/1000-86400*12, parts: mkParts(5)},
], loose: [
  {name:'随便一个视频.mp4', rel:'随便一个视频.mp4', size:355, mtime:Date.now()/1000},
  {name:'screen recording 2026-10-18.mp4', rel:'screen.mp4', size:88, mtime:Date.now()/1000},
]};

const TASKS = [
  {id:2, bvid:'BV1mock006', title:'夜航西飞 · 机场塔台通讯实录(搬运)', status:'下载中',
   line:'P3 47.2%', created: Date.now()/1000-600},
  {id:1, bvid:'BV1mock005', title:'风力发电机的叶片是怎么造出来的', status:'排队中',
   line:'排队中 (第1位)', created: Date.now()/1000-700},
];

createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const j = o => { res.writeHead(200, {'Content-Type':'application/json'}); res.end(JSON.stringify(o)); };
  if (u.pathname === '/') { res.writeHead(200, {'Content-Type':'text/html; charset=utf-8'}); return res.end(html); }
  /* 慢图: 拖住 load 事件, 让 `floorp --screenshot` 那种"一 load 就拍"的工具等得到渲染完 */
  if (u.pathname === '/slow.png') {
    return setTimeout(() => {
      res.writeHead(200, {'Content-Type':'image/png', 'Cache-Control':'no-store'});
      res.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64'));
    }, 1200);
  }
  /* /seed —— 往 localStorage 里塞一份"继续观看"账本, 顺便停在媒体库, 专门用来肉眼验卡片/动效 */
  if (u.pathname === '/seed') {
    const now = Date.now(), v0 = LIB.videos[0], v1 = LIB.videos[1];
    const hist = [
      { r: v1.folder + '/' + v1.parts[0].file, t: 120, d: 1800, at: now - 60000 },
      { r: v0.folder + '/' + v0.parts[0].file, t: 2400, d: 3600, at: now - 3 * 86400000 },
    ];
    const pre = `<script>try{localStorage.setItem('take_hist_v1', ${JSON.stringify(JSON.stringify(hist))});}` +
      `catch(e){}</script><img src="/slow.png" style="position:absolute;width:1px;height:1px;opacity:0" alt="">`;
    const post = `<script>try{switchTab('lib');renderResume();}catch(e){}</script>`;
    res.writeHead(200, {'Content-Type':'text/html; charset=utf-8'});
    return res.end(html.replace(/<body([^>]*)>/, '<body$1>' + pre).replace('</body>', post + '</body>'));
  }
  if (u.pathname === '/api/version') return j({v:'6.13'});
  if (u.pathname === '/api/tasks') return j(TASKS);
  if (u.pathname === '/api/library') return j(LIB);
  if (u.pathname === '/api/tags') return j({tags:{red:2, green:1}, fav:3});
  if (u.pathname === '/api/queue') return j({items:[
    {rel:'深夜城市漫游/P1.mp4', title:'【4K60帧】深夜城市漫游', bvid:'BV1mock001', p:1, name:'第1话'},
    {rel:'掌机拆解/P1.mp4', title:'把一台 1997 年的掌机拆到最后一颗螺丝', bvid:'BV1mock002', p:1, name:'第1话'}]});
  if (u.pathname === '/api/browse') {
    const p = u.searchParams.get('path') || '';
    if (!p) return j({path:'', parent:'', can_up:false, dirs:[
      {name:'下载', path:'C:/Users/Downloads', n:42},
      {name:'Movies', path:'C:/Users/Movies', n:8}], files:[]});
    if (p.includes('Downloads')) return j({path:p, parent:'C:/Users', can_up:true, dirs:[
      {name:'纪录片', path:p+'/纪录片', n:5},
      {name:'课程', path:p+'/课程', n:12}], files:[
      {name:'深海之下 4K HDR.mp4', rel:'深海之下.mp4', size:1840, mtime:Date.now()/1000},
      {name:'城市速写 S01E03.mp4', rel:'城市速写.mp4', size:620, mtime:Date.now()/1000},
      {name:'访谈片段.mkv', rel:'访谈片段.mkv', size:930, mtime:Date.now()/1000}]});
    return j({path:p, parent:'C:/Users', can_up:true, dirs:[], files:[
      {name:'演示视频.mp4', rel:'演示.mp4', size:120, mtime:Date.now()/1000}]});
  }
  if (u.pathname === '/api/diagnostics') return j({platform:'linux', termux:false, python:'3.12.2',
    ffmpeg:'/usr/bin/ffmpeg', ffmpeg_ok:true, min_python:'3.9',
    hints:['Termux: Android 12+ 需授予 wakelock, 否则系统会杀掉 ffmpeg 子进程']});
  if (u.pathname === '/api/config') return j({engine:'yt-dlp', port:8765, download_dir:'/fake/path', cookie_set:false});
  if (u.pathname === '/api/credentials') return j({items:[
    {domain:'example.com', keys:['SESSION','buvid'], masked:'SESSION=abcd…wxyz; buvid=1234…5678', n:2},
    {domain:'', keys:['session'], masked:'session=qqqq…wwww', n:1}]});
  if (u.pathname === '/api/dupes') return j({waste_mb: 1234.5, groups:[
    {hash:'abc', size_mb: 842.0, waste_mb: 842.0, files:[
      {bvid:'BV1mock001', p:1, name:'深夜城市漫游 P1.mp4', rel:'a/P1.mp4', title:'【4K60帧】深夜城市漫游', path:'/x'},
      {bvid:'BV1mock002', p:1, name:'深夜城市漫游 (副本).mp4', rel:'b/P1.mp4', title:'把一台 1997 年的掌机拆到最后一颗螺丝', path:'/y'}]},
    {hash:'def', size_mb: 392.5, waste_mb: 392.5, files:[
      {bvid:'BV1mock003', p:1, name:'山之间.mp4', rel:'c/P1.mp4', title:'山之间', path:'/z'},
      {bvid:'BV1mock004', p:2, name:'山之间 副本.mp4', rel:'d/P2.mp4', title:'云是什么', path:'/w'}]}]});
  if (u.pathname === '/api/storage') return j({total_mb: 128640.5, free_mb: 51200, count: 6, items:[
    {bvid:'BV1mock001', title:'【4K60帧】深夜城市漫游 · 从霓虹到清晨的天台', size_mb: 48200, parts:4},
    {bvid:'BV1mock002', title:'把一台 1997 年的掌机拆到最后一颗螺丝', size_mb: 32100, parts:2},
    {bvid:'BV1mock003', title:'山之间 —— 三个月徒步纵走的全部影像', size_mb: 24100, parts:1},
    {bvid:'BV1mock004', title:'云是什么 · 一场讲给成年人的气象课', size_mb: 15800, parts:3},
    {bvid:'BV1mock005', title:'风力发电机的叶片是怎么造出来的', size_mb: 8400, parts:2},
    {bvid:'BV1mock006', title:'夜航西飞 · 机场塔台通讯实录(搬运)', size_mb: 40, parts:5}]});
  if (u.pathname === '/api/chapters') return j({real:false, duration:300, chapters:
    Array.from({length:12},(_,i)=>({start:i*25, end:(i+1)*25, title:'片段 '+(i+1)}))});
  if (u.pathname === '/api/marks') return j({ok:true, marks:[{t:42.5,title:'标记 0:42'}]});
  if (u.pathname === '/api/subs') return j({subs:[{label:'中英', rel:'/fake/video.srt'}]});
  if (u.pathname === '/api/sub') {
    res.writeHead(200, {'Content-Type':'text/vtt'});
    return res.end("WEBVTT\n\n1\n00:00:01.000 --> 00:00:04.000\n这是字幕测试行\n");
  }
  if (u.pathname === '/api/thumbs') {
    // 4x3 灰阶渐变假雪碧图
    res.writeHead(200, {'Content-Type':'image/jpeg', 'Cache-Control':'max-age=600'});
    return res.end(Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAFUlEQVR42mNk+M/wn4EIwESMolGEBgAeNQX/LLxKmAAAAABJRU5ErkJggg==', 'base64'));
  }
  if (u.pathname.startsWith('/api/cover/')) {
    const bvid = u.pathname.split('/').pop();
    const c = covers[bvid] || ['▶','#232a52','#0f3145'];
    res.writeHead(200, {'Content-Type':'image/svg+xml','Cache-Control':'no-store'});
    return res.end(svgCover(...c));
  }
  if (req.method === 'POST') {                    // 批量删除/收藏等写操作(假实现)
    let raw = '';
    req.on('data', c => raw += c);
    req.on('end', () => {
      let b = {};
      try { b = JSON.parse(raw || '{}'); } catch {}
      // 标签接口要像真服务器一样回 tags(前端靠它判断"加上了"还是"取消了")
      return j({ok: true, done: b.bvid || [], failed: [],
                tags: b.tag ? [b.tag] : [], fav: true});
    });
    return;
  }
  res.writeHead(404); res.end('{}');
}).listen(8790, '127.0.0.1', () => console.log('preview at http://127.0.0.1:8790'));
