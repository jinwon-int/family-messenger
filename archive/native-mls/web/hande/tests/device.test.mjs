// device.js lobby keyring against a fake worker and a scripted relay (pure node:test).
// #517: replenish must be able to keep the consumed packages' secrets while a lobby
// Welcome is still unadopted (prune: false), and openLobby must be callable on its own
// (adoptWelcome opens the lobby store before cloning a room from it).
// #574 PR 2b: candidate mailbox / approvals / roles calls and the sign_roles frame against a scripted relay.
// node --test archive/native-mls/web/hande/tests/device.test.mjs
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createDevice, LOBBY_TARGET} from '../device.js';
import {LOBBY_ROOM, LOBBY_DATABASE, IDENTITY_ROOM} from '../identity.js';

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

// ---- device self-service (#574 PR 2b): candidate mailbox / approvals / roles against a scripted relay, sign_roles frame ----

/** Identity-store fake: policy_fingerprint echoes a fixed hex, sign_* return u32le(n) ‖ payload ‖ 64-byte signature. */
function identityWorker() {
  const w = {signed: []};
  const bridge = {
    has: () => true, spawn: async () => {}, stop: () => {},
    async call(name, method, argument) {
      assert.equal(name, 'device');
      if (method === 'ack') return {ok: true, result: {}};
      if (method !== 'operation') return {ok: false};
      assert.equal(argument.room, IDENTITY_ROOM, `${argument.method} runs on the identity store`);
      if (argument.method === 'sign_approval' || argument.method === 'sign_roles') {
        const payload = Uint8Array.from(argument.bytes);
        w.signed.push([argument.method, new TextDecoder().decode(payload)]);
        const head = new Uint8Array(4); new DataView(head.buffer).setUint32(0, payload.length, true);
        const sig = new Uint8Array(64).fill(argument.method === 'sign_roles' ? 0x55 : 0xaa);
        return {ok: true, result: {cursor: 0, output: Array.from(new Uint8Array([...head, ...payload, ...sig]))}};
      }
      if (argument.method === 'sign_bad') return {ok: false, stage: 'sign', detail: 'identity "x@y" invalid'};
      return {ok: false};
    },
  };
  return {bridge, w};
}
function scriptedRelay(script) {
  const r = {calls: []};
  r.api = async (method, path, body) => { r.calls.push({method, path, body}); return script(method, path, body, r.calls.length); };
  r.describe = (status, body) => `${status} ${body?.error ?? ''}`.trim();
  return r;
}
const started = async (relay, worker = identityWorker().bridge) => {
  const dev = createDevice({device: 'mom-web-aaaaaa', worker, relay, storage: memStorage()});
  dev.state.publicKey = '07'.repeat(32); dev.state.fingerprint = 'fe'.repeat(32);   // what start() derives from init_multi
  return dev;
};

test('postCandidate: 본문은 subject 없이 {device_id, actor, signing_key, fingerprint}; 201 은 posted 에 만료·revision 을 남긴다', async () => {
  const relay = scriptedRelay((m, path) => (path === '/v2/devices/candidates' ? {status: 201, body: {device_id: 'mom-web-aaaaaa', fingerprint: 'fe'.repeat(32), policy_revision: 9, expires_at: 1_700_000_600}} : {status: 500, body: null}));
  const dev = await started(relay);
  const r = await dev.postCandidate();
  assert.equal(r.status, 201);
  assert.deepEqual(relay.calls[0], {method: 'POST', path: '/v2/devices/candidates', body: {device_id: 'mom-web-aaaaaa', actor: 'mom', signing_key: '07'.repeat(32), fingerprint: 'fe'.repeat(32)}});
  assert.ok(!('subject' in relay.calls[0].body), 'strict JSON on the relay: no subject key');
  assert.deepEqual(dev.state.selfService, {unsupported: false, posted: {expiresAt: 1_700_000_600_000, policyRevision: 9}});
});

test('postCandidate: 403 first_device_out_of_band · 409 device_exists 는 그대로 돌려주고, 404 는 unsupported 로 다시 묻지 않는다', async () => {
  for (const [status, body] of [[403, {error: 'first_device_out_of_band'}], [409, {error: 'device_exists'}]]) {
    const dev = await started(scriptedRelay(() => ({status, body})));
    const r = await dev.postCandidate();
    assert.deepEqual([r.status, r.body], [status, body]);
    assert.equal(dev.state.selfService.posted, null);
  }
  const relay = scriptedRelay(() => ({status: 404, body: null}));
  const dev = await started(relay);
  assert.equal((await dev.postCandidate()).status, 404);
  assert.equal(dev.state.selfService.unsupported, true);
  assert.equal((await dev.postCandidate()).status, 404);
  assert.equal(await dev.listCandidates(), null);
  assert.equal(relay.calls.length, 1, 'an old relay is asked exactly once');
});

test('listCandidates: 200 은 본문째, 403 은 null, 그 밖은 throw', async () => {
  const list = {policy_revision: 9, candidates: [{device_id: 'mom-pc-1', actor: 'mom', subject: 's', signing_key: '07'.repeat(32), fingerprint: 'fe'.repeat(32), created_at: 1, expires_at: 601}]};
  const relay = scriptedRelay((m, path) => (path === '/v2/devices/candidates?device=mom-web-aaaaaa' ? {status: 200, body: list} : {status: 500, body: null}));
  assert.deepEqual(await (await started(relay)).listCandidates(), list);
  assert.equal(await (await started(scriptedRelay(() => ({status: 403, body: {error: 'device_subject_mismatch'}})))).listCandidates(), null);
  await assert.rejects(() => started(scriptedRelay(() => ({status: 500, body: {error: 'device_policy_unavailable'}}))).then(d => d.listCandidates()), /500 device_policy_unavailable/);
});

test('postApproval / postRoles: 증거를 그대로 POST 하고 201·409·403 을 상태로 돌려준다', async () => {
  const ev = {device_id: 'mom-pc-1', actor: 'mom', subject: 's', signing_key: '07'.repeat(32), base_revision: 9, signature: 'aa'.repeat(64), fingerprint: 'fe'.repeat(32), approved_by: 'mom-web-aaaaaa'};
  const relay = scriptedRelay((m, path, body, n) => {
    if (path === '/v2/devices/approvals') return n === 1 ? {status: 409, body: {error: 'stale_revision', revision: 10}} : {status: 201, body: {device_id: body.device_id, approved_by: 'mom-web-aaaaaa', revision: 11}};
    if (path === '/v2/devices/roles') return {status: 403, body: {error: 'approval_rejected', detail: '"mom" would be left without a registrar; grant another device first'}};
    return {status: 500, body: null};
  });
  const dev = await started(relay);
  const stale = await dev.postApproval(ev);
  assert.deepEqual([stale.status, stale.body.revision], [409, 10]);
  const ok = await dev.postApproval({...ev, base_revision: 10});
  assert.deepEqual([ok.status, ok.body.revision], [201, 11]);
  assert.deepEqual(relay.calls[1].body, {...ev, base_revision: 10});
  const roles = await dev.postRoles({device_id: 'mom-web-aaaaaa', actor: 'mom', roles: [], base_revision: 11, signature: 'bb'.repeat(64), approved_by: 'mom-web-aaaaaa'});
  assert.equal(roles.status, 403);
  assert.match(roles.body.detail, /without a registrar/);
});

test('signRoles / signApproval: 프레임(u32le n ‖ payload ‖ 서명)에서 서명 hex 만, 거부는 읽을 수 있는 메시지로', async () => {
  const {bridge, w} = identityWorker();
  const dev = await started(scriptedRelay(() => ({status: 500, body: null})), bridge);
  const args = JSON.stringify({device_id: 'mom-pc-1', actor: 'mom', roles: ['registrar'], base_revision: 9});
  assert.equal(await dev.signRoles(args), '55'.repeat(64));
  assert.equal(await dev.signApproval('{"action":"approve-device"}'), 'aa'.repeat(64));
  assert.deepEqual(w.signed, [['sign_roles', args], ['sign_approval', '{"action":"approve-device"}']]);
  bridge.call = async (name, method, argument) => (argument?.method ? {ok: false, stage: 'sign', detail: 'identity "x@y" invalid'} : {ok: true, result: {}});
  await assert.rejects(() => dev.signRoles(args), /sign_roles 거부/);
});
