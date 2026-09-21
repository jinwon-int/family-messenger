import test from 'node:test';
import assert from 'node:assert/strict';
import {
  PERSIST_KEYS,
  VOLATILE_KEYS,
  clearSession,
  hasLiveSession,
  readPushPreference,
  readSession,
  savePushPreference,
  saveSession,
  splitSession,
} from '../src/session.js';

function memoryStorage() {
  const map = new Map();
  return {
    map,
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
}

test('세션 분리: 토큰은 휘발성, 식별자는 영속', () => {
  const { persistent, volatile } = splitSession({
    homeserverUrl: 'https://chat.example.com',
    userId: '@minseo:example.com',
    deviceId: 'DEVICE1',
    accessToken: 'syt_secret',
  });
  assert.deepEqual(persistent, { homeserverUrl: 'https://chat.example.com', userId: '@minseo:example.com', deviceId: 'DEVICE1' });
  assert.deepEqual(volatile, { accessToken: 'syt_secret' });
});

test('영속 저장소에 토큰이 섞여 와도 절대 저장하지 않는다', () => {
  const persistent = memoryStorage();
  const volatile = memoryStorage();
  saveSession(
    { homeserverUrl: 'https://chat.example.com', userId: '@a:example.com', deviceId: 'D', accessToken: 'syt_token' },
    { persistent, volatile },
  );
  for (const value of persistent.map.values()) {
    assert.notEqual(value, 'syt_token');
  }
  assert.equal(volatile.map.get(VOLATILE_KEYS.accessToken), 'syt_token');
  assert.equal(persistent.map.get(PERSIST_KEYS.userId), '@a:example.com');
});

test('읽기·지우기 왕복', () => {
  const persistent = memoryStorage();
  const volatile = memoryStorage();
  saveSession({ homeserverUrl: 'https://chat.example.com', userId: '@a:example.com', deviceId: 'D', accessToken: 'tok' }, { persistent, volatile });
  const read = readSession({ persistent, volatile });
  assert.equal(read.accessToken, 'tok');
  assert.equal(read.deviceId, 'D');
  assert.ok(hasLiveSession(read));
  clearSession({ persistent, volatile });
  assert.deepEqual(readSession({ persistent, volatile }), {});
  assert.equal(hasLiveSession({}), false);
  assert.equal(hasLiveSession({ accessToken: 't' }), false);
  assert.equal(hasLiveSession({ accessToken: 't', homeserverUrl: 'h', userId: '@a:example.com' }), true);
});

test('암호화 저장소 마커(cryptoDeviceId)는 영속 저장소에만, 토큰과 분리되어 저장된다', () => {
  const persistent = memoryStorage();
  const volatile = memoryStorage();
  const stores = { persistent, volatile };
  saveSession({ homeserverUrl: 'https://chat.example.com', userId: '@a:example.com', deviceId: 'D', accessToken: 'tok' }, stores);
  assert.equal(readSession(stores).cryptoDeviceId, undefined);
  saveSession({ cryptoDeviceId: 'D' }, stores);
  const read = readSession(stores);
  assert.equal(read.cryptoDeviceId, 'D');
  assert.equal(read.accessToken, 'tok');
  assert.equal(volatile.getItem('familychat.cryptoDeviceId'), null, '마커는 sessionStorage에 가지 않는다');
  clearSession(stores);
  assert.equal(readSession(stores).cryptoDeviceId, undefined);
});

// 알림 선호 (#167 C). 세션이 아니라 이 브라우저의 선택이라 clearSession이 지우지 않는다.
test('알림 선호: 끄기는 새로고침과 로그아웃을 넘어 유지된다', () => {
  const persistent = new Map();
  const volatile = new Map();
  const stores = {
    persistent: { getItem: (k) => persistent.get(k) ?? null, setItem: (k, v) => persistent.set(k, v), removeItem: (k) => persistent.delete(k) },
    volatile: { getItem: (k) => volatile.get(k) ?? null, setItem: (k, v) => volatile.set(k, v), removeItem: (k) => volatile.delete(k) },
  };
  // 고른 적이 없으면 null — 권한이 이미 granted인 기기는 예전처럼 자동 등록된다.
  assert.equal(readPushPreference(stores), null);

  savePushPreference('off', stores);
  assert.equal(readPushPreference(stores), 'off');

  // ⚠ 로그아웃해도 남아야 한다. disablePush는 브라우저 권한을 취소할 수 없어서
  //    끈 뒤에도 permission은 granted다 — 선호가 사라지면 다음 로그인에 되살아난다.
  clearSession(stores);
  assert.equal(readPushPreference(stores), 'off', '로그아웃이 알림 선호를 지우면 끄기가 무효가 된다');

  savePushPreference('on', stores);
  assert.equal(readPushPreference(stores), 'on');

  // 알 수 없는 값은 무시한다.
  savePushPreference('maybe', stores);
  assert.equal(readPushPreference(stores), 'on');
});

test('알림 선호: 저장소가 없어도 터지지 않는다', () => {
  assert.equal(readPushPreference(), null);
  assert.equal(readPushPreference({}), null);
  assert.doesNotThrow(() => savePushPreference('off'));
  assert.doesNotThrow(() => savePushPreference('off', {}));
});
