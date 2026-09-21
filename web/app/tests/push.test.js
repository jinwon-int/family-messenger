// pusher 등록/해제 시험 (#167 B).
//
// 이 모듈이 지키는 계약은 네 가지다:
//  1. pushkey는 endpoint가 아니라 p256dh다 (sygnal이 그렇게 읽는다)
//  2. data에 events_only/only_last_per_room이 들어간다 (없으면 iOS 권한 박탈로 이어진다)
//  3. format은 들어가지 않는다 (Tuwunel이 content/sender/type을 빼버린다)
//  4. 로그아웃 경로에서 pusher를 **토큰이 살아 있는 동안** 지운다

import test from 'node:test';
import assert from 'node:assert/strict';
import { decodeApplicationServerKey, disablePush, enablePush, isIosDevice, pushAvailability, pusherPayload, readSubscription } from '../src/push.js';

const SAMPLE_KEY = 'BIY-ucjgRHPAYhdIh6AU91y-yCYABUaROXg3L-_ghS-tRwZAxJsu8KxM_p7pWyUcLxM_LDbGZJlzf54BkzeAuSI';
const PUSH = {
  gatewayUrl: 'https://push.example.test/_matrix/push/v1/notify',
  appId: 'com.example.familychat.web',
  applicationServerKey: SAMPLE_KEY,
};
const SUB = {
  endpoint: 'https://fcm.googleapis.com/fcm/send/abcdefghijklmnop',
  keys: { p256dh: 'P256DH-VALUE', auth: 'AUTH-VALUE' },
};

const subscription = (json = SUB, extra = {}) => ({ toJSON: () => json, ...extra });

test('readSubscription: 세 값이 모두 있어야 통과한다', () => {
  assert.deepEqual(readSubscription(subscription()), { endpoint: SUB.endpoint, p256dh: 'P256DH-VALUE', auth: 'AUTH-VALUE' });
  // toJSON이 없는 평범한 객체도 받는다.
  assert.deepEqual(readSubscription(SUB), { endpoint: SUB.endpoint, p256dh: 'P256DH-VALUE', auth: 'AUTH-VALUE' });

  // 하나라도 없으면 null — sygnal이 pushkey를 reject하고 홈서버가 pusher를 지운다.
  assert.equal(readSubscription(subscription({ ...SUB, endpoint: '' })), null);
  assert.equal(readSubscription(subscription({ endpoint: SUB.endpoint, keys: { p256dh: 'x' } })), null);
  assert.equal(readSubscription(subscription({ endpoint: SUB.endpoint, keys: null })), null);
  assert.equal(readSubscription(subscription({ endpoint: SUB.endpoint })), null);
  assert.equal(readSubscription(null), null);
  assert.equal(readSubscription({ toJSON: () => null }), null);
});

test('pusherPayload: pushkey는 endpoint가 아니라 p256dh다', () => {
  const payload = pusherPayload({ subscription: subscription(), push: PUSH, userId: '@me:example.test', deviceDisplayName: 'ABCDEF' });
  assert.equal(payload.pushkey, 'P256DH-VALUE');
  assert.notEqual(payload.pushkey, SUB.endpoint, 'endpoint를 pushkey로 쓰면 sygnal이 복호화 키를 잃는다');
  assert.equal(payload.data.endpoint, SUB.endpoint);
  assert.equal(payload.data.auth, 'AUTH-VALUE');
  assert.equal(payload.data.url, PUSH.gatewayUrl);
  assert.equal(payload.app_id, PUSH.appId);
  assert.equal(payload.kind, 'http');
  assert.equal(payload.lang, 'ko');
  assert.equal(payload.device_display_name, 'ABCDEF');
});

test('pusherPayload: iOS 권한 박탈을 막는 data 플래그가 들어간다', () => {
  const payload = pusherPayload({ subscription: subscription(), push: PUSH, userId: '@me:example.test' });
  assert.equal(payload.data.events_only, true, 'event_id 없는 정리용 푸시를 받으면 안 된다');
  assert.equal(payload.data.only_last_per_room, true);
  assert.equal(payload.append, true);
});

test('pusherPayload: format은 넣지 않는다', () => {
  // format: 'event_id_only'면 Tuwunel이 content/sender/type을 빼고 보내서
  // webpush 평문 페이로드가 사실상 비고 알림이 대체 문구밖에 못 된다.
  const payload = pusherPayload({ subscription: subscription(), push: PUSH, userId: '@me:example.test' });
  assert.ok(!('format' in payload), 'format이 최상위에 있으면 안 된다');
  assert.ok(!('format' in payload.data), 'format이 data에 있으면 안 된다');
});

test('pusherPayload: userId가 있으면 default_payload로 계정을 실어 보낸다', () => {
  const withUser = pusherPayload({ subscription: subscription(), push: PUSH, userId: '@me:example.test' });
  assert.deepEqual(withUser.data.default_payload, { account: '@me:example.test' });
  const without = pusherPayload({ subscription: subscription(), push: PUSH });
  assert.ok(!('default_payload' in without.data), '빈 계정을 실어 보내지 않는다');
});

test('pusherPayload: 설정이나 구독이 불완전하면 null', () => {
  assert.equal(pusherPayload({ subscription: subscription(), push: null }), null);
  assert.equal(pusherPayload({ subscription: subscription(), push: { ...PUSH, appId: '' } }), null);
  assert.equal(pusherPayload({ subscription: subscription(), push: { ...PUSH, gatewayUrl: '' } }), null);
  assert.equal(pusherPayload({ subscription: subscription({ endpoint: SUB.endpoint }), push: PUSH }), null);
});

test('decodeApplicationServerKey: 65바이트 Uint8Array로 바꾼다', () => {
  const bytes = decodeApplicationServerKey(SAMPLE_KEY);
  assert.ok(bytes instanceof Uint8Array);
  assert.equal(bytes.length, 65);
  assert.equal(bytes[0], 0x04);
  assert.deepEqual([...bytes], [...Buffer.from(SAMPLE_KEY, 'base64url')]);
});

test('decodeApplicationServerKey: 그럴듯하게 디코딩되는 쓰레기도 거부한다', () => {
  // atob("null")은 던지지 않고 길이 3짜리 바이트열을 만든다. 길이·접두를 보지
  // 않으면 그 가짜 키가 subscribe까지 간다.
  // 계약은 "던진다"이지 예외 종류가 아니다 — atob 자체가 DOMException을 던지는
  // 입력('undefined')과 조용히 통과시키는 입력('null')이 섞여 있다.
  for (const bad of ['null', '', 'AAAA', 'undefined', 'not base64!!']) {
    assert.throws(() => decodeApplicationServerKey(bad), `입력 ${JSON.stringify(bad)}는 던져야 한다`);
  }
  // 65바이트이지만 압축 점(0x02)인 경우 — 길이만 보면 통과한다.
  const compressed = Buffer.from(SAMPLE_KEY, 'base64url');
  compressed[0] = 0x02;
  assert.equal(compressed.length, 65);
  assert.throws(() => decodeApplicationServerKey(compressed.toString('base64url')), TypeError);
});

const CONFIGURED_KEY = new Uint8Array(Buffer.from(SAMPLE_KEY, 'base64url'));
const OTHER_KEY = (() => { const k = new Uint8Array(CONFIGURED_KEY); k[64] ^= 0xff; return k; })();

/**
 * enablePush/disablePush용 가짜 registration + client.
 *
 * 실제 브라우저 의미론을 따라간다: 구독 객체는 options.applicationServerKey를
 * 갖고, unsubscribe() 뒤에는 getSubscription()이 null을 돌려준다. 이걸 흉내내지
 * 않으면 "키가 바뀌면 다시 구독한다" 같은 계약을 구조적으로 시험할 수 없다.
 */
function harness({
  existing = null, existingKey = CONFIGURED_KEY, order = [],
  subscribeResult = SUB, subscribeThrows = null, setPusherThrows = null, removeThrows = null,
  unsubscribeResult = true, unsubscribeThrows = null, client: clientOverride,
} = {}) {
  const calls = { subscribe: [], setPusher: [], removePusher: [], unsubscribe: 0 };
  const makeSub = (json, key) => ({
    toJSON: () => json,
    options: { userVisibleOnly: true, applicationServerKey: key },
    unsubscribe: async () => {
      calls.unsubscribe += 1;
      order.push('unsubscribe');
      if (unsubscribeThrows) throw unsubscribeThrows;
      if (unsubscribeResult) current = null;
      return unsubscribeResult;
    },
  });
  let current = existing ? makeSub(existing, existingKey) : null;

  const client = clientOverride === undefined ? {
    setPusher: async (payload) => {
      calls.setPusher.push(payload);
      order.push('setPusher');
      if (setPusherThrows) throw setPusherThrows;
    },
    removePusher: async (pushKey, appId) => {
      calls.removePusher.push([pushKey, appId]);
      order.push('removePusher');
      if (removeThrows) throw removeThrows;
    },
  } : clientOverride;

  return {
    calls,
    order,
    get current() { return current; },
    registration: {
      pushManager: {
        getSubscription: async () => current,
        subscribe: async (opts) => {
          calls.subscribe.push(opts);
          order.push('subscribe');
          if (subscribeThrows) throw subscribeThrows;
          current = makeSub(subscribeResult, opts.applicationServerKey);
          return current;
        },
      },
    },
    client,
  };
}

test('enablePush: 권한이 없으면 구독하지 않는다', async () => {
  for (const permission of ['default', 'denied', undefined]) {
    const h = harness();
    const result = await enablePush({ registration: h.registration, push: PUSH, client: h.client, permission });
    assert.deepEqual(result, { ok: false, reason: 'no-permission' }, String(permission));
    assert.equal(h.calls.subscribe.length, 0, '권한 없이 구독을 시도하면 안 된다');
    assert.equal(h.calls.setPusher.length, 0);
  }
});

test('enablePush: 설정이 없으면 아무것도 하지 않는다', async () => {
  const h = harness();
  assert.deepEqual(await enablePush({ registration: h.registration, push: null, client: h.client, permission: 'granted' }), { ok: false, reason: 'not-configured' });
  assert.equal(h.calls.subscribe.length, 0);
});

test('enablePush: 구독하고 pusher를 등록한다', async () => {
  const h = harness();
  const result = await enablePush({ registration: h.registration, push: PUSH, client: h.client, userId: '@me:example.test', permission: 'granted' });
  assert.deepEqual(result, { ok: true, pushkey: 'P256DH-VALUE' });
  assert.equal(h.calls.subscribe.length, 1);
  assert.equal(h.calls.subscribe[0].userVisibleOnly, true, 'userVisibleOnly 없이는 구독이 거부된다');
  assert.ok(h.calls.subscribe[0].applicationServerKey instanceof Uint8Array);
  assert.equal(h.calls.setPusher.length, 1);
  assert.equal(h.calls.setPusher[0].pushkey, 'P256DH-VALUE');
});

test('enablePush: 같은 VAPID 키로 만든 구독은 재사용한다', async () => {
  const h = harness({ existing: SUB, existingKey: CONFIGURED_KEY });
  const result = await enablePush({ registration: h.registration, push: PUSH, client: h.client, permission: 'granted' });
  assert.equal(result.ok, true);
  assert.equal(h.calls.subscribe.length, 0, '다시 구독할 이유가 없다');
  assert.equal(h.calls.unsubscribe, 0);
  assert.equal(h.calls.setPusher.length, 1, '그래도 pusher는 다시 등록한다');
});

test('enablePush: VAPID 키가 바뀌면 낡은 구독을 풀고 다시 구독한다', async () => {
  // 키를 교체하면 기존 구독은 전부 무효가 된다. 그대로 쓰면 pusher 등록은
  // 성공하고 푸시 서비스만 거부해서 "등록은 됐는데 알림만 안 온다"가 된다.
  const h = harness({ existing: { endpoint: 'https://fcm.test/OLD', keys: { p256dh: 'OLD-P', auth: 'OLD-A' } }, existingKey: OTHER_KEY });
  const result = await enablePush({ registration: h.registration, push: PUSH, client: h.client, permission: 'granted' });
  assert.equal(result.ok, true);
  assert.deepEqual(h.order, ['unsubscribe', 'subscribe', 'setPusher'], '풀고 → 다시 구독 → 등록');
  assert.equal(result.pushkey, 'P256DH-VALUE', '새 구독의 pushkey여야 한다');
  assert.notEqual(result.pushkey, 'OLD-P');
});

test('enablePush: 브라우저가 구독의 키를 안 알려주면 재사용하지 않는다', async () => {
  // 판단할 수 없으면 재사용하지 않는다 — 조용히 틀린 키를 쓰는 것보다 낫다.
  const h = harness({ existing: SUB });
  h.registration.pushManager.getSubscription = async () => ({ toJSON: () => SUB, unsubscribe: async () => { h.order.push('unsubscribe'); return true; } });
  await enablePush({ registration: h.registration, push: PUSH, client: h.client, permission: 'granted' });
  assert.equal(h.calls.subscribe.length, 1, '다시 구독해야 한다');
});

test('enablePush: 홈서버에 보낼 수 없으면 구독부터 만들지 않는다', async () => {
  // 먼저 구독하면 pusher 없는 구독이 브라우저에 남고, 설정 오류가
  // pusher-failed(홈서버 거부)로 보고되어 진단이 흐려진다.
  for (const client of [null, undefined, {}]) {
    const h = harness({ client });
    const result = await enablePush({ registration: h.registration, push: PUSH, client, permission: 'granted' });
    assert.deepEqual(result, { ok: false, reason: 'no-client' }, String(client));
    assert.equal(h.calls.subscribe.length, 0, '구독을 만들면 안 된다');
  }
});

test('enablePush: pusher 등록에 실패하면 이번에 만든 구독을 되돌린다', async () => {
  const h = harness({ setPusherThrows: new Error('M_FORBIDDEN') });
  assert.deepEqual(await enablePush({ registration: h.registration, push: PUSH, client: h.client, permission: 'granted' }), { ok: false, reason: 'pusher-failed' });
  assert.deepEqual(h.order, ['subscribe', 'setPusher', 'unsubscribe'], '만든 구독을 되돌려야 한다');
  assert.equal(h.current, null, '홈서버가 모르는 구독을 남기면 안 된다');

  // 원래 있던 구독은 되돌리지 않는다 — 우리가 만든 게 아니다.
  const reused = harness({ existing: SUB, existingKey: CONFIGURED_KEY, setPusherThrows: new Error('M_FORBIDDEN') });
  await enablePush({ registration: reused.registration, push: PUSH, client: reused.client, permission: 'granted' });
  assert.equal(reused.calls.unsubscribe, 0);
});

test('enablePush: 실패는 던지지 않고 이유를 돌려준다', async () => {
  const denied = harness({ subscribeThrows: new Error('permission revoked') });
  assert.deepEqual(await enablePush({ registration: denied.registration, push: PUSH, client: denied.client, permission: 'granted' }), { ok: false, reason: 'subscribe-failed' });

  const broken = harness({ subscribeResult: { endpoint: SUB.endpoint } });
  assert.deepEqual(await enablePush({ registration: broken.registration, push: PUSH, client: broken.client, permission: 'granted' }), { ok: false, reason: 'incomplete-subscription' });
  assert.equal(broken.calls.setPusher.length, 0, '불완전한 구독을 홈서버에 등록하면 안 된다');
  assert.equal(broken.calls.unsubscribe, 1, '쓸 수 없는 구독은 되돌린다');

  const badKey = harness();
  assert.deepEqual(await enablePush({ registration: badKey.registration, push: { ...PUSH, applicationServerKey: 'null' }, client: badKey.client, permission: 'granted' }), { ok: false, reason: 'bad-key' });
  assert.equal(badKey.calls.subscribe.length, 0);

  const unsupported = await enablePush({ registration: {}, push: PUSH, client: {}, permission: 'granted' });
  assert.deepEqual(unsupported, { ok: false, reason: 'unsupported' });
});

test('disablePush: pusher를 먼저 지우고 구독을 해제한다', async () => {
  const h = harness({ existing: SUB });
  const result = await disablePush({ registration: h.registration, push: PUSH, client: h.client });
  assert.deepEqual(result, { ok: true, removed: true, unsubscribed: true });
  // pushkey는 구독에서만 읽을 수 있으므로 순서가 뒤집히면 지울 수가 없다.
  assert.deepEqual(h.order, ['removePusher', 'unsubscribe']);
  assert.deepEqual(h.calls.removePusher, [['P256DH-VALUE', PUSH.appId]]);
  assert.equal(h.current, null, '해제 뒤에는 구독이 남지 않는다');
});

test('disablePush: 홈서버에서 못 지워도 구독은 푼다', async () => {
  // 남은 pusher는 다음 발송에서 410을 받아 sygnal이 reject하고 홈서버가 정리한다.
  // 여기서 멈추면 이 브라우저는 계속 구독 상태로 남아 알림을 받는다.
  const h = harness({ existing: SUB, removeThrows: new Error('401') });
  const result = await disablePush({ registration: h.registration, push: PUSH, client: h.client });
  assert.equal(h.calls.unsubscribe, 1, '홈서버 실패가 구독 해제를 막으면 안 된다');
  assert.equal(result.removed, false);
  assert.equal(result.unsubscribed, true);
  // ok는 "이 기기가 더 이상 알림을 받지 않는다"는 뜻이다. 홈서버 정리 실패와
  // 무관하게 구독을 풀었으면 참이어야 설정 토글이 "꺼짐"을 표시할 수 있다.
  assert.equal(result.ok, true);
});

test('disablePush: ok는 "이 기기에 활성 구독이 없다"로 일관된다', async () => {
  // 앞서 ok = removed && unsubscribed로 두었더니 "아무것도 안 했다"가 성공,
  // "구독은 확실히 풀었다"가 실패로 보고되어 서로 모순이었다.
  const none = harness({ existing: null });
  assert.equal((await disablePush({ registration: none.registration, push: PUSH, client: none.client })).ok, true, '구독이 없으면 이미 꺼진 상태');

  const stuck = harness({ existing: SUB, unsubscribeResult: false });
  const result = await disablePush({ registration: stuck.registration, push: PUSH, client: stuck.client });
  assert.equal(result.removed, true, '홈서버에서는 지웠다');
  assert.equal(result.ok, false, '구독이 남아 있으면 아직 알림을 받는다');
});

test('disablePush: 구독이 없으면 조용히 끝난다', async () => {
  const h = harness({ existing: null });
  assert.deepEqual(await disablePush({ registration: h.registration, push: PUSH, client: h.client }), { ok: true, removed: false, unsubscribed: false });
  assert.equal(h.calls.removePusher.length, 0);
});

test('disablePush: 서비스워커가 없어도 터지지 않는다', async () => {
  assert.deepEqual(await disablePush({ registration: null, push: PUSH, client: {} }), { ok: true, removed: false, unsubscribed: false });
  assert.deepEqual(await disablePush({ registration: {}, push: PUSH, client: {} }), { ok: true, removed: false, unsubscribed: false });
});

// ---------------------------------------------------------------------------
// 설정 화면이 무엇을 보여줄지 (#167 C)

const BASE = { push: PUSH, hasServiceWorker: true, hasPushManager: true, hasNotification: true, permission: 'default', subscribed: false, isIos: false, isStandalone: false };

test('pushAvailability: 설정이 없으면 다른 모든 판단보다 먼저 알린다', () => {
  assert.equal(pushAvailability({ ...BASE, push: null }), 'not-configured');
  assert.equal(pushAvailability({ ...BASE, push: null, isIos: true }), 'not-configured');
});

test('pushAvailability: iOS 탭은 "지원 안 함"이 아니라 "홈화면에 추가"다', () => {
  // iOS Safari 탭에는 PushManager가 아예 없다. 기능 검사만 하면 "이 브라우저는
  // 지원하지 않습니다"가 뜨는데, 사실은 홈화면에 추가하면 된다. 그 안내를 못 보면
  // 가족은 영영 알림을 못 켠다.
  assert.equal(pushAvailability({ ...BASE, isIos: true, isStandalone: false, hasPushManager: false }), 'ios-needs-install');
  assert.equal(pushAvailability({ ...BASE, isIos: true, isStandalone: false }), 'ios-needs-install');
  // 홈화면 앱이면 평범하게 켤 수 있다.
  assert.equal(pushAvailability({ ...BASE, isIos: true, isStandalone: true }), 'off');
  assert.equal(pushAvailability({ ...BASE, isIos: true, isStandalone: true, subscribed: true }), 'on');
});

test('pushAvailability: 미지원·차단·켜짐·꺼짐', () => {
  assert.equal(pushAvailability({ ...BASE, hasServiceWorker: false }), 'unsupported');
  assert.equal(pushAvailability({ ...BASE, hasPushManager: false }), 'unsupported');
  assert.equal(pushAvailability({ ...BASE, hasNotification: false }), 'unsupported');
  assert.equal(pushAvailability({ ...BASE, permission: 'denied' }), 'denied');
  assert.equal(pushAvailability({ ...BASE, permission: 'granted', subscribed: true }), 'on');
  assert.equal(pushAvailability({ ...BASE, permission: 'granted', subscribed: false }), 'off');
  // 권한이 아직 default여도 켤 수 있는 상태로 보여준다 — 버튼을 눌러야 요청한다.
  assert.equal(pushAvailability({ ...BASE, permission: 'default' }), 'off');
});

test('isIosDevice: iPadOS 13+는 자신을 Macintosh로 보고한다', () => {
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)', maxTouchPoints: 5 }), true);
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X)', maxTouchPoints: 5 }), true);
  // iPadOS 13+ 데스크톱 모드: UA가 Macintosh다. 터치 지점 수로 가른다.
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 5 }), true);
  // 진짜 데스크톱 Mac은 maxTouchPoints가 0이다.
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 0 }), false);
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)', maxTouchPoints: 10 }), false);
  assert.equal(isIosDevice({}), false);
});
