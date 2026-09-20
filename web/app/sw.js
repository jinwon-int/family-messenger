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

// ---------------------------------------------------------------------------
// 웹푸시 (#167)
//
// ⚠ 이 파일은 번들되지 않는다(build.mjs는 자리표시자만 치환한다). import를 쓸 수
//    없으므로 문구가 strings.js가 아니라 여기 리터럴로 있다. 뷰 모듈이 아니다.
//
// ⚠ **push를 받으면 무슨 일이 있어도 showNotification을 부른다.** Apple 문서:
//    "Safari doesn't support invisible push notifications... If you don't,
//    Safari revokes the push notification permission for your site."
//    그래서 아래 경로에는 '표시하지 않고 끝나는' 분기가 하나도 없다 —
//    페이로드가 없어도, JSON이 깨져도, 필드가 비어도 대체 알림을 띄운다.
//    pusher의 events_only/only_last_per_room이 홈서버를 거치며 사라지는 경우에도
//    이 무조건 표시가 마지막 안전망이다(SYGNAL-DEPLOY.md 진단표).
//
// 1차 범위: 복호화하지 않는다. sygnal이 평문으로 싣는 room_name/sender_display_name만
// 쓴다. E2EE 방의 content는 megolm 봉투라 본문이 없고(암호문은 2000자 초과 시
// sygnal이 아예 떼어낸다), 그때는 "OOO님이 메시지를 보냈습니다"로 내려간다.

const NOTIFY_ICON = './icons/icon.svg';
const NOTIFY_TITLE_FALLBACK = '패밀리챗';
const NOTIFY_BODY_FALLBACK = '새 메시지가 도착했습니다';
const NOTIFY_BODY_MAX = 200;
// 본문을 그대로 보여줄 msgtype. 그 외(사진·파일 등)는 body가 파일명이라 보여주지 않는다.
const PLAIN_MSGTYPES = ['m.text', 'm.notice', 'm.emote'];

function plainBody(content) {
  if (!content || typeof content !== 'object') return null;
  // algorithm이 있으면 megolm 봉투다 — 이 단계에서는 열지 않는다.
  if (content.algorithm) return null;
  const msgtype = content.msgtype;
  if (msgtype !== undefined && !PLAIN_MSGTYPES.includes(msgtype)) return null;
  const body = content.body;
  if (typeof body !== 'string') return null;
  const trimmed = body.trim();
  if (trimmed.length === 0) return null;
  return trimmed.length > NOTIFY_BODY_MAX ? `${trimmed.slice(0, NOTIFY_BODY_MAX)}…` : trimmed;
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

/** sygnal 페이로드 → showNotification 인자. 어떤 입력에도 반드시 무언가를 돌려준다. */
function describeNotification(payload) {
  const data = payload && typeof payload === 'object' ? payload : {};
  const roomName = nonEmpty(data.room_name) ?? nonEmpty(data.room_alias);
  const sender = nonEmpty(data.sender_display_name) ?? nonEmpty(data.sender);
  const body = plainBody(data.content);

  let text;
  if (body) text = sender ? `${sender}: ${body}` : body;
  else if (sender) text = `${sender}님이 메시지를 보냈습니다`;
  else text = NOTIFY_BODY_FALLBACK;

  const roomId = nonEmpty(data.room_id);
  return {
    title: roomName ?? NOTIFY_TITLE_FALLBACK,
    options: {
      body: text,
      icon: NOTIFY_ICON,
      badge: NOTIFY_ICON,
      // 같은 방의 이전 알림을 대체한다. sygnal의 only_last_per_room(Topic 헤더)과
      // 같은 목적이고, 그 설정이 사라진 경우의 클라이언트 측 보험이다.
      tag: roomId ?? 'familychat',
      timestamp: Date.now(),
      data: { roomId, eventId: nonEmpty(data.event_id) },
    },
  };
}

function readPushPayload(event) {
  if (!event || !event.data) return null;
  try {
    return event.data.json();
  } catch {
    return null;
  }
}

self.addEventListener('push', (event) => {
  let described;
  try {
    described = describeNotification(readPushPayload(event));
  } catch {
    // 여기서 던지면 알림이 안 뜨고 iOS에서 권한이 박탈된다. 무조건 대체 알림.
    described = { title: NOTIFY_TITLE_FALLBACK, options: { body: NOTIFY_BODY_FALLBACK, icon: NOTIFY_ICON, badge: NOTIFY_ICON, tag: 'familychat', data: { roomId: null, eventId: null } } };
  }
  event.waitUntil(self.registration.showNotification(described.title, described.options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const roomId = event.notification.data ? event.notification.data.roomId : null;
  event.waitUntil((async () => {
    const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of clients) {
      if (typeof client.focus !== 'function') continue;
      await client.focus();
      // 앱에 URL 라우팅이 없어(방 선택은 메모리 상태) 어느 방을 열지는 메시지로 넘긴다.
      if (typeof client.postMessage === 'function') client.postMessage({ type: 'familychat:open-room', roomId });
      return;
    }
    if (typeof self.clients.openWindow === 'function') await self.clients.openWindow('./');
  })());
});
