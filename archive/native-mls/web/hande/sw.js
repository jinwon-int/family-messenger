// 서비스 워커(#480 D): PWA 설치용 앱 셸 캐시 — 정책은 sw-policy.js(순수). main.js 가 `{ type: 'module' }` 로 등록한다.
// 네트워크 우선 + 오프라인 폴백. `/v2/*` 와 다른 origin 은 건드리지 않는다. 푸시 없음(webpush 게이트웨이 없음).
import { CACHE_NAME, SHELL_ASSETS, shouldHandle, fallbackKey } from './sw-policy.js';

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    // 하나가 없어도(예: 아직 배포 전 파일) 설치는 계속한다 — addAll 은 전부 아니면 무.
    await Promise.allSettled(SHELL_ASSETS.map((asset) => cache.add(asset)));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (!shouldHandle(request, self.location.origin)) return;
  event.respondWith((async () => {
    try {
      const response = await fetch(request);
      if (response && response.ok) {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(request, copy)).catch(() => {});
      }
      return response;
    } catch (error) {
      const cached = await caches.match(request);
      if (cached) return cached;
      const key = fallbackKey(request);
      const fallback = key ? await caches.match(key) : undefined;
      if (fallback) return fallback;
      throw error;
    }
  })());
});
