// 서비스워커 푸시 핸들러 시험 (#167).
//
// sw.js는 번들되지 않고 import도 못 하므로(build.mjs는 자리표시자만 치환한다)
// 실제 파일을 node:vm에 올려 가짜 self에 리스너를 등록시키고, 진짜 push 이벤트를
// 흘려보낸다. 헬퍼 함수만 따로 시험하면 "리스너를 등록하지 않았다"는 결함을 놓친다.
//
// 시험이 지키는 계약은 하나다: **push를 받으면 어떤 입력에도 showNotification이
// 정확히 한 번 불린다.** 안 부르면 iOS Safari가 푸시 권한을 박탈한다(Apple 문서).

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { runInNewContext } from 'node:vm';
import { rewriteServiceWorker } from '../build-lib.mjs';

// 빌드가 내보내는 것과 같은 형태로 치환해서 올린다 — 자리표시자가 사라지면
// rewriteServiceWorker가 던지므로 이 시험이 그 회귀도 같이 막는다.
const SW_SOURCE = rewriteServiceWorker(readFileSync(join(import.meta.dirname, '..', 'sw.js'), 'utf-8'), {
  cacheName: 'familychat-test',
  shell: ['./', './index.html'],
});

// vm은 별도 realm이라 그 안에서 만들어진 객체는 프로토타입이 달라
// deepStrictEqual이 "same structure but not reference-equal"로 거부한다.
// 구조만 비교하면 되므로 평범한 값으로 낮춘다.
const plain = (value) => JSON.parse(JSON.stringify(value));

/** sw.js를 평가하고 { listeners, shown, focused, opened, posted }를 돌려준다. */
function loadServiceWorker() {
  const listeners = new Map();
  const shown = [];
  const posted = [];
  const focused = [];
  const opened = [];
  const windows = [];

  const self = {
    addEventListener: (type, handler) => { listeners.set(type, handler); },
    location: { origin: 'https://chat.example.test' },
    registration: {
      showNotification: (title, options) => { shown.push({ title, options }); return Promise.resolve(); },
    },
    clients: {
      claim: () => Promise.resolve(),
      matchAll: async () => windows,
      openWindow: async (url) => { opened.push(url); return null; },
    },
    skipWaiting: () => Promise.resolve(),
  };
  const sandbox = {
    self,
    caches: { open: async () => ({ addAll: async () => {}, put: async () => {} }), keys: async () => [], match: async () => undefined, delete: async () => {} },
    fetch: async () => ({ clone: () => ({}) }),
    URL,
    Date,
    console,
  };
  sandbox.globalThis = sandbox;
  runInNewContext(SW_SOURCE, sandbox);

  return { listeners, shown, posted, focused, opened, windows, self };
}

/** push 이벤트를 흘려보내고 waitUntil에 넘긴 작업이 끝날 때까지 기다린다. */
async function firePush(sw, payload, { raw = false } = {}) {
  const handler = sw.listeners.get('push');
  assert.ok(handler, 'push 리스너가 등록되어야 한다');
  const pending = [];
  const data = payload === undefined
    ? null
    : { json: () => { if (raw) throw new SyntaxError('not json'); return payload; } };
  handler({ data, waitUntil: (p) => pending.push(p) });
  assert.equal(pending.length, 1, 'push 핸들러는 waitUntil로 작업을 붙잡아야 한다');
  await Promise.all(pending);
  return sw.shown;
}

test('푸시: 평문 m.text는 보낸사람과 본문을 보여준다', async () => {
  const sw = loadServiceWorker();
  const shown = await firePush(sw, {
    room_id: '!fam:example.test',
    room_name: '가족방',
    sender: '@mom:example.test',
    sender_display_name: '엄마',
    event_id: '$abc',
    type: 'm.room.message',
    content: { msgtype: 'm.text', body: '저녁 먹었니' },
  });
  assert.equal(shown.length, 1);
  assert.equal(shown[0].title, '가족방');
  assert.equal(shown[0].options.body, '엄마: 저녁 먹었니');
  assert.equal(shown[0].options.tag, '!fam:example.test');
  assert.deepEqual(plain(shown[0].options.data), { roomId: '!fam:example.test', eventId: '$abc' });
});

test('푸시: megolm 봉투는 본문 없이 보낸사람만 알린다', async () => {
  const sw = loadServiceWorker();
  // E2EE 방의 content. sygnal은 2000자 넘는 ciphertext를 아예 떼어내므로
  // ciphertext가 있든 없든 같은 결과여야 한다.
  for (const content of [
    { algorithm: 'm.megolm.v1.aes-sha2', ciphertext: 'AwgAEnB…', sender_key: 'k', session_id: 's' },
    { algorithm: 'm.megolm.v1.aes-sha2', sender_key: 'k', session_id: 's' },
  ]) {
    const fresh = loadServiceWorker();
    const shown = await firePush(fresh, { room_id: '!fam:example.test', room_name: '가족방', sender_display_name: '아빠', content });
    assert.equal(shown.length, 1);
    assert.equal(shown[0].options.body, '아빠님이 메시지를 보냈습니다');
  }
  assert.equal(sw.shown.length, 0);
});

test('푸시: 본문에 암호문이 새지 않는다', async () => {
  const sw = loadServiceWorker();
  const ciphertext = 'AwgAEnB2ZXJ5U2VjcmV0Q2lwaGVydGV4dA';
  const shown = await firePush(sw, {
    room_name: '가족방',
    sender_display_name: '엄마',
    content: { algorithm: 'm.megolm.v1.aes-sha2', ciphertext, body: '이것도 보이면 안 된다' },
  });
  const rendered = JSON.stringify(shown[0]);
  assert.ok(!rendered.includes(ciphertext), '암호문이 알림에 들어가면 안 된다');
  assert.ok(!rendered.includes('이것도 보이면 안 된다'), 'algorithm이 있으면 body를 믿지 않는다');
});

test('푸시: 필드가 없어도 반드시 대체 알림을 띄운다 (iOS 권한 박탈 방지)', async () => {
  // Apple: push를 받고 showNotification을 안 부르면 Safari가 권한을 박탈한다.
  // 그래서 아래 어떤 입력에도 알림이 정확히 1건 떠야 한다.
  const cases = [
    ['페이로드 없음', undefined, {}],
    ['빈 객체', {}, {}],
    ['null', null, {}],
    ['배열', [1, 2, 3], {}],
    ['문자열', 'nope', {}],
    ['JSON 파싱 실패', {}, { raw: true }],
    ['event_id 없는 정리용 푸시', { room_id: '!r:example.test', counts: { unread: 0 } }, {}],
    ['이름만 있고 보낸사람 없음', { room_name: '가족방' }, {}],
  ];
  for (const [label, payload, opts] of cases) {
    const sw = loadServiceWorker();
    const shown = await firePush(sw, payload, opts);
    assert.equal(shown.length, 1, `${label}: 알림이 정확히 1건`);
    assert.ok(typeof shown[0].title === 'string' && shown[0].title.length > 0, `${label}: 제목 있음`);
    assert.ok(typeof shown[0].options.body === 'string' && shown[0].options.body.length > 0, `${label}: 본문 있음`);
  }
});

test('푸시: 표시명이 없으면 사용자 ID로, 그것도 없으면 일반 문구로 내려간다', async () => {
  // Tuwunel은 sender_display_name을 로컬 프로필에서 읽으므로 원격 사용자면 빠질 수 있다.
  const withId = loadServiceWorker();
  assert.equal((await firePush(withId, { sender: '@remote:other.test' }))[0].options.body, '@remote:other.test님이 메시지를 보냈습니다');

  const bare = loadServiceWorker();
  assert.equal((await firePush(bare, { room_id: '!r:example.test' }))[0].options.body, '새 메시지가 도착했습니다');
});

test('푸시: 방 이름이 없으면 별칭, 그것도 없으면 앱 이름을 제목으로 쓴다', async () => {
  const alias = loadServiceWorker();
  assert.equal((await firePush(alias, { room_alias: '#가족:example.test' }))[0].title, '#가족:example.test');

  const none = loadServiceWorker();
  assert.equal((await firePush(none, { sender_display_name: '엄마' }))[0].title, '패밀리챗');
});

test('푸시: 긴 본문은 잘라서 보여준다', async () => {
  const sw = loadServiceWorker();
  const long = '가'.repeat(500);
  const shown = await firePush(sw, { sender_display_name: '엄마', content: { msgtype: 'm.text', body: long } });
  assert.ok(shown[0].options.body.length < 260, `본문이 잘려야 한다: ${shown[0].options.body.length}`);
  assert.ok(shown[0].options.body.endsWith('…'));
});

test('푸시: 사진·파일은 본문(파일명) 대신 일반 문구를 쓴다', async () => {
  for (const msgtype of ['m.image', 'm.file', 'm.video', 'm.audio']) {
    const sw = loadServiceWorker();
    const shown = await firePush(sw, { sender_display_name: '엄마', content: { msgtype, body: 'IMG_4821.jpg' } });
    assert.equal(shown[0].options.body, '엄마님이 메시지를 보냈습니다', msgtype);
  }
});

test('알림 클릭: 열려 있는 창을 포커스하고 방 번호를 넘긴다', async () => {
  const sw = loadServiceWorker();
  const focused = [];
  const posted = [];
  sw.windows.push({ focus: async () => { focused.push(true); }, postMessage: (m) => posted.push(m) });

  const handler = sw.listeners.get('notificationclick');
  assert.ok(handler, 'notificationclick 리스너가 등록되어야 한다');
  let closed = false;
  const pending = [];
  handler({
    notification: { close: () => { closed = true; }, data: { roomId: '!fam:example.test', eventId: '$abc' } },
    waitUntil: (p) => pending.push(p),
  });
  await Promise.all(pending);

  assert.ok(closed, '알림은 닫아야 한다');
  assert.deepEqual(focused, [true]);
  assert.deepEqual(plain(posted), [{ type: 'familychat:open-room', roomId: '!fam:example.test' }]);
  assert.deepEqual(sw.opened, [], '이미 창이 있으면 새 창을 열지 않는다');
});

test('알림 클릭: 열린 창이 없으면 앱을 새로 연다', async () => {
  const sw = loadServiceWorker();
  const handler = sw.listeners.get('notificationclick');
  const pending = [];
  handler({ notification: { close: () => {}, data: { roomId: '!fam:example.test' } }, waitUntil: (p) => pending.push(p) });
  await Promise.all(pending);
  assert.deepEqual(sw.opened, ['./']);
});

test('알림 클릭: data가 없어도 터지지 않는다', async () => {
  const sw = loadServiceWorker();
  const handler = sw.listeners.get('notificationclick');
  const pending = [];
  handler({ notification: { close: () => {}, data: null }, waitUntil: (p) => pending.push(p) });
  await Promise.all(pending);
  assert.deepEqual(sw.opened, ['./']);
});

test('서비스워커는 앱 셸 캐시 핸들러를 그대로 유지한다', () => {
  const sw = loadServiceWorker();
  for (const type of ['install', 'activate', 'fetch', 'push', 'notificationclick']) {
    assert.ok(sw.listeners.has(type), `${type} 리스너`);
  }
});
