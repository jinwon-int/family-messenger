// 대화 목록 순서 저장 — main.js의 저장/되울림 처리를 실제 부트스트랩으로 검사한다.
// 가짜 클라이언트는 matrix-js-sdk 42.3.0 setAccountData의 두 성질을 흉내 낸다:
//   (1) 저장소 값과 같으면 PUT 없이 바로 끝난다,
//   (2) 같은 종류의 account data가 동기화로 "아무거나" 돌아오면 끝난다(내 값인지 보지 않는다).
// 저장을 겹쳐 보내던 첫 구현은 (1) 때문에 빠른 되돌리기를 잃고, (2) 때문에 다른 기기의 순서를
// 무시했다(독립 검토에서 재현). 합성 데이터만 쓰고 네트워크는 없다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { Window } from 'happy-dom';
import { saveSession } from '../../src/session.js';

const bundle = await build({
  entryPoints: [new URL('../../src/main.js', import.meta.url).pathname],
  bundle: true, write: false, format: 'iife', platform: 'browser',
  plugins: [{ name: 'synthetic-matrix', setup(builder) {
    builder.onResolve({ filter: /\/matrix\/client\.js$/ }, () => ({ path: 'client', namespace: 'fixture' }));
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
      export const createFamilyClient = async () => window.testClient;
      export const loginWithPassword = async () => { throw new Error('Unexpected login'); };
      export class PlaintextRefusedError extends Error {}
    ` }));
  } }],
});

const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const tick = () => new Promise((resolve) => setTimeout(resolve, 20));
const settle = async () => { for (let i = 0; i < 8; i++) await tick(); };

async function app(t) {
  const window = new Window({ url: 'https://chat.example.test/' });
  t.after(() => window.happyDOM.abort());
  const { document } = window;
  document.body.innerHTML = '<div id="app"></div>';
  window.fetch = async () => ({ ok: true, json: async () => ({}) });
  const summaries = ['a', 'b', 'c'].map((id) => ({
    roomId: `!${id}:example.test`, displayName: id, kind: 'private', memberCount: 2, agents: [],
  }));
  const sync = { store: [], puts: [], waiting: [], orderChanged: () => {}, fail: false };
  window.testClient = {
    enableEncryption: async () => {}, start() {}, onTimeline() {}, onVerificationRequest() {},
    onRoomAdded() {}, onTyping() {}, roomSummaries: () => summaries, inviteSummaries: () => [],
    canLoadEarlier: () => false, roomMemberHandles: () => [], sendText: async () => {}, liveTimelineEvents: () => [],
    roomOrder: () => [...sync.store],
    onRoomOrderChange(callback) { sync.orderChanged = callback; },
    setRoomOrder(ids) {
      if (sync.fail) return Promise.reject(new Error('synthetic 500'));
      if (same(sync.store, ids)) return Promise.resolve(); // (1) PUT 없음
      sync.puts.push([...ids]);
      return new Promise((resolve) => sync.waiting.push(resolve));
    },
  };
  // 서버가 이 계정의 room_order를 동기화로 내려보낸다(내 저장의 되울림이든 다른 기기의 값이든).
  sync.deliver = (ids) => {
    sync.store = [...ids];
    sync.orderChanged([...ids]);
    const waiting = sync.waiting.splice(0);
    for (const resolve of waiting) resolve(); // (2) 어떤 값이 와도 기다리던 저장이 끝난다
  };
  saveSession({ homeserverUrl: 'https://matrix.example.test', userId: '@reader:example.test', deviceId: 'TEST', accessToken: 'synthetic' }, {
    persistent: window.localStorage, volatile: window.sessionStorage,
  });
  window.eval(bundle.outputFiles[0].text);
  for (let i = 0; i < 20 && !document.querySelector('.room-item'); i++) await new Promise((resolve) => setImmediate(resolve));
  const shown = () => [...document.querySelectorAll('ul.rooms > li')].map((li) => li.dataset.roomId.slice(1, 2));
  const press = (id, dir) => [...document.querySelectorAll('ul.rooms > li')]
    .find((li) => li.dataset.roomId === `!${id}:example.test`).querySelector(`.order-${dir}`).click();
  const ids = (letters) => letters.map((x) => `!${x}:example.test`);
  document.querySelector('.order-toggle').click(); // 순서 편집 시작
  return { window, document, sync, shown, press, ids };
}

test('빠른 되돌리기(▼ 뒤 ▲)는 앞 저장의 되울림에 덮이지 않고 서버에도 되돌린 순서가 남는다', async (t) => {
  const { sync, shown, press, ids } = await app(t);
  assert.deepEqual(shown(), ['a', 'b', 'c'], '저장된 순서가 없으면 기본(이름) 순서');
  press('b', 'down');
  assert.deepEqual(shown(), ['a', 'c', 'b']);
  press('b', 'up');
  assert.deepEqual(shown(), ['a', 'b', 'c'], '화면은 즉시 되돌아간다');
  assert.equal(sync.puts.length, 1, '저장은 한 번에 하나만 나간다');

  sync.deliver(sync.puts[0]); // 첫 저장의 되울림
  await settle();
  assert.deepEqual(shown(), ['a', 'b', 'c'], '옛 되울림으로 튀지 않는다');
  assert.deepEqual(sync.puts.at(-1), ids(['a', 'b', 'c']), '되돌린 순서를 이어서 저장한다');

  sync.deliver(sync.puts.at(-1));
  await settle();
  assert.deepEqual(shown(), ['a', 'b', 'c']);
  assert.deepEqual(sync.store, ids(['a', 'b', 'c']), '서버에도 되돌린 순서가 남는다');
  assert.equal(sync.puts.length, 2);
});

test('내 저장 중에 다른 기기가 바꾼 순서가 오면, 저장이 끝난 뒤 그 순서로 맞춘다', async (t) => {
  const { sync, shown, press, ids } = await app(t);
  press('b', 'down');
  assert.equal(sync.puts.length, 1);
  sync.deliver(ids(['c', 'b', 'a'])); // 다른 기기의 저장이 내 되울림보다 먼저 도착(SDK는 이걸로 내 저장을 끝낸다)
  await settle();
  assert.deepEqual(shown(), ['c', 'b', 'a'], '서버와 같은 순서를 보여 준다');
  assert.equal(sync.puts.length, 1, '내 옛 순서를 다시 보내지 않는다');
});

test('저장 중이 아닐 때 다른 기기에서 옮기면 바로 반영된다', async (t) => {
  const { sync, shown, ids } = await app(t);
  sync.deliver(ids(['c', 'a', 'b']));
  await settle();
  assert.deepEqual(shown(), ['c', 'a', 'b']);
});

test('저장에 실패하면 알리고 서버의 마지막 순서로 되돌린다', async (t) => {
  const { document, sync, shown, press } = await app(t);
  sync.fail = true;
  press('a', 'down');
  assert.deepEqual(shown(), ['b', 'a', 'c']);
  await settle();
  assert.deepEqual(shown(), ['a', 'b', 'c']);
  assert.match(document.body.textContent, /대화 순서를 저장하지 못했습니다/);
});
