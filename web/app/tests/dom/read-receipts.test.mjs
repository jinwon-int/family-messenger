// 안 읽음 NEW 배지 + 읽음 확인 전송 — 실제 부트스트랩·UI·SDK Room(영수증 구조, 로컬 에코 영수증)을
// 쓰고 네트워크만 가짜다(authedRequest 기록). 테스트 계정·운영 세션 데이터 없음.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { build } from 'esbuild';
import { Window } from 'happy-dom';
import { ClientAdapter } from '../../src/matrix/client.js';
import { saveSession } from '../../src/session.js';

const sdk = createRequire(import.meta.url)('matrix-js-sdk');
const bundle = await build({
  entryPoints: [new URL('../../src/main.js', import.meta.url).pathname],
  bundle: true, write: false, format: 'iife', platform: 'browser',
  plugins: [{ name: 'test-client', setup(builder) {
    builder.onResolve({ filter: /\/matrix\/client\.js$/ }, () => ({ path: 'client', namespace: 'fixture' }));
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
      export const createFamilyClient = async () => window.testClient;
      export const loginWithPassword = async () => { throw new Error('Unexpected login'); };
      export class PlaintextRefusedError extends Error {}
    ` }));
  } }],
});
const flush = () => new Promise((resolve) => setImmediate(resolve));
const me = '@owner:example.test';
const mom = '@mom:example.test';
const roomA = '!a:example.test';
const roomB = '!b:example.test';

async function app(t, initial = [], { failReceipts = false } = {}) {
  const window = new Window({ url: 'https://chat.example.test/' });
  t.after(() => window.happyDOM.abort());
  window.document.body.innerHTML = '<div id="app"></div>';
  window.fetch = async () => ({ ok: true, json: async () => ({}) });
  const warnings = [];
  window.console.warn = (...args) => warnings.push(args.map(String).join(' '));
  const client = sdk.createClient({ baseUrl: 'https://matrix.example.test', userId: me, accessToken: 'synthetic', timelineSupport: true });
  // 영수증 POST만 기록한다(로컬 에코 영수증은 SDK가 그대로 남긴다).
  const receipts = [];
  client.http.authedRequest = async (method, path) => {
    receipts.push(decodeURIComponent(path));
    if (failReceipts) throw new Error('synthetic network failure');
    return {};
  };
  const rooms = {};
  for (const id of [roomA, roomB]) {
    rooms[id] = new sdk.Room(id, client, me, { timelineSupport: true });
    client.store.storeRoom(rooms[id]);
    client.reEmitter.reEmit(rooms[id], ['Room.timeline', 'Room.redaction', 'Room.localEchoUpdated', 'Room.timelineReset', 'Room.receipt']);
  }
  const adapter = new ClientAdapter(client, me);
  let synced;
  Object.assign(adapter, {
    enableEncryption: async () => {}, start(callback) { synced = callback; },
    roomSummaries: () => [
      { roomId: roomA, displayName: '엄마', kind: 'private', memberCount: 2, agents: [] },
      { roomId: roomB, displayName: '가족', kind: 'family', memberCount: 3, agents: [] },
    ],
    inviteSummaries: () => [], canLoadEarlier: () => false,
  });
  window.testClient = adapter;
  saveSession({ homeserverUrl: 'https://matrix.example.test', userId: me, deviceId: 'TEST', accessToken: 'synthetic' }, {
    persistent: window.localStorage, volatile: window.sessionStorage,
  });
  let ts = 1000;
  const send = async (roomId, id, body, sender = mom) => {
    const event = client.getEventMapper()({ room_id: roomId, event_id: id, type: 'm.room.message', sender, origin_server_ts: ts++, content: { msgtype: 'm.text', body } });
    await rooms[roomId].addLiveEvents([event], { addToState: false });
    await flush();
    return event;
  };
  // 다른 기기에서 읽음(서버가 sync로 내려준 m.receipt).
  const readElsewhere = async (roomId, eventId) => {
    rooms[roomId].addReceipt(new sdk.MatrixEvent({ type: 'm.receipt', room_id: roomId, content: { [eventId]: { 'm.read': { [me]: { ts: ts++ } } } } }));
    await flush();
  };
  for (const args of initial) await send(...args);
  window.eval(bundle.outputFiles[0].text);
  for (let i = 0; i < 30 && !window.document.querySelector('.room-item'); i++) await flush();
  synced('PREPARED');
  const settle = async () => {
    // 백그라운드 재렌더(다음 프레임) + 읽음 확인 모음(짧은 지연)을 기다린다.
    for (let i = 0; i < 3; i++) {
      await new Promise((resolve) => window.requestAnimationFrame(() => resolve()));
      await new Promise((resolve) => window.setTimeout(resolve, 200));
      await flush();
    }
  };
  await settle();
  const doc = window.document;
  // 열려 있지 않은 방의 목록 갱신은 2초 주기 서명 비교(startListTicker)가 맡는다.
  const waitFor = async (predicate, ms = 3000) => {
    for (const end = Date.now() + ms; Date.now() < end;) {
      if (predicate()) return true;
      await new Promise((resolve) => window.setTimeout(resolve, 50));
    }
    return predicate();
  };
  const row = (roomId) => doc.querySelector(`.room-item[data-room-id="${roomId}"]`);
  const badge = (roomId) => row(roomId)?.querySelector('.unread-badge') ?? null;
  const receiptFor = (roomId, eventId) => `/rooms/${roomId}/receipt/m.read/${eventId}`;
  const setVisibility = (value) => {
    Object.defineProperty(doc, 'visibilityState', { configurable: true, get: () => value });
    doc.dispatchEvent(new window.Event('visibilitychange'));
  };
  return { window, doc, waitFor, client, rooms, send, readElsewhere, settle, row, badge, receipts, receiptFor, setVisibility, warnings };
}

test('목록: 남의 새 메시지는 NEW 배지, 다른 기기에서 읽으면(Room.receipt) 배지가 사라진다', async (t) => {
  const a = await app(t, [[roomA, '$a1', '저녁 먹자'], [roomB, '$b1', '내가 보냄', me]]);
  assert.ok(a.badge(roomA), '안 읽은 방에 배지');
  assert.equal(a.badge(roomB), null, '내 메시지가 마지막인 방은 읽음');
  assert.ok(a.row(roomA).classList.contains('unread'));
  assert.match(a.row(roomA).textContent, /새 메시지/, '행 이름에 "새 메시지"가 들어간다');
  assert.deepEqual(a.receipts, [], '목록만 보고 있으면 영수증을 보내지 않는다');

  await a.readElsewhere(roomA, '$a1');
  await a.settle();
  assert.equal(a.badge(roomA), null, '다른 기기의 읽음 영수증이 배지를 지운다');

  await a.send(roomA, '$a2', '어디야?');
  assert.ok(await a.waitFor(() => a.badge(roomA)), '새 메시지가 오면(목록 주기 갱신으로) 다시 배지');
  assert.deepEqual(a.receipts, []);
});

test('방을 열면 최신 메시지에 m.read를 한 번 보내고 배지가 사라진다; 보는 중 새 메시지도 읽음 처리', async (t) => {
  const a = await app(t, [[roomA, '$a1', '저녁 먹자'], [roomA, '$a2', '어디야?']]);
  assert.ok(a.badge(roomA));
  a.row(roomA).click();
  await a.settle();
  assert.deepEqual(a.receipts, [a.receiptFor(roomA, '$a2')], '가장 최신 메시지 하나에만');
  assert.equal(a.badge(roomA), null, '열어 읽은 방은 배지 없음');

  // 같은 이벤트로 재렌더가 여러 번 일어나도 다시 보내지 않는다.
  a.window.dispatchEvent(new a.window.Event('focus'));
  a.doc.querySelector('.room-screen .timeline').dispatchEvent(new a.window.Event('scroll'));
  await a.settle();
  assert.equal(a.receipts.length, 1, '같은 이벤트는 한 번만');

  await a.send(roomA, '$a3', '곧 도착');
  await a.settle();
  assert.deepEqual(a.receipts.slice(1), [a.receiptFor(roomA, '$a3')], '맨 아래에서 보는 중 온 새 메시지');
  assert.equal(a.badge(roomA), null);

  await a.send(roomA, '$mine', '알았어', me);
  await a.settle();
  assert.equal(a.receipts.length, 2, '내 메시지에는 보내지 않는다');
  assert.equal(a.badge(roomA), null);
});

test('탭이 숨겨져 있으면 보내지 않고 배지를 남기며, 다시 보이면 그때 보낸다', async (t) => {
  const a = await app(t, [[roomA, '$a1', '저녁 먹자']]);
  a.row(roomA).click();
  await a.settle();
  assert.deepEqual(a.receipts, [a.receiptFor(roomA, '$a1')]);

  a.setVisibility('hidden');
  await a.send(roomA, '$a2', '자니?');
  await a.settle();
  assert.equal(a.receipts.length, 1, '숨은 탭에서는 읽은 것이 아니다');
  assert.ok(a.badge(roomA), '열린 방이라도 아직 안 읽었으면 배지');

  a.setVisibility('visible');
  await a.settle();
  assert.deepEqual(a.receipts.slice(1), [a.receiptFor(roomA, '$a2')]);
  assert.equal(a.badge(roomA), null);
});

test('위로 스크롤해 최신 메시지가 안 보이면 보내지 않고, 맨 아래로 내려오면 보낸다', async (t) => {
  const a = await app(t, [[roomA, '$a1', '저녁 먹자']]);
  a.row(roomA).click();
  await a.settle();
  assert.equal(a.receipts.length, 1);
  const list = a.doc.querySelector('.room-screen .timeline');
  // happy-dom은 레이아웃이 없다 — 긴 대화를 위로 올려 둔 상태를 흉내 낸다.
  Object.defineProperty(list, 'scrollHeight', { configurable: true, get: () => 2000 });
  Object.defineProperty(list, 'clientHeight', { configurable: true, get: () => 400 });
  let top = 100;
  Object.defineProperty(list, 'scrollTop', { configurable: true, get: () => top, set: () => {} });
  await a.send(roomA, '$a2', '사진 봤어?');
  await a.settle();
  assert.equal(a.receipts.length, 1, '최신 메시지가 화면 밖');
  assert.ok(a.badge(roomA));

  top = 1600;
  list.dispatchEvent(new a.window.Event('scroll'));
  await a.settle();
  assert.deepEqual(a.receipts.slice(1), [a.receiptFor(roomA, '$a2')]);
  assert.equal(a.badge(roomA), null);
});

test('영수증 전송 실패는 기록만 하고 화면은 계속 동작하며, 같은 이벤트로 재시도 폭주하지 않는다', async (t) => {
  const a = await app(t, [[roomA, '$a1', '저녁 먹자']], { failReceipts: true });
  a.row(roomA).click();
  await a.settle();
  await a.settle();
  assert.equal(a.receipts.length, 1);
  assert.ok(a.warnings.some((line) => /read receipt failed/.test(line)), '실패는 경고 로그로만');
  assert.ok(a.doc.querySelector('.room-screen .composer textarea'), '방 화면은 그대로');
  await a.send(roomA, '$a2', '다음 메시지');
  await a.settle();
  assert.equal(a.receipts.length, 2, '새 메시지에는 다시 시도한다');
});
