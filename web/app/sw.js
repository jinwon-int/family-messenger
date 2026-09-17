// Service worker: app-shell cache for PWA installs.
// Never touches /_matrix (homeserver API) or media traffic.
//
// Template: build.mjs fills the CACHE name (build hash) and the SHELL list
// (hashed asset names) below. Every build therefore gets a fresh cache name
// and the activate step drops the previous one — no more hand-bumped versions.

const CACHE = '__CACHE_NAME__';
const SHELL = __SHELL_ASSETS__;

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))),
  );
  self.clients.claim();
});

// 문서·설정·매니페스트는 항상 네트워크 우선(핫픽스가 기기 캐시에 갇히지 않게).
// 해시가 붙은 자산과 wasm은 내용이 곧 이름이므로 캐시 우선.
function isNetworkFirst(request, url) {
  if (request.mode === 'navigate') return true;
  const path = url.pathname;
  return path === '/' || path.endsWith('/index.html') || path.endsWith('/config.json') || path.endsWith('/manifest.webmanifest');
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/_matrix')) return;

  if (isNetworkFirst(request, url)) {
    event.respondWith(
      fetch(request)
        .then((response) => {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put(request, copy));
          return response;
        })
        .catch(() => caches.match(request).then((cached) => cached ?? (request.mode === 'navigate' ? caches.match('./index.html') : undefined))),
    );
    return;
  }

  event.respondWith(
    caches.match(request).then((cached) => cached ?? fetch(request).then((response) => {
      const copy = response.clone();
      caches.open(CACHE).then((cache) => cache.put(request, copy));
      return response;
    })),
  );
});
