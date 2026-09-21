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
  // 결과를 확인한다. atob는 "null" 같은 문자열도 조용히 통과시켜 길이 3짜리
  // 가짜 키를 만든다. config.js가 이미 검증하지만 이 함수는 export되어 있어
  // 다른 호출자가 검증 없이 부를 수 있다.
  if (bytes.length !== 65 || bytes[0] !== 0x04) throw new TypeError('applicationServerKey는 비압축 P-256 점 65바이트여야 한다');
  return bytes;
}

/** 두 바이트열이 같은가. 구독의 applicationServerKey는 ArrayBuffer로 온다. */
function sameKey(a, b) {
  if (!a || !b) return false;
  const left = a instanceof Uint8Array ? a : new Uint8Array(a);
  const right = b instanceof Uint8Array ? b : new Uint8Array(b);
  if (left.length !== right.length) return false;
  for (let i = 0; i < left.length; i += 1) if (left[i] !== right[i]) return false;
  return true;
}

/**
 * 기존 구독이 지금 설정된 VAPID 키로 만들어진 것인가.
 *
 * 키를 교체하면 기존 구독은 전부 무효가 된다(gen-vapid-key.sh 경고). 그런데
 * 낡은 구독을 그대로 쓰면 pusher 등록은 성공하고, sygnal이 새 개인키로 서명한
 * 푸시를 푸시 서비스가 옛 p256dh에 대해 거부한다 — "등록은 됐는데 알림만 안 온다".
 * 브라우저가 options를 안 알려주면(구형) 판단할 수 없으므로 재사용하지 않는다.
 */
function matchesConfiguredKey(subscription, applicationServerKey) {
  const options = subscription && subscription.options;
  if (!options || !('applicationServerKey' in options)) return false;
  return sameKey(options.applicationServerKey, applicationServerKey);
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
      // sygnal이 페이로드에 병합해 주는 값. **아직 sw.js가 읽지 않는다.**
      // 읽게 되면 공용 기기에서 다른 계정의 알림을 걸러낼 수 있다: append:true라
      // 같은 pushkey에 여러 계정의 pusher가 공존할 수 있고(이 배포의 Tuwunel은
      // 타 계정 pusher를 지우지 않는다), 로그아웃이 실패했거나 세션이 만료된
      // 계정의 메시지가 지금 로그인한 사람에게 보일 수 있다.
      // 거르려면 서비스워커가 "지금 이 브라우저의 계정"을 알아야 하는데, 앱이
      // 닫힌 상태에서도 읽을 수 있는 저장소가 필요하다 — 별도 조각이다.
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
  // 홈서버에 보낼 수 없다면 구독부터 만들지 않는다. 먼저 구독하면 pusher 없는
  // 구독이 브라우저에 남고, 설정 오류가 'pusher-failed'(홈서버 거부)로 보고되어
  // 진단이 흐려진다.
  if (!client || typeof client.setPusher !== 'function') return { ok: false, reason: 'no-client' };

  let key;
  try {
    key = decodeApplicationServerKey(push.applicationServerKey);
  } catch {
    return { ok: false, reason: 'bad-key' };
  }

  let subscription;
  let created = false;
  try {
    const existing = typeof manager.getSubscription === 'function' ? await manager.getSubscription() : null;
    // 지금 설정된 VAPID 키로 만들어진 구독만 재사용한다. 키가 바뀌었으면 풀고
    // 다시 만든다 — 낡은 구독을 그대로 쓰면 등록은 성공하고 알림만 사라진다.
    if (existing && matchesConfiguredKey(existing, key)) {
      subscription = existing;
    } else {
      if (existing && typeof existing.unsubscribe === 'function') await existing.unsubscribe();
      subscription = await manager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
      created = true;
    }
  } catch {
    return { ok: false, reason: 'subscribe-failed' };
  }

  const payload = pusherPayload({ subscription, push, userId, deviceDisplayName });
  if (!payload) {
    if (created) await unsubscribeQuietly(subscription);
    return { ok: false, reason: 'incomplete-subscription' };
  }
  try {
    await client.setPusher(payload);
  } catch {
    // 이번에 만든 구독이라면 되돌린다. 남겨두면 홈서버가 모르는 구독이 기기에
    // 남아, 다음 시도에서 재사용 후보로 잡힌다.
    if (created) await unsubscribeQuietly(subscription);
    return { ok: false, reason: 'pusher-failed' };
  }
  return { ok: true, pushkey: payload.pushkey };
}

async function unsubscribeQuietly(subscription) {
  try {
    if (subscription && typeof subscription.unsubscribe === 'function') await subscription.unsubscribe();
  } catch {
    /* 되돌리기 실패는 보고할 곳이 없다 */
  }
}

/**
 * pusher를 지우고 구독을 해제한다.
 *
 * @returns {Promise<{ok: boolean, removed: boolean, unsubscribed: boolean}>}
 *   `ok`는 **"이 기기에 더 이상 활성 구독이 없다"** 는 뜻이다. 호출자(설정 토글)가
 *   "꺼짐"을 표시해도 되는지를 이 값 하나로 판단할 수 있어야 한다.
 *   `removed`는 홈서버 쪽 pusher 삭제 성공 여부로, 실패해도 이 기기는 알림을
 *   받지 않는다(남은 pusher는 다음 발송의 404/410으로 홈서버가 정리한다).
 *   앞서 `ok = removed && unsubscribed`로 두었더니 "아무것도 안 했다"가 성공,
 *   "구독은 확실히 풀었다"가 실패로 보고되어 서로 모순이었다.
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
  return { ok: unsubscribed, removed, unsubscribed };
}
