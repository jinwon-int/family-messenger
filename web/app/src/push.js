// 웹푸시 pusher 등록/해제 (#167 B). 브라우저 API는 전부 인자로 받는다 — 시험이
// 실제 구독 없이 계약을 검사할 수 있어야 한다.
//
// 흐름: PushManager.subscribe → 구독의 p256dh를 pushkey로 삼아 홈서버에 pusher 등록
//       → 홈서버가 sygnal로 notify → sygnal이 endpoint로 웹푸시 발송 → sw.js가 표시.
//
// pushkey는 endpoint가 아니라 **p256dh**다. sygnal의 WebpushPushkin이
// `p256dh = device.pushkey`, `endpoint = device.data["endpoint"]`로 읽는다.
// 긴 endpoint URL은 data에 들어가므로 Synapse의 pushkey 512바이트 제약에도 걸리지 않는다.

import { strings } from './strings.js';

export const PUSHER_KIND = 'http';
export const PUSHER_LANG = 'ko';

const isText = (value) => typeof value === 'string' && value.length > 0;

/**
 * base64url 문자열 → Uint8Array.
 *
 * applicationServerKey에 문자열을 그대로 넘기는 것은 규격상 허용되지만 구형
 * 브라우저가 받지 않는 경우가 있어 직접 바이트로 바꿔 넘긴다. config.js가 이미
 * 87자·65바이트·0x04를 검증했으므로 여기서는 형식을 다시 따지지 않는다.
 */
export function decodeApplicationServerKey(value) {
  const binary = atob(String(value).replace(/-/g, '+').replace(/_/g, '/'));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** PushSubscription(또는 그 toJSON 결과) → {endpoint, p256dh, auth}. 불완전하면 null. */
export function readSubscription(subscription) {
  if (!subscription) return null;
  const json = typeof subscription.toJSON === 'function' ? subscription.toJSON() : subscription;
  if (!json || typeof json !== 'object') return null;
  const endpoint = json.endpoint;
  const keys = json.keys;
  const p256dh = keys && typeof keys === 'object' ? keys.p256dh : null;
  const auth = keys && typeof keys === 'object' ? keys.auth : null;
  // 셋 중 하나라도 없으면 sygnal이 pushkey를 reject하고 홈서버가 pusher를 지운다.
  // 그 상태는 "등록은 됐는데 알림만 안 온다"로 보이므로 여기서 잘라낸다.
  if (!isText(endpoint) || !isText(p256dh) || !isText(auth)) return null;
  return { endpoint, p256dh, auth };
}

/**
 * pushers/set 본문을 만든다. @returns {null|object}
 *
 * ⚠ `format`은 넣지 않는다. Tuwunel이 `event_id_only`를 만나면 content·sender·type을
 *    빼고 보내서 webpush 평문 페이로드가 사실상 비고, 알림이 "새 메시지가 도착했습니다"
 *    밖에 못 된다(docs/SYGNAL-DEPLOY.md).
 */
export function pusherPayload({ subscription, push, userId, deviceDisplayName }) {
  const parsed = readSubscription(subscription);
  if (!parsed || !push || !isText(push.appId) || !isText(push.gatewayUrl)) return null;
  return {
    kind: PUSHER_KIND,
    app_id: push.appId,
    pushkey: parsed.p256dh,
    app_display_name: strings.appName,
    device_display_name: isText(deviceDisplayName) ? deviceDisplayName : strings.appName,
    lang: PUSHER_LANG,
    // 서비스워커/origin당 구독이 하나라 계정이 달라도 pushkey가 같다. 스펙대로 보낸다.
    // (이 배포의 Tuwunel은 append를 읽지 않지만, 타 사용자 pusher를 지우지도 않는다.)
    append: true,
    data: {
      url: push.gatewayUrl,
      endpoint: parsed.endpoint,
      auth: parsed.auth,
      // event_id 없는 정리용 푸시를 받지 않는다. 받으면 서비스워커가 보여줄 것이
      // 없는데 userVisibleOnly 때문에 브라우저가 "site has been updated in the
      // background"를 대신 띄우고, iOS에서는 권한 박탈로 이어진다.
      events_only: true,
      // 같은 방의 이전 알림을 Topic 헤더로 대체한다.
      only_last_per_room: true,
      ...(isText(userId) ? { default_payload: { account: userId } } : {}),
    },
  };
}

/**
 * 구독하고 pusher를 등록한다.
 * @returns {Promise<{ok: true, pushkey: string}|{ok: false, reason: string}>}
 *
 * 권한 요청은 여기서 하지 않는다 — 호출자가 사용자 제스처 안에서 처리한다.
 * 로그인 직후 무조건 팝업을 띄우면 거절당한 뒤 회복이 어렵다(#167 C).
 */
export async function enablePush({ registration, push, client, userId, deviceDisplayName, permission }) {
  if (!push) return { ok: false, reason: 'not-configured' };
  if (permission !== 'granted') return { ok: false, reason: 'no-permission' };
  const manager = registration?.pushManager;
  if (!manager || typeof manager.subscribe !== 'function') return { ok: false, reason: 'unsupported' };

  let subscription;
  try {
    // 이미 구독이 있으면 재사용한다. 다시 subscribe하면 applicationServerKey가
    // 같을 때는 같은 구독이 오지만, 굳이 왕복할 이유가 없다.
    subscription = typeof manager.getSubscription === 'function' ? await manager.getSubscription() : null;
    if (!subscription) {
      subscription = await manager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: decodeApplicationServerKey(push.applicationServerKey),
      });
    }
  } catch {
    return { ok: false, reason: 'subscribe-failed' };
  }

  const payload = pusherPayload({ subscription, push, userId, deviceDisplayName });
  if (!payload) return { ok: false, reason: 'incomplete-subscription' };
  try {
    await client.setPusher(payload);
  } catch {
    return { ok: false, reason: 'pusher-failed' };
  }
  return { ok: true, pushkey: payload.pushkey };
}

/**
 * pusher를 지우고 구독을 해제한다.
 * @returns {Promise<{ok: boolean, removed: boolean, unsubscribed: boolean}>}
 *
 * **순서가 중요하다.** pushkey는 구독에서만 읽을 수 있으므로 pusher를 먼저 지운다.
 * 로그아웃 경로에서는 **client.logout()보다 먼저** 불러야 한다 — 토큰이 사라진 뒤에는
 * pusher를 지울 수 없고, 그러면 기기를 떠난 뒤에도 알림이 계속 간다(#126).
 */
export async function disablePush({ registration, push, client }) {
  const manager = registration?.pushManager;
  if (!manager || typeof manager.getSubscription !== 'function') return { ok: true, removed: false, unsubscribed: false };

  let subscription = null;
  try {
    subscription = await manager.getSubscription();
  } catch {
    return { ok: false, removed: false, unsubscribed: false };
  }
  if (!subscription) return { ok: true, removed: false, unsubscribed: false };

  const parsed = readSubscription(subscription);
  let removed = false;
  if (parsed && push && isText(push.appId) && client && typeof client.removePusher === 'function') {
    try {
      await client.removePusher(parsed.p256dh, push.appId);
      removed = true;
    } catch {
      // 홈서버에서 못 지웠다. 그래도 구독은 푼다 — 남은 pusher는 다음 발송에서
      // 404/410을 받아 sygnal이 pushkey를 reject하고 홈서버가 정리한다.
      removed = false;
    }
  }

  let unsubscribed = false;
  try {
    unsubscribed = typeof subscription.unsubscribe === 'function' ? Boolean(await subscription.unsubscribe()) : false;
  } catch {
    unsubscribed = false;
  }
  return { ok: removed && unsubscribed, removed, unsubscribed };
}
