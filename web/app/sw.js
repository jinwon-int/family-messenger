// Service worker: app-shell cache for PWA installs.
// Never touches /_matrix (homeserver API) or media traffic.

const CACHE = 'familychat-shell-v9'; // v9: #128 키보드 단축키(main.js?v=5) + styles.css?v=2(구 SW cache-first에 갇힌 옛 CSS 우회)
const SHELL = ['./', './index.html', './main.js?v=5', './styles.css?v=2', './manifest.webmanifest', './icons/icon.svg'];

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

self.addEventListener('fetch', (event) => {
  const reqUrl = new URL(event.request.url);
  const isShellDoc = event.request.mode === 'navigate'
    || reqUrl.pathname === '/' || reqUrl.pathname.endsWith('/index.html') || reqUrl.pathname.endsWith('/main.js')
    || reqUrl.pathname.endsWith('/styles.css');
  if (event.request.method === 'GET' && isShellDoc && reqUrl.origin === self.location.origin) {
    // 셸·번들은 항상 네트워크 우선 — 핫픽스가 기기 캐시에 갇히지 않게 한다.
    event.respondWith(
      fetch(event.request).then((response) => {
        const copy = response.clone();
        caches.open(CACHE).then((cache) => cache.put(event.request, copy));
        return response;
      }).catch(() => caches.match(event.request)),
    );
    return;
  }
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/_matrix')) return;

  // Navigations: network first, shell cache as offline fallback.
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((response) => {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put('./index.html', copy));
          return response;
        })
        .catch(() => caches.match('./index.html')),
    );
    return;
  }

  // Same-origin assets: cache first.
  event.respondWith(
    caches.match(request).then((cached) => cached ?? fetch(request)),
  );
});
