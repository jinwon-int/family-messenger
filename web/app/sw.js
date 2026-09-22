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
// 해시가 붙은 자산은 내용이 곧 이름이므로 캐시 우선. wasm은 이름이 고정 경로지만
// install이 프리캐시하고 캐시 이름이 빌드마다 바뀌므로(위 헤더 주석) 캐시 우선이
// 안전하다 — 새 glue에 오래된 wasm이 엮일 일이 없다.
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

// ⚠ Chrome은 알림 icon/badge로 SVG를 디코딩하지 않는다. 이 저장소에는 아직 PNG
//    아이콘이 없어서 그대로 둔다 — 지원하지 않는 브라우저는 기본 아이콘으로 떨어질 뿐
//    알림 자체는 뜬다. PNG 추가는 별도 조각이다.
const NOTIFY_ICON = './icons/icon.svg';
const NOTIFY_TITLE_FALLBACK = '패밀리챗';
const NOTIFY_BODY_FALLBACK = '새 메시지가 도착했습니다';
const NOTIFY_BODY_MAX = 200;
// 내용을 모르는 대체 알림이 쓰는 태그. 방 태그를 쓰면 안 된다 — 아래 describeNotification 참조.
const NOTIFY_TAG_UNKNOWN = 'familychat:unknown';
// 본문을 그대로 보여줄 msgtype. 그 외(사진·파일·스티커 등)는 body가 파일명이나
// 설명이라 보여주지 않는다. **msgtype이 없으면 통과시키지 않는다** — m.sticker처럼
// msgtype 없이 body만 있는 이벤트가 화이트리스트를 그냥 지나가기 때문이다.
const PLAIN_MSGTYPES = ['m.text', 'm.notice', 'm.emote'];
const ENCRYPTED_EVENT_TYPE = 'm.room.encrypted';

const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

/**
 * 평문으로 보여도 되는 본문만 골라낸다. @returns {null|{text: string, msgtype: string}}
 *
 * 봉투 판정은 값의 truthiness가 아니라 **키의 존재**로 한다. content는 보내는 쪽이
 * 완전히 통제하는 JSON이라 `algorithm: ""`/`0`/`null` 같은 값으로 검사를 지나갈 수
 * 있고, 그러면 ciphertext 옆의 body가 그대로 알림에 뜬다. 상위 type도 함께 본다 —
 * m.room.encrypted는 msgtype이 없어 화이트리스트가 건너뛰어진다.
 */
function plainBody(payload, content) {
  if (!content || typeof content !== 'object' || Array.isArray(content)) return null;
  if (payload.type === ENCRYPTED_EVENT_TYPE) return null;
  if (has(content, 'algorithm') || has(content, 'ciphertext')) return null;
  const msgtype = content.msgtype;
  if (typeof msgtype !== 'string' || !PLAIN_MSGTYPES.includes(msgtype)) return null;
  const body = content.body;
  if (typeof body !== 'string') return null;
  const trimmed = body.trim();
  if (trimmed.length === 0) return null;
  // 코드 포인트 단위로 자른다. UTF-16 단위로 자르면 이모지의 서로게이트 쌍이 쪼개져
  // 단독 서로게이트가 남고 U+FFFD로 렌더된다.
  const points = Array.from(trimmed);
  const text = points.length > NOTIFY_BODY_MAX ? `${points.slice(0, NOTIFY_BODY_MAX).join('')}…` : trimmed;
  return { text, msgtype };
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

/** sygnal 페이로드 → showNotification 인자. 어떤 입력에도 반드시 무언가를 돌려준다. */
function describeNotification(payload) {
  const data = payload && typeof payload === 'object' ? payload : {};
  const roomName = nonEmpty(data.room_name) ?? nonEmpty(data.room_alias);
  const sender = nonEmpty(data.sender_display_name) ?? nonEmpty(data.sender);
  const plain = plainBody(data, data.content);

  let text;
  if (plain && sender) text = plain.msgtype === 'm.emote' ? `${sender} ${plain.text}` : `${sender}: ${plain.text}`;
  else if (plain) text = plain.text;
  else if (sender) text = `${sender}님이 메시지를 보냈습니다`;
  else text = NOTIFY_BODY_FALLBACK;

  const roomId = nonEmpty(data.room_id);
  const eventId = nonEmpty(data.event_id);
  // 같은 방의 이전 알림을 대체한다. sygnal의 only_last_per_room(Topic 헤더)과 같은
  // 목적이고, 그 설정이 사라진 경우의 클라이언트 측 보험이다.
  //
  // ⚠ 단, **event_id가 없는 푸시에는 방 태그를 쓰지 않는다.** 그건 내용을 모르는
  //    대체 알림인데, 방 태그를 쓰면 방금 띄운 "엄마: 저녁 먹었니"를 "새 메시지가
  //    도착했습니다"로 덮어써서 정보를 지운다. events_only가 홈서버를 거치며 사라져
  //    정리용 푸시가 들어오는 상황 — 즉 이 대체 알림이 필요한 바로 그 상황 — 에서
  //    실제로 일어난다.
  const tag = eventId ? (roomId ?? NOTIFY_TITLE_FALLBACK) : NOTIFY_TAG_UNKNOWN;
  return {
    title: roomName ?? NOTIFY_TITLE_FALLBACK,
    options: {
      body: text,
      icon: NOTIFY_ICON,
      badge: NOTIFY_ICON,
      tag,
      timestamp: Date.now(),
      data: { roomId, eventId },
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

function fallbackNotification() {
  return { title: NOTIFY_TITLE_FALLBACK, options: { body: NOTIFY_BODY_FALLBACK, tag: NOTIFY_TAG_UNKNOWN } };
}

self.addEventListener('push', (event) => {
  let described;
  try {
    described = describeNotification(readPushPayload(event));
  } catch {
    // 여기서 던지면 알림이 안 뜨고 iOS에서 권한이 박탈된다. 무조건 대체 알림.
    described = fallbackNotification();
  }
  // showNotification이 거부해도 waitUntil까지 거부가 새어나가지 않게 한다. 거부를
  // 그대로 두면 push 이벤트가 실패로 끝나 브라우저가 "site has been updated in the
  // background"를 대신 띄운다 — 우리가 막으려던 바로 그 결과다. 옵션이 문제였을
  // 수 있으므로 최소 옵션으로 한 번 더 시도한 뒤 삼킨다.
  const shown = self.registration.showNotification(described.title, described.options);
  event.waitUntil(Promise.resolve(shown).catch(() => {
    const bare = fallbackNotification();
    return Promise.resolve(self.registration.showNotification(bare.title, bare.options)).catch(() => {});
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const roomId = event.notification.data ? event.notification.data.roomId : null;
  // 이 경로에는 실패해도 되는 단계가 여럿이다(Chrome은 사용자 제스처 판정에 따라
  // focus()를 InvalidAccessError로 거부한다). 한 곳의 거부가 나머지 창 시도와
  // openWindow 폴백까지 지우지 않도록 단계마다 격리한다.
  event.waitUntil((async () => {
    let clients = [];
    try {
      clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    } catch {
      clients = [];
    }
    for (const client of clients) {
      if (!client || typeof client.focus !== 'function') continue;
      try {
        await client.focus();
      } catch {
        continue; // 이 창은 못 띄운다 — 다음 창을 시도한다
      }
      // 앱에 URL 라우팅이 없어(방 선택은 메모리 상태) 어느 방을 열지는 메시지로 넘긴다.
      if (typeof client.postMessage === 'function') {
        try {
          client.postMessage({ type: 'familychat:open-room', roomId });
        } catch {
          // 포커스는 됐다. 방 이동만 못 할 뿐이므로 새 창을 열지 않는다.
        }
      }
      return;
    }
    try {
      if (typeof self.clients.openWindow === 'function') await self.clients.openWindow('./');
    } catch {
      // 열 수 없으면 할 수 있는 일이 없다. 거부를 밖으로 내보내지만 않는다.
    }
  })());
});
