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

/**
 * sw.js를 평가한다.
 * @param {{showNotification?: (n: number) => void, matchAll?: () => void, openWindow?: () => void}} faults
 *   단계별로 던지게 만드는 훅. 성공 경로만 시험하면 거부 전파 결함을 놓친다.
 */
function loadServiceWorker(faults = {}) {
  const listeners = new Map();
  const shown = [];
  const opened = [];
  const windows = [];
  // 실패한 호출은 shown에 쌓이지 않으므로 시도 횟수를 따로 센다.
  let attempts = 0;

  const self = {
    addEventListener: (type, handler) => { listeners.set(type, handler); },
    location: { origin: 'https://chat.example.test' },
    registration: {
      showNotification: (title, options) => {
        if (faults.showNotification) {
          const failure = faults.showNotification(attempts++);
          if (failure) return Promise.reject(failure);
        }
        shown.push({ title, options });
        return Promise.resolve();
      },
    },
    clients: {
      claim: () => Promise.resolve(),
      matchAll: async () => {
        if (faults.matchAll) throw faults.matchAll();
        return windows;
      },
      openWindow: async (url) => {
        if (faults.openWindow) throw faults.openWindow();
        opened.push(url);
        return null;
      },
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

  return { listeners, shown, opened, windows, self };
}

/** notificationclick을 발사하고 waitUntil이 거부하지 않는지까지 확인한다. */
async function fireClick(sw, data = { roomId: '!fam:example.test', eventId: '$abc' }) {
  const handler = sw.listeners.get('notificationclick');
  assert.ok(handler, 'notificationclick 리스너가 등록되어야 한다');
  const pending = [];
  let closed = false;
  handler({ notification: { close: () => { closed = true; }, data }, waitUntil: (p) => pending.push(p) });
  assert.equal(pending.length, 1);
  // 거부가 새어나가면 클릭 경로가 통째로 죽은 것이다 — 통과시키지 않는다.
  await assert.doesNotReject(() => Promise.all(pending));
  return { closed };
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
  // waitUntil이 거부하면 push 이벤트가 실패로 끝나고 브라우저가 "site has been
  // updated in the background"를 대신 띄운다 — 막으려던 바로 그 결과다.
  await assert.doesNotReject(() => Promise.all(pending), 'waitUntil은 거부하면 안 된다');
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
  // E2EE 방의 content. sygnal은 2000자 넘는 ciphertext를 아예 떼어내므로
  // ciphertext가 있든 없든 같은 결과여야 한다.
  for (const content of [
    { algorithm: 'm.megolm.v1.aes-sha2', ciphertext: 'AwgAEnB…', sender_key: 'k', session_id: 's' },
    { algorithm: 'm.megolm.v1.aes-sha2', sender_key: 'k', session_id: 's' },
  ]) {
    const sw = loadServiceWorker();
    const shown = await firePush(sw, { room_id: '!fam:example.test', room_name: '가족방', sender_display_name: '아빠', type: 'm.room.encrypted', content });
    assert.equal(shown.length, 1);
    assert.equal(shown[0].options.body, '아빠님이 메시지를 보냈습니다');
  }
});

test('푸시: 봉투 판정은 값이 아니라 키 존재로 한다', async () => {
  // content는 보내는 쪽이 완전히 통제하는 JSON이다. algorithm의 truthiness만 보면
  // 빈 문자열·0·null로 검사를 지나가고 ciphertext 옆의 body가 알림에 그대로 뜬다.
  const cases = [
    ['algorithm 빈 문자열', { algorithm: '', ciphertext: 'CT', msgtype: 'm.text', body: '새면 안 됨1' }],
    ['algorithm 0', { algorithm: 0, ciphertext: 'CT', msgtype: 'm.text', body: '새면 안 됨2' }],
    ['algorithm null', { algorithm: null, ciphertext: 'CT', msgtype: 'm.text', body: '새면 안 됨3' }],
    ['algorithm 없이 ciphertext만', { ciphertext: 'CT', msgtype: 'm.text', body: '새면 안 됨4' }],
  ];
  for (const [label, content] of cases) {
    const sw = loadServiceWorker();
    const shown = await firePush(sw, { room_name: '가족방', sender_display_name: '엄마', content });
    assert.equal(shown[0].options.body, '엄마님이 메시지를 보냈습니다', label);
    assert.ok(!JSON.stringify(shown[0]).includes('CT'), `${label}: 암호문 누출`);
  }
});

test('푸시: 상위 type이 m.room.encrypted면 msgtype이 있어도 본문을 믿지 않는다', async () => {
  // m.room.encrypted는 보통 msgtype이 없어 화이트리스트가 통째로 건너뛰어진다.
  const sw = loadServiceWorker();
  const shown = await firePush(sw, {
    room_name: '가족방',
    sender_display_name: '엄마',
    type: 'm.room.encrypted',
    content: { msgtype: 'm.text', body: '새면 안 되는 본문' },
  });
  assert.equal(shown[0].options.body, '엄마님이 메시지를 보냈습니다');
  assert.ok(!JSON.stringify(shown[0]).includes('새면 안 되는 본문'));
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
  for (const msgtype of ['m.image', 'm.file', 'm.video', 'm.audio', 'm.location']) {
    const sw = loadServiceWorker();
    const shown = await firePush(sw, { sender_display_name: '엄마', content: { msgtype, body: 'IMG_4821.jpg' } });
    assert.equal(shown[0].options.body, '엄마님이 메시지를 보냈습니다', msgtype);
  }
});

test('푸시: msgtype이 없는 이벤트는 본문을 보여주지 않는다 (m.sticker)', async () => {
  // m.sticker content에는 msgtype이 없고 body(스티커 설명)만 있다. msgtype 미지정을
  // 통과시키면 화이트리스트가 그냥 우회된다 — 적대적 입력이 아니라 평범한 사용이다.
  const sw = loadServiceWorker();
  const shown = await firePush(sw, { room_name: '가족방', sender_display_name: '엄마', type: 'm.sticker', content: { body: '웃는 강아지.png', url: 'mxc://x/y' } });
  assert.equal(shown[0].options.body, '엄마님이 메시지를 보냈습니다');
  assert.ok(!JSON.stringify(shown[0]).includes('웃는 강아지'));
});

test('푸시: 에모트는 콜론 없이 렌더한다', async () => {
  const sw = loadServiceWorker();
  const shown = await firePush(sw, { sender_display_name: '엄마', content: { msgtype: 'm.emote', body: '웃었습니다' } });
  assert.equal(shown[0].options.body, '엄마 웃었습니다');
});

test('푸시: 내용 모르는 대체 알림은 방 태그를 재사용하지 않는다', async () => {
  // 방 태그를 쓰면 방금 띄운 정보 있는 알림을 대체 문구로 덮어쓴다. events_only가
  // 사라져 정리용 푸시가 오는 상황 — 대체 알림이 필요한 바로 그 상황 — 에서 발생한다.
  const sw = loadServiceWorker();
  const first = await firePush(sw, {
    room_id: '!fam:example.test', room_name: '가족방', sender_display_name: '엄마',
    event_id: '$abc', content: { msgtype: 'm.text', body: '저녁 먹었니' },
  });
  assert.equal(first[0].options.tag, '!fam:example.test');

  // event_id 없는 정리용 푸시가 같은 방으로 들어온다.
  const second = await firePush(sw, { room_id: '!fam:example.test', counts: { unread: 0 } });
  assert.equal(second.length, 2, '알림은 두 건 다 떠야 한다');
  assert.notEqual(second[1].options.tag, second[0].options.tag, '정보 있는 알림을 덮어쓰면 안 된다');
});

test('푸시: 긴 본문을 잘라도 이모지가 쪼개지지 않는다', async () => {
  const sw = loadServiceWorker();
  // 경계에 서로게이트 쌍을 놓는다. UTF-16 단위로 자르면 단독 서로게이트가 남는다.
  const body = 'x'.repeat(199) + '👨‍👩‍👧'.slice(0, 2) + 'y'.repeat(50);
  const shown = await firePush(sw, { content: { msgtype: 'm.text', body } });
  const text = shown[0].options.body;
  for (const unit of text) {
    const code = unit.codePointAt(0);
    assert.ok(!(code >= 0xd800 && code <= 0xdfff), `단독 서로게이트가 남았다: U+${code.toString(16)}`);
  }
});

test('푸시: showNotification이 거부해도 이벤트를 실패로 끝내지 않는다', async () => {
  // 거부가 waitUntil로 새면 push 이벤트가 실패하고 브라우저가 "site has been updated
  // in the background"를 대신 띄운다 — 막으려던 결과가 그대로 난다.
  const always = loadServiceWorker({ showNotification: () => new Error('No notification permission has been granted') });
  await firePush(always, { room_name: '가족방', sender_display_name: '엄마' }); // doesNotReject는 firePush 안에서 확인한다
  assert.equal(always.shown.length, 0, '권한이 없으면 뜰 수 없다');

  // 첫 호출만 실패하는 경우(옵션이 문제였던 경우) 최소 옵션으로 한 번 더 시도해야 한다.
  const once = loadServiceWorker({ showNotification: (n) => (n === 0 ? new TypeError('bad option') : null) });
  const shown = await firePush(once, { room_name: '가족방', sender_display_name: '엄마', event_id: '$a', room_id: '!r:x' });
  assert.equal(shown.length, 1, '재시도로 알림이 떠야 한다');
  assert.equal(shown[0].title, '패밀리챗');
  assert.equal(shown[0].options.body, '새 메시지가 도착했습니다');
});

/** 포커스 가능한 가짜 창. reject=true면 Chrome의 InvalidAccessError를 흉내낸다. */
function fakeWindow({ reject = false, postThrows = false } = {}) {
  const win = { focused: 0, posted: [] };
  win.focus = async () => {
    if (reject) throw new Error('Not allowed to focus a window.');
    win.focused += 1;
  };
  win.postMessage = (message) => {
    if (postThrows) throw new Error('postMessage failed');
    win.posted.push(message);
  };
  return win;
}

test('알림 클릭: 열려 있는 창을 포커스하고 방 번호를 넘긴다', async () => {
  const sw = loadServiceWorker();
  const win = fakeWindow();
  sw.windows.push(win);

  const { closed } = await fireClick(sw);

  assert.ok(closed, '알림은 닫아야 한다');
  assert.equal(win.focused, 1);
  assert.deepEqual(plain(win.posted), [{ type: 'familychat:open-room', roomId: '!fam:example.test' }]);
  assert.deepEqual(sw.opened, [], '이미 창이 있으면 새 창을 열지 않는다');
});

test('알림 클릭: 첫 창이 포커스를 거부하면 다음 창을 시도한다', async () => {
  // Chrome은 사용자 제스처 판정에 따라 focus()를 InvalidAccessError로 거부한다.
  // 거부가 전파되면 나머지 창도 postMessage도 openWindow 폴백도 전부 사라진다.
  const sw = loadServiceWorker();
  const bad = fakeWindow({ reject: true });
  const good = fakeWindow();
  sw.windows.push(bad, good);

  await fireClick(sw);

  assert.equal(good.focused, 1, '두 번째 창을 시도해야 한다');
  assert.deepEqual(plain(good.posted), [{ type: 'familychat:open-room', roomId: '!fam:example.test' }]);
  assert.deepEqual(sw.opened, []);
});

test('알림 클릭: 모든 창이 포커스를 거부하면 새 창으로 폴백한다', async () => {
  const sw = loadServiceWorker();
  sw.windows.push(fakeWindow({ reject: true }), fakeWindow({ reject: true }));
  await fireClick(sw);
  assert.deepEqual(sw.opened, ['./']);
});

test('알림 클릭: matchAll이 거부해도 새 창으로 폴백한다', async () => {
  const sw = loadServiceWorker({ matchAll: () => new Error('matchAll failed') });
  await fireClick(sw);
  assert.deepEqual(sw.opened, ['./']);
});

test('알림 클릭: openWindow가 거부해도 이벤트를 실패로 끝내지 않는다', async () => {
  const sw = loadServiceWorker({ openWindow: () => new Error('Not allowed to open a window.') });
  await fireClick(sw); // fireClick이 doesNotReject를 확인한다
  assert.deepEqual(sw.opened, []);
});

test('알림 클릭: postMessage가 던져도 새 창을 열지 않는다', async () => {
  const sw = loadServiceWorker();
  const win = fakeWindow({ postThrows: true });
  sw.windows.push(win);
  await fireClick(sw);
  assert.equal(win.focused, 1, '포커스는 성공했다');
  assert.deepEqual(sw.opened, [], '포커스가 됐으면 창을 더 열지 않는다');
});

test('알림 클릭: 열린 창이 없으면 앱을 새로 연다', async () => {
  const sw = loadServiceWorker();
  await fireClick(sw);
  assert.deepEqual(sw.opened, ['./']);
});

test('알림 클릭: data가 없어도 터지지 않는다', async () => {
  const sw = loadServiceWorker();
  await fireClick(sw, null);
  assert.deepEqual(sw.opened, ['./']);
});

test('서비스워커는 앱 셸 캐시 핸들러를 그대로 유지한다', () => {
  const sw = loadServiceWorker();
  for (const type of ['install', 'activate', 'fetch', 'push', 'notificationclick']) {
    assert.ok(sw.listeners.has(type), `${type} 리스너`);
  }
});
