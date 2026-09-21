// pusher 등록/해제 시험 (#167 B).
//
// 이 모듈이 지키는 계약은 네 가지다:
//  1. pushkey는 endpoint가 아니라 p256dh다 (sygnal이 그렇게 읽는다)
//  2. data에 events_only/only_last_per_room이 들어간다 (없으면 iOS 권한 박탈로 이어진다)
//  3. format은 들어가지 않는다 (Tuwunel이 content/sender/type을 빼버린다)
//  4. 로그아웃 경로에서 pusher를 **토큰이 살아 있는 동안** 지운다

import test from 'node:test';
import assert from 'node:assert/strict';
import { decodeApplicationServerKey, disablePush, enablePush, pusherPayload, readSubscription } from '../src/push.js';

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

/** enablePush/disablePush용 가짜 registration + client. */
function harness({ existing = null, subscribeResult = subscription(), subscribeThrows = null, setPusherThrows = null, removeThrows = null, unsubscribeResult = true, unsubscribeThrows = null } = {}) {
  const calls = { subscribe: [], setPusher: [], removePusher: [], unsubscribe: 0 };
  const sub = existing
    ? {
      toJSON: () => existing,
      unsubscribe: async () => {
        calls.unsubscribe += 1;
        if (unsubscribeThrows) throw unsubscribeThrows;
        return unsubscribeResult;
      },
    }
    : null;
  return {
    calls,
    registration: {
      pushManager: {
        getSubscription: async () => sub,
        subscribe: async (opts) => {
          calls.subscribe.push(opts);
          if (subscribeThrows) throw subscribeThrows;
          return subscribeResult;
        },
      },
    },
    client: {
      setPusher: async (payload) => {
        calls.setPusher.push(payload);
        if (setPusherThrows) throw setPusherThrows;
      },
      removePusher: async (pushKey, appId) => {
        calls.removePusher.push([pushKey, appId]);
        if (removeThrows) throw removeThrows;
      },
    },
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

test('enablePush: 이미 구독이 있으면 재사용한다', async () => {
  const h = harness({ existing: SUB });
  const result = await enablePush({ registration: h.registration, push: PUSH, client: h.client, permission: 'granted' });
  assert.equal(result.ok, true);
  assert.equal(h.calls.subscribe.length, 0, '다시 구독할 이유가 없다');
  assert.equal(h.calls.setPusher.length, 1, '그래도 pusher는 다시 등록한다');
});

test('enablePush: 실패는 던지지 않고 이유를 돌려준다', async () => {
  const denied = harness({ subscribeThrows: new Error('permission revoked') });
  assert.deepEqual(await enablePush({ registration: denied.registration, push: PUSH, client: denied.client, permission: 'granted' }), { ok: false, reason: 'subscribe-failed' });

  const broken = harness({ subscribeResult: subscription({ endpoint: SUB.endpoint }) });
  assert.deepEqual(await enablePush({ registration: broken.registration, push: PUSH, client: broken.client, permission: 'granted' }), { ok: false, reason: 'incomplete-subscription' });
  assert.equal(broken.calls.setPusher.length, 0, '불완전한 구독을 홈서버에 등록하면 안 된다');

  const rejected = harness({ setPusherThrows: new Error('M_FORBIDDEN') });
  assert.deepEqual(await enablePush({ registration: rejected.registration, push: PUSH, client: rejected.client, permission: 'granted' }), { ok: false, reason: 'pusher-failed' });

  const unsupported = await enablePush({ registration: {}, push: PUSH, client: {}, permission: 'granted' });
  assert.deepEqual(unsupported, { ok: false, reason: 'unsupported' });
});

test('disablePush: pusher를 먼저 지우고 구독을 해제한다', async () => {
  const h = harness({ existing: SUB });
  const order = [];
  const client = {
    removePusher: async (...args) => { order.push(['removePusher', ...args]); },
  };
  const registration = {
    pushManager: {
      getSubscription: async () => ({
        toJSON: () => SUB,
        unsubscribe: async () => { order.push(['unsubscribe']); return true; },
      }),
    },
  };
  const result = await disablePush({ registration, push: PUSH, client });
  assert.deepEqual(result, { ok: true, removed: true, unsubscribed: true });
  // pushkey는 구독에서만 읽을 수 있으므로 순서가 뒤집히면 지울 수가 없다.
  assert.deepEqual(order, [['removePusher', 'P256DH-VALUE', PUSH.appId], ['unsubscribe']]);
  assert.equal(h.calls.unsubscribe, 0);
});

test('disablePush: 홈서버에서 못 지워도 구독은 푼다', async () => {
  // 남은 pusher는 다음 발송에서 410을 받아 sygnal이 reject하고 홈서버가 정리한다.
  // 여기서 멈추면 이 브라우저는 계속 구독 상태로 남아 알림을 받는다.
  const h = harness({ existing: SUB, removeThrows: new Error('401') });
  const result = await disablePush({ registration: h.registration, push: PUSH, client: h.client });
  assert.deepEqual(result, { ok: false, removed: false, unsubscribed: true });
  assert.equal(h.calls.unsubscribe, 1, '홈서버 실패가 구독 해제를 막으면 안 된다');
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
