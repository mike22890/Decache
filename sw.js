// sw.js — service worker: 只缓存"外壳"(图标/manifest/页面壳)
// 绝不动 /api/* —— 里面是媒体流和用户数据, 缓存了就是灾难
const CACHE = 'decache-shell-v1';
const SHELL = ['/icons/icon-192.png', '/icons/icon-512.png', '/icons/icon-maskable-512.png',
               '/icons/apple-touch-icon.png', '/manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const path = new URL(req.url).pathname;
  if (path.startsWith('/api')) return;              // API / 视频流 / 字幕: 一律不碰
  if (path.startsWith('/icons/') || path === '/manifest.json') {
    e.respondWith(caches.match(req).then(r => r || fetch(req)));
    return;
  }
  if (path === '/') {                               // 页面: 网络优先, 离线回落到缓存
    e.respondWith(fetch(req).catch(() => caches.match('/')));
    return;
  }
});
