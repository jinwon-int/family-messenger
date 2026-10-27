// device.js lobby keyring against a fake worker and a scripted relay (pure node:test).
// #517: replenish must be able to keep the consumed packages' secrets while a lobby
// Welcome is still unadopted (prune: false), and openLobby must be callable on its own
// (adoptWelcome opens the lobby store before cloning a room from it).
// node --test archive/native-mls/web/hande/tests/device.test.mjs
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createDevice, LOBBY_TARGET} from '../device.js';
import {LOBBY_ROOM, LOBBY_DATABASE} from '../identity.js';

const memStorage = () => { const m = new Map(); return {getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k)}; };

function fakeWorker() {
  const w = {opened: [], minted: 0, deleted: [], spawned: true};
  const bridge = {
    has: () => w.spawned, spawn: async () => { w.spawned = true; }, stop: () => { w.spawned = false; },
    async call(name, method, argument) {
      assert.equal(name, 'device');
      if (method === 'open_room') { w.opened.push(argument); return {ok: true, result: {revision: 0, cursor: 0, fresh: true, history: false, public_key: Array.from(new Uint8Array(32).fill(7))}}; }
      if (method === 'ack') return {ok: true, result: {}};
      if (method !== 'operation') return {ok: false};
      assert.equal(argument.room, LOBBY_ROOM, `${argument.method} runs on the lobby store`);
      if (argument.method === 'key_package') { w.minted++; return {ok: true, result: {cursor: 0, output: [w.minted, 0, 0]}}; }
      if (argument.method === 'delete_key_package') { w.deleted.push(argument.bytes); return {ok: true, result: {cursor: 0, output: []}}; }
      return {ok: false};
    },
  };
  return {bridge, w};
}
function fakeRelay(live) {
  const r = {live, posted: []};
  r.api = async (method, path, body) => {
    if (method === 'GET' && path.startsWith('/v2/lobby/status')) return {status: 200, body: {live: r.live, max: LOBBY_TARGET}};
    if (method === 'POST' && path === '/v2/lobby/keypackages') { r.posted.push(body.packages); r.live += body.packages.length; return {status: 201, body: {}}; }
    throw new Error(`unexpected ${method} ${path}`);
  };
  r.describe = (status, body) => `${status} ${body?.error ?? ''}`.trim();
  return r;
}
const published = storage => JSON.parse(storage.getItem('hande:lobby:published:owner-web-aaaaaa') || '[]');

test('replenish(기본): 소비된 선두 항목의 비밀을 지우고 부족분을 발행한다', async () => {
  const {bridge, w} = fakeWorker(); const relay = fakeRelay(0); const storage = memStorage(); const logs = [];
  const dev = createDevice({device: 'owner-web-aaaaaa', worker: bridge, relay, storage, on: {log: l => logs.push(l)}});
  const first = await dev.replenish(LOBBY_TARGET);
  assert.deepEqual([first.minted, first.pruned, first.kept, first.live], [8, 0, 0, 8]);
  assert.equal(published(storage).length, 8);
  relay.live = 5;   // three consumed by invites (oldest first)
  const second = await dev.replenish(LOBBY_TARGET);
  assert.deepEqual([second.minted, second.pruned, second.kept, second.live], [3, 3, 0, 8]);
  assert.equal(w.deleted.length, 3);
  assert.deepEqual(w.deleted.map(b => b[0]), [1, 2, 3], '소비된 것은 먼저 발행한 세 개');
  assert.equal(published(storage).length, 8);
});

test('replenish({prune: false}): 수락 안 된 Welcome 이 있으면 소비분 비밀을 남기고 발행만 한다 (#517)', async () => {
  const {bridge, w} = fakeWorker(); const relay = fakeRelay(0); const storage = memStorage(); const logs = [];
  const dev = createDevice({device: 'owner-web-aaaaaa', worker: bridge, relay, storage, on: {log: l => logs.push(l)}});
  await dev.replenish(LOBBY_TARGET);
  relay.live = 5;
  const kept = await dev.replenish(LOBBY_TARGET, {prune: false});
  assert.deepEqual([kept.minted, kept.pruned, kept.kept, kept.live], [3, 0, 3, 8]);
  assert.equal(w.deleted.length, 0, '비밀키는 하나도 지우지 않는다');
  assert.equal(published(storage).length, 11, '소비된 세 개는 목록 선두에 남는다');
  assert.match(logs.at(-1), /남김/);
  // Once the Welcome is adopted the next default replenish prunes exactly those three.
  const later = await dev.replenish(LOBBY_TARGET);
  assert.deepEqual([later.minted, later.pruned, later.kept], [0, 3, 0]);
  assert.deepEqual(w.deleted.map(b => b[0]), [1, 2, 3]);
  assert.equal(published(storage).length, 8);
});

test('openLobby: 로비 스토어를 identity 사본으로 연다 — adoptWelcome 이 replenish 없이도 먼저 호출할 수 있다', async () => {
  const {bridge, w} = fakeWorker(); const relay = fakeRelay(8); const storage = memStorage();
  const dev = createDevice({device: 'owner-web-aaaaaa', worker: bridge, relay, storage});
  await dev.openLobby();
  assert.deepEqual(w.opened, [{room: LOBBY_ROOM, database: LOBBY_DATABASE, from: 'identity'}]);
});

test('replenish({protect}): 수락 안 된 Welcome 의 key_package_ref 에 해당하는 비밀만 남기고 나머지 소비분은 지운다 (#517 정밀 보호)', async () => {
  const {bridge, w} = fakeWorker(); const relay = fakeRelay(0); const storage = memStorage(); const logs = [];
  const dev = createDevice({device: 'owner-web-aaaaaa', worker: bridge, relay, storage, on: {log: l => logs.push(l)}});
  await dev.replenish(LOBBY_TARGET);
  const refOf = async b64s => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', Uint8Array.from(Buffer.from(b64s, 'base64'))))).map(x => x.toString(16).padStart(2, '0')).join('');
  const second = await refOf(published(storage)[1]);   // the second-minted package: consumed, but its Welcome is still pending
  relay.live = 5;
  const r = await dev.replenish(LOBBY_TARGET, {protect: new Set([second])});
  assert.deepEqual([r.minted, r.pruned, r.kept, r.live], [3, 2, 1, 8]);
  assert.deepEqual(w.deleted.map(b => b[0]), [1, 3], '보호된 두 번째 것만 남기고 1·3번을 지운다');
  const list = published(storage);
  assert.equal(list.length, 9, '보호된 항목은 목록 선두에 남는다');
  assert.equal(await refOf(list[0]), second);
  assert.match(logs.at(-1), /남김/);
  // Welcome adopted → no longer protected → the next replenish prunes exactly it.
  const later = await dev.replenish(LOBBY_TARGET);
  assert.deepEqual([later.minted, later.pruned, later.kept], [0, 1, 0]);
  assert.deepEqual(w.deleted.map(b => b[0]), [1, 3, 2]);
  assert.equal(published(storage).length, 8);
});
