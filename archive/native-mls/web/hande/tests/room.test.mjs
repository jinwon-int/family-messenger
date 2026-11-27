// room.js against a fake durable worker and a scripted relay (pure node:test, no
// wasm, no DOM): the relay-app flow order, 403 enrollment wait, Welcome join,
// application decrypt → history → ack, send with one CAS retry, invite commit →
// own echo → targeted Welcome, refused commit halt, removal halt, #296 resume.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRoomSession, parseMembers, nextDeviceId, b64} from '../room.js';
import {strings} from '../strings.js';

const utf8 = new TextEncoder();
const frameMembers = members => {
  const parts = [];
  const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b; };
  parts.push(u32(members.length));
  for (const id of members) { const idb = utf8.encode(id); parts.push(u32(idb.length), idb, new Uint8Array(32).fill(members.indexOf(id) + 1)); }
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0; for (const p of parts) { out.set(p, at); at += p.length; }
  return Array.from(out);
};
const memStorage = () => { const m = new Map(); return {getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), map: m}; };

// epoch(#813): 주면 워커가 MLS epoch 를 흉내 낸다 — 결과마다 `epoch`(session-store.js 와 같은 문자열), create → 0,
// join → joinEpoch, merge_pending·merge_staged → +1. 안 주면 예전 워커처럼 `epoch` 가 없다(판정하지 않는다).
function fakeWorker({fresh = true, group = null, decrypt = () => ({sender: 'owner-pc', client: 'owner-pc'}), joinRefuses = () => false, epoch, joinEpoch = 1} = {}) {
  const w = {group, calls: [], history: [], spawned: true, pendingGroup: null, acked: [], opened: [], reset: [], epoch};
  const bridge = {
    has: () => w.spawned, spawn: async () => { w.spawned = true; }, stop: () => { w.spawned = false; },
    async call(name, method, argument) {
      assert.equal(name, 'device');
      w.calls.push([method, argument?.method ?? null]);
      if (['open_room', 'operation', 'ack', 'status', 'history_put', 'history_list', 'history_get', 'reset_room', 'close_room'].includes(method)) assert.equal(argument.room, 'family', `${method} carries the room`);
      if (method === 'open_room') { w.opened.push(argument); return {ok: true, result: {revision: 0, cursor: 0, fresh, history: true, public_key: Array.from(new Uint8Array(32).fill(7))}}; }
      if (method === 'reset_room') { w.reset.push(argument.database); w.group = null; return {ok: true, result: {}}; }
      if (method === 'close_room') return {ok: true, result: {}};
      if (method === 'status') return {ok: true, result: {revision: 1, cursor: 0, public_key: new Uint8Array(32).fill(7), entries: 1}};
      if (method === 'ack') { w.acked.push(...argument.ids); return {ok: true, result: {}}; }
      if (method === 'history_put') { w.history.push(argument); return {ok: true, result: {seq: argument.seq}}; }
      if (method === 'history_list') return {ok: true, result: w.history.map(r => ({seq: r.seq, sender: r.sender, client: r.client, kind: r.kind, text: r.text, size: r.bytes.length, received_at: 1700000000000}))};
      if (method === 'history_get') return {ok: true, result: {bytes: w.history.find(r => r.seq === argument.seq).bytes}};
      if (method !== 'operation') return {ok: false};
      const m = argument.method, bytes = argument.bytes;
      const out = o => ({ok: true, result: {cursor: 1, output: o ?? [], ...(m === 'stage_commit' ? {transient: true} : {}),
        ...(w.epoch === undefined ? {} : {epoch: w.epoch === null ? 'none' : String(w.epoch)})}});
      if (w.epoch !== undefined) {
        if (m === 'create') w.epoch = 0;
        else if (m === 'join' && !joinRefuses(bytes)) w.epoch = joinEpoch;
        else if (m === 'merge_pending' || m === 'merge_staged') w.epoch += 1;
      }
      switch (m) {
        case 'fingerprint': return out(Array.from(utf8.encode('f'.repeat(64))));
        case 'members': return w.group ? out(frameMembers(w.group)) : {ok: false};
        case 'members_after_pending': return out(frameMembers(w.pendingGroup ?? w.group));
        case 'create': w.group = ['owner-web-aaaaaa']; return out();
        case 'join': if (joinRefuses(bytes)) return {ok: false, stage: 'join', detail: 'no key package secret'}; w.group = ['bot-1', 'owner-pc', 'owner-web-aaaaaa']; return out();
        case 'encrypt': return out(bytes);
        case 'decrypt': { const d = decrypt(bytes); return {ok: true, result: {cursor: 2, output: bytes, ...d}}; }
        case 'key_package': return out([1, 2, 3]);
        case 'invite_with_commit': { const c = [9, 9], wl = [8, 8, 8]; w.pendingGroup = [...w.group, 'mom-web-bbbbbb']; return out([2, 0, 0, 0, ...c, ...wl]); }
        case 'merge_pending': w.group = w.pendingGroup; w.pendingGroup = null; return out();
        case 'clear_pending': w.pendingGroup = null; return out();
        case 'stage_commit': return out([0]);
        case 'merge_staged': case 'discard_staged': case 'policy_fingerprint': case 'sign_approval': case 'remove_pending': return out([0, 0, 0, 0]);
        default: return {ok: false};
      }
    },
  };
  return {bridge, w};
}
function fakeRelay(handler) {
  const calls = [];
  return {calls, roomPath: (room, s) => `/v2/rooms/${room}/${s}`, describe: (st, b) => `${st} ${b?.error ?? ''}`.trim(),
    async api(method, path, body) { calls.push({method, path, body}); return handler(method, path, body, calls.length); }};
}
function policy({verdict = {ok: true}, report = {adds: [], removes: [], updates: [], path: []}} = {}) {
  return {parseStageReport: () => report, checkCommit: () => verdict, outerForCommit: () => null, resolveUncertainPending: () => 'keep'};
}
function session({worker, relay, pol, storage = memStorage(), device = 'owner-web-aaaaaa', now = Date.now}) {
  const events = {messages: [], logs: [], notices: [], changes: 0};
  const s = createRoomSession({room: 'family', device, database: 'family-mls-synthetic-hande-family', worker, relay, storage, policy: pol ?? policy(),
    on: {change: () => events.changes++, message: m => events.messages.push(m), log: l => events.logs.push(l), notice: (t, tone) => events.notices.push([t, tone])},
    setInterval: () => 1, clearInterval: () => {}, now});
  return {s, events, storage};
}

test('fresh device: relay 403 → waiting; registration JSON carries key + fingerprint', async () => {
  const {bridge} = fakeWorker();
  const relay = fakeRelay(() => ({status: 403, body: {error: 'device_subject_mismatch'}}));
  const {s} = session({worker: bridge, relay});
  const opened = await s.open();
  assert.deepEqual(opened, {fresh: true});
  await s.activate();
  assert.equal(s.state.waiting403, true);
  assert.equal(s.state.joined, false);
  const reg = s.registration('sub-123');
  assert.equal(reg.device_id, 'owner-web-aaaaaa'); assert.equal(reg.actor, 'owner'); assert.equal(reg.subject, 'sub-123');
  assert.equal(reg.signing_key, '07'.repeat(32));
  const {createHash} = await import('node:crypto');
  assert.equal(reg.fingerprint, createHash('sha256').update(Buffer.alloc(32, 7)).digest('hex'));
});

test('Welcome joins, application decrypts to a message with ts, history row + relay ack', async () => {
  const {bridge, w} = fakeWorker({decrypt: () => ({sender: 'owner-pc', client: 'owner-pc'})});
  const events = [
    {seq: 1, device: 'owner-pc', kind: 'welcome', epoch: 1, bytes: b64([1]), created_at: 1700000000},
    {seq: 2, device: 'owner-pc', kind: 'application', epoch: 1, bytes: b64(Array.from(utf8.encode('안녕'))), client_id: 'owner-pc-x', created_at: 1700000001},
  ];
  const relay = fakeRelay((m, path) => {
    if (path.includes('ack=')) return {status: 200, body: {epoch: 1, events: [], cursor: 2, members: []}};
    return {status: 200, body: {epoch: 1, revision: 1, events, cursor: 0, first_seq: 1, members: []}};
  });
  const {s, events: ev} = session({worker: bridge, relay});
  await s.open(); await s.activate();
  assert.equal(s.state.joined, true);
  assert.deepEqual(s.state.roster, ['bot-1', 'owner-pc', 'owner-web-aaaaaa']);
  const msg = ev.messages.find(x => x.kind === 'text');
  assert.equal(msg.text, '안녕'); assert.equal(msg.sender, 'owner-pc'); assert.equal(msg.seq, 2); assert.equal(msg.ts, 1700000001000);
  assert.equal(w.history.length, 1);
  assert.ok(relay.calls.some(c => c.path.includes('after=2&ack=2')), 'acks the processed seq');
  assert.equal(s.state.relaySeq, 2);
  assert.equal(s.state.waiting403, false);
});

test('a Welcome this store cannot open is skipped and the later (re-invite) Welcome joins (#530)', async () => {
  // The invite before a remove + re-invite left Welcome seq 4 in the log; its lobby secret is
  // gone. The re-invite's Welcome is seq 7. Reading from the start must not stop at seq 4.
  const {bridge, w} = fakeWorker({joinRefuses: bytes => bytes[0] === 9});
  const events = [
    {seq: 1, device: 'bot-1', kind: 'commit', epoch: 0, bytes: b64([0]), created_at: 1700000000},
    {seq: 4, device: 'bot-1', kind: 'welcome', epoch: 2, bytes: b64([9]), created_at: 1700000001},
    {seq: 6, device: 'bot-1', kind: 'commit', epoch: 3, bytes: b64([0]), created_at: 1700000002},
    {seq: 7, device: 'bot-1', kind: 'welcome', epoch: 4, bytes: b64([1]), created_at: 1700000003},
  ];
  const relay = fakeRelay((m, path) => {
    if (path.includes('ack=')) return {status: 200, body: {epoch: 4, events: [], cursor: 7, members: []}};
    return {status: 200, body: {epoch: 4, revision: 1, events, cursor: 3, first_seq: 1, members: []}};
  });
  const {s, events: ev} = session({worker: bridge, relay});
  await s.open(); await s.activate();
  const logs = ev.logs;
  assert.equal(s.state.joined, true, 'joined through the later Welcome');
  assert.equal(s.state.relaySeq, 7);
  assert.ok(logs.some(l => l.includes('열 수 없는 Welcome(seq 4)')), 'the stale Welcome is reported, not fatal');
  assert.ok(logs.some(l => l.includes('참여 완료(seq 7)')));
  assert.equal(w.calls.filter(c => c[1] === 'join').length, 2, 'join attempted on both Welcomes');
});

test('open with replace drops a group-less store and startSeq rewinds the cursor before the Welcome', async () => {
  const {bridge, w} = fakeWorker({fresh: true});
  const relay = fakeRelay(() => ({status: 200, body: {epoch: 1, events: [], cursor: 0, members: []}}));
  const storage = memStorage();
  storage.setItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family', JSON.stringify({joined: false, relaySeq: 40, epoch: 0, roster: []}));
  const {s} = session({worker: bridge, relay, storage});
  const opened = await s.open({from: 'lobby', replace: true, startSeq: 41});
  assert.equal(opened.fresh, true);
  assert.deepEqual(w.reset, ['family-mls-synthetic-hande-family'], 'reset_room before the lobby clone');
  assert.equal(w.opened.at(-1).from, 'lobby');
  assert.equal(s.state.relaySeq, 0, 'fresh store: state reset');
  // A store that already holds a group is never replaced.
  const {bridge: b2, w: w2} = fakeWorker({fresh: false, group: ['owner-web-aaaaaa']});
  const st2 = memStorage();
  st2.setItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family', JSON.stringify({joined: true, relaySeq: 50, epoch: 2, roster: ['owner-web-aaaaaa']}));
  const {s: s2} = session({worker: b2, relay, storage: st2});
  await s2.open({from: 'lobby', replace: true, startSeq: 45});
  assert.deepEqual(w2.reset, [], 'joined store kept');
  assert.equal(s2.state.relaySeq, 44, 'cursor rewound to read the Welcome again');
  assert.equal(s2.state.joined, false);
});

test('send on a resumed store: own echo row, CAS retry, draft kept on failure', async () => {
  const {bridge, w} = fakeWorker({fresh: false, group: ['owner-pc', 'owner-web-aaaaaa']});
  let posts = 0;
  const relay = fakeRelay((m, path, body) => {
    if (m === 'GET') return {status: 200, body: {epoch: 3, events: [], cursor: 5, members: []}};
    posts++;
    if (posts === 1) return {status: 409, body: {error: 'cas_mismatch', epoch: 3}};
    if (posts === 2) return {status: 201, body: {seq: 6, epoch: 3}};
    return {status: 403, body: {error: 'not_a_member'}};
  });
  const storage = memStorage();
  storage.setItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family', JSON.stringify({joined: true, relaySeq: 5, epoch: 2, roster: ['owner-pc', 'owner-web-aaaaaa']}));
  const {s, events: ev} = session({worker: bridge, relay, storage});
  await s.open(); await s.activate();
  const seq = await s.send('hello');
  assert.equal(seq, 6);
  assert.equal(w.calls.filter(c => c[1] === 'encrypt').length, 2, 'one re-encrypt after cas_mismatch');
  const own = ev.messages.find(x => x.kind === 'text' && x.sender === 'owner-web-aaaaaa');
  assert.equal(own.text, 'hello'); assert.equal(own.seq, 6);
  assert.equal(w.history.at(-1).text, 'hello');
  // #813 S3: 403 not_a_member while this store still lists the device (also after the resync) — not 「동기화 뒤 다시 시도」.
  await assert.rejects(() => s.send('again'), new RegExp(strings.room.relayDiverged));
  assert.equal(s.state.diverged.reason, 'not_a_member');
});

test('invite: key package → commit 201 pending → own echo merges → targeted Welcome', async () => {
  const {bridge, w} = fakeWorker({fresh: false, group: ['owner-web-aaaaaa']});
  let phase = 0;
  const relay = fakeRelay((m, path, body) => {
    if (m === 'GET' && path.includes('keypackages')) return {status: 200, body: {ref: 'r', bytes: b64([5, 5])}};
    if (m === 'POST' && body.kind === 'commit') { phase = 1; assert.deepEqual(body.members, [{device: 'mom-web-bbbbbb', actor: 'mom'}, {device: 'owner-web-aaaaaa', actor: 'owner'}]); return {status: 201, body: {seq: 10, epoch: 0}}; }
    if (m === 'POST' && body.kind === 'welcome') { phase = 2; assert.deepEqual(body.targets, ['mom-web-bbbbbb']); assert.equal(body.epoch, 1); return {status: 201, body: {seq: 11, epoch: 1}}; }
    if (m === 'GET' && phase === 1) return {status: 200, body: {epoch: 1, events: [{seq: 10, device: 'owner-web-aaaaaa', kind: 'commit', epoch: 0, bytes: b64([9, 9])}], cursor: 9, members: []}};
    return {status: 200, body: {epoch: phase ? 1 : 0, events: [], cursor: 9, members: []}};
  });
  const storage = memStorage();
  storage.setItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family', JSON.stringify({joined: true, relaySeq: 9, epoch: 0, roster: ['owner-web-aaaaaa']}));
  const {s} = session({worker: bridge, relay, storage});
  await s.open(); await s.activate();
  await s.invite('mom-web-bbbbbb');
  assert.equal(phase, 2, 'Welcome posted after the echo');
  assert.equal(s.state.pending, false);
  assert.deepEqual(s.state.roster, ['owner-web-aaaaaa', 'mom-web-bbbbbb']);
  assert.equal(s.state.epoch, 1);
  assert.ok(w.calls.some(c => c[1] === 'merge_pending'));
});

test('foreign commit refused by policy → discard + durable halt; removal → halt(removed)', async () => {
  for (const [verdict, report, removed] of [[{ok: false, reason: 'roster_mismatch', detail: 'x'}, {adds: [], removes: [], updates: [], path: []}, false],
    [{ok: true}, {adds: [], removes: [{id: 'owner-web-aaaaaa'}], updates: [], path: []}, true]]) {
    const {bridge, w} = fakeWorker({fresh: false, group: ['bot-1', 'owner-web-aaaaaa']});
    const relay = fakeRelay(() => ({status: 200, body: {epoch: 2, events: [{seq: 12, device: 'bot-1', kind: 'commit', epoch: 1, bytes: b64([1])}], cursor: 11, members: []}}));
    const storage = memStorage();
    storage.setItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family', JSON.stringify({joined: true, relaySeq: 11, epoch: 1, roster: ['bot-1', 'owner-web-aaaaaa']}));
    const {s, events: ev} = session({worker: bridge, relay, storage, pol: policy({verdict, report})});
    await s.open(); await s.activate();
    assert.ok(s.state.halted, 'halted');
    assert.equal(s.state.halted.removed, removed);
    assert.equal(s.state.halted.seq, 12);
    assert.ok(w.calls.some(c => c[1] === (removed ? 'merge_staged' : 'discard_staged')));
    assert.ok(ev.messages.some(m => m.kind === 'system' && m.key === 'halt-12'));
    const saved = JSON.parse(storage.getItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family'));
    assert.equal(saved.halted.reason, removed ? 'removed_from_room' : 'roster_mismatch');
    await assert.rejects(() => s.send('x'));
  }
});

test('#296 resume: page state lost but the worker holds the group → join state from the relay cursor', async () => {
  const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'owner-web-aaaaaa']});
  const relay = fakeRelay((m, path) => path.includes('limit=1') ? {status: 200, body: {epoch: 4, events: [], cursor: 40, members: []}} : {status: 200, body: {epoch: 4, events: [], cursor: 40, members: []}});
  const {s, events: ev} = session({worker: bridge, relay});
  await s.open(); await s.activate();
  assert.equal(s.state.joined, true); assert.equal(s.state.relaySeq, 40); assert.equal(s.state.epoch, 4);
  // 봉인 보관 안내는 타임라인 시스템 행이 아니라 화면 로그에만 남는다(오너 결정 2026-10-20).
  assert.ok(!ev.messages.some(m => m.kind === 'system' && m.key === 'history'));
  assert.ok(ev.logs.some(l => /seq 40/.test(l) && /보관/.test(l)));
});

const STATE_KEY = 'hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family';
const joinedAt = (storage, epoch, roster = ['owner-pc', 'owner-web-aaaaaa']) =>
  storage.setItem(STATE_KEY, JSON.stringify({joined: true, relaySeq: 5, epoch, roster}));

test('#813 S1: relay room epoch below this store\'s MLS epoch → diverged (notice state), nothing halts; relay back in step → cleared', async () => {
  const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'owner-web-aaaaaa'], epoch: 3});
  let relayEpoch = 2;   // restored from a snapshot taken before the last commit
  const relay = fakeRelay((m, path) => ({status: 200, body: {epoch: relayEpoch, events: [], cursor: 5, members: []}}));
  const storage = memStorage(); joinedAt(storage, 3);
  const {s, events: ev} = session({worker: bridge, relay, storage});
  await s.open(); await s.activate();
  assert.deepEqual(s.state.diverged, {reason: 'epoch_regressed', relay_epoch: 2, local_epoch: 3});
  assert.equal(s.state.halted, null, 'notify only');
  assert.equal(s.state.epoch, 2, 'sends keep the relay epoch (CAS)');
  assert.ok(ev.logs.some(l => l.includes('릴레이와 어긋남(epoch_regressed)')));
  assert.ok(!JSON.parse(storage.getItem(STATE_KEY)).diverged, 'not persisted — the next sync decides again');
  relayEpoch = 3;
  await s.sync();
  assert.equal(s.state.diverged, null);
});

test('#813 S1 never fires in normal flows: own invite (pending until its echo), lost race (409 → clear_pending → winner), reconnect, an old worker', async () => {
  // Own commit: 201 at relay epoch 0 → 1; the store stays at 0 until the echo merges it.
  {
    const {bridge, w} = fakeWorker({fresh: false, group: ['owner-web-aaaaaa'], epoch: 0});
    let phase = 0;
    const relay = fakeRelay((m, path, body) => {
      if (m === 'GET' && path.includes('keypackages')) return {status: 200, body: {ref: 'r', bytes: b64([5, 5])}};
      if (m === 'POST' && body.kind === 'commit') { phase = 1; return {status: 201, body: {seq: 10, epoch: 1}}; }
      if (m === 'POST' && body.kind === 'welcome') { phase = 2; return {status: 201, body: {seq: 11, epoch: 1}}; }
      if (m === 'GET' && phase === 1) return {status: 200, body: {epoch: 1, events: [{seq: 10, device: 'owner-web-aaaaaa', kind: 'commit', epoch: 0, bytes: b64([9, 9])}], cursor: 9, members: []}};
      return {status: 200, body: {epoch: phase ? 1 : 0, events: [], cursor: 9, members: []}};
    });
    const storage = memStorage(); joinedAt(storage, 0, ['owner-web-aaaaaa']);
    const {s} = session({worker: bridge, relay, storage});
    await s.open(); await s.activate();
    await s.invite('mom-web-bbbbbb');
    assert.equal(w.epoch, 1, 'merged on the echo');
    await s.sync();   // reconnect: the same relay state again
    assert.equal(s.state.diverged, null);
  }
  // Lost race: our commit draws 409, pending cleared (epoch 0 stays), the winner's commit is read next.
  {
    const {bridge, w} = fakeWorker({fresh: false, group: ['bot-1', 'owner-web-aaaaaa'], epoch: 0});
    let raced = false;
    const relay = fakeRelay((m, path, body) => {
      if (m === 'GET' && path.includes('keypackages')) return {status: 200, body: {ref: 'r', bytes: b64([5, 5])}};
      if (m === 'POST' && body.kind === 'commit') { raced = true; return {status: 409, body: {error: 'cas_mismatch', epoch: 1}}; }
      if (m === 'GET' && raced) return {status: 200, body: {epoch: 1, events: [{seq: 10, device: 'bot-1', kind: 'commit', epoch: 0, bytes: b64([1])}], cursor: 9, members: []}};
      return {status: 200, body: {epoch: 0, events: [], cursor: 9, members: []}};
    });
    const storage = memStorage(); joinedAt(storage, 0, ['bot-1', 'owner-web-aaaaaa']);
    const {s} = session({worker: bridge, relay, storage});
    await s.open(); await s.activate();
    await assert.rejects(() => s.invite('mom-web-bbbbbb'), new RegExp(strings.room.commitRaced));
    assert.ok(w.calls.some(c => c[1] === 'clear_pending'));
    assert.equal(w.epoch, 1, 'the winner merged');
    await s.sync();
    assert.equal(s.state.diverged, null);
  }
  // A worker without `epoch` in its results (older build): nothing to compare, nothing flagged.
  {
    const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'owner-web-aaaaaa']});
    const relay = fakeRelay(() => ({status: 200, body: {epoch: 0, events: [], cursor: 5, members: []}}));
    const storage = memStorage(); joinedAt(storage, 7);
    const {s} = session({worker: bridge, relay, storage});
    await s.open(); await s.activate();
    assert.equal(s.state.mlsEpoch, null);
    assert.equal(s.state.diverged, null);
  }
});

test('#813 S3: 403 not_a_member → resync → still a member → relayDiverged (not 「동기화 뒤 다시 시도」); a stored send clears it; removed by a commit read in that resync → the old text', async () => {
  {
    const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'owner-web-aaaaaa'], epoch: 2});
    let refuse = true;
    const relay = fakeRelay((m) => {
      if (m === 'GET') return {status: 200, body: {epoch: 2, events: [], cursor: 5, members: []}};
      return refuse ? {status: 403, body: {error: 'not_a_member'}} : {status: 201, body: {seq: 6, epoch: 2}};
    });
    const storage = memStorage(); joinedAt(storage, 2);
    const {s} = session({worker: bridge, relay, storage});
    await s.open(); await s.activate();
    assert.equal(s.state.diverged, null, 'in step before the send');
    await assert.rejects(() => s.send('hi'), err => err.message === strings.room.relayDiverged);
    assert.deepEqual(s.state.diverged, {reason: 'not_a_member', relay_epoch: 2, local_epoch: 2});
    refuse = false;   // the next commit re-aligned the relay roster
    assert.equal(await s.send('hi again'), 6);
    assert.equal(s.state.diverged, null);
  }
  {
    const {bridge} = fakeWorker({fresh: false, group: ['bot-1', 'owner-web-aaaaaa'], epoch: 1});
    let posted = false;
    const relay = fakeRelay((m) => {
      if (m === 'POST') { posted = true; return {status: 403, body: {error: 'not_a_member'}}; }
      if (!posted) return {status: 200, body: {epoch: 1, events: [], cursor: 11, members: []}};
      return {status: 200, body: {epoch: 2, events: [{seq: 12, device: 'bot-1', kind: 'commit', epoch: 1, bytes: b64([1])}], cursor: 11, members: []}};
    });
    const storage = memStorage(); storage.setItem(STATE_KEY, JSON.stringify({joined: true, relaySeq: 11, epoch: 1, roster: ['bot-1', 'owner-web-aaaaaa']}));
    const {s} = session({worker: bridge, relay, storage, pol: policy({report: {adds: [], removes: [{id: 'owner-web-aaaaaa'}], updates: [], path: []}})});
    await s.open(); await s.activate();
    await assert.rejects(() => s.send('hi'), /403 not_a_member/);
    assert.equal(s.state.halted.removed, true, 'the removal was read on the resync');
    assert.equal(s.state.diverged, null, 'a removal is not divergence');
  }
});

test('helpers', () => {
  assert.equal(nextDeviceId('owner-web-1a2b3c'), 'owner-web-1a2b3c-2');
  assert.equal(nextDeviceId('owner-web-1a2b3c-2'), 'owner-web-1a2b3c-3');
  assert.deepEqual(parseMembers(frameMembers(['a-1', 'b-2'])), ['a-1', 'b-2']);
});

// 2026-10-26: a worker refusal shows which check refused it (durable worker `detail`).
test('describeRejection / refused: worker detail is shown, malformed detail is dropped', async () => {
  const {describeRejection, refused} = await import('../room.js');
  assert.equal(refused('encrypt', {ok: false}).message, 'encrypt 거부');                     // old worker: unchanged
  const detail = {reason: 'transaction rejected', storage: 'QuotaExceededError',
    inner: {reason: 'rejected', where: ['session-store.js:282', 'session-store.js:636']}};
  assert.equal(refused('encrypt', {ok: false, detail}).message,
    'encrypt 거부 (transaction rejected storage=QuotaExceededError ⇐ rejected @ session-store.js:282 < session-store.js:636)');
  assert.equal(describeRejection({detail: {reason: 'state limit', name: 'Error!'}}), ' (state limit)');
  assert.equal(describeRejection({detail: {reason: 'x"<script>'}}), '');
  assert.equal(describeRejection({detail: {reason: 'rejected', where: ['../../etc/passwd:1', 'a.js:1']}}), ' (rejected @ a.js:1)');
  assert.equal(describeRejection({detail: 'rejected'}), '');
  assert.match(refused('open_room', {ok: false, detail: {reason: 'record key rejected'}}).message, /^open_room 거부 \(record key rejected\)$/);
});

// #499 file-v2: the MLS message carries only the descriptor; the blob is fetched, verified and
// decrypted lazily; history keeps the descriptor, never the bytes; a bad descriptor is never text.
test('file-v2 event: descriptor-only history row, lazy blob load verified + decrypted, retry after failure', async () => {
  const {encryptFile, encodeDescriptor} = await import('../file-v2.js');
  const photo = Uint8Array.from({length: 3000}, (_, i) => (i * 7) & 255);
  const enc = await encryptFile(photo);
  const desc = encodeDescriptor({blob: enc.blob, size: enc.size, key: enc.key, nonce: enc.nonce, name: '../사진.jpg', w: 3024, h: 4032});
  const {bridge, w} = fakeWorker({fresh: false, group: ['owner-pc', 'owner-web-aaaaaa'], decrypt: () => ({sender: 'owner-pc', client: 'owner-pc'})});
  const events = [
    {seq: 6, device: 'owner-pc', kind: 'application', epoch: 3, bytes: b64(Array.from(utf8.encode(desc))), client_id: 'file-v2-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2', created_at: 1700000006},
    {seq: 7, device: 'owner-pc', kind: 'application', epoch: 3, bytes: b64(Array.from(utf8.encode('{"v":2,"blob":"zz"}'))), client_id: 'file-v2-1f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2', created_at: 1700000007},
  ];
  const relay = fakeRelay((m, path) => {
    if (path.includes('ack=')) return {status: 200, body: {epoch: 3, events: [], cursor: 7, members: []}};
    return {status: 200, body: {epoch: 3, revision: 1, events, cursor: 5, first_seq: 1, members: []}};
  });
  let blobCalls = 0, failNext = true;
  relay.blob = async (room, id, device) => {
    blobCalls++;
    assert.deepEqual([room, id, device], ['family', enc.blob, 'owner-web-aaaaaa']);
    if (failNext) { failNext = false; const e = new Error('blob 404 no_such_blob'); e.status = 404; throw e; }
    return enc.ciphertext;
  };
  const storage = memStorage();
  storage.setItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family', JSON.stringify({joined: true, relaySeq: 5, epoch: 3, roster: ['owner-pc', 'owner-web-aaaaaa']}));
  const {s, events: ev} = session({worker: bridge, relay, storage});
  await s.open(); await s.activate();
  const att = ev.messages.find(x => x.kind === 'attachment' && x.seq === 6);
  assert.ok(att, 'file-v2 shows as an attachment entry');
  assert.equal(att.size, photo.length); assert.equal(att.fileName, '사진.jpg', 'sender name reduced to a safe last segment');
  assert.deepEqual(att.dims, {w: 3024, h: 4032}, '#647: descriptor w/h reach the timeline before any fetch');
  assert.equal(blobCalls, 0, 'nothing fetched until the timeline asks');
  await assert.rejects(() => att.load(), /no_such_blob/);
  assert.deepEqual(await att.load(), photo, 'a failed load is retried on the next ask');
  assert.deepEqual(await att.load(), photo); assert.equal(blobCalls, 2, 'success is cached');
  // History: descriptor only, no bytes; the bad descriptor is neither text nor history.
  const rows = w.history.filter(r => r.seq === 6 || r.seq === 7);
  assert.deepEqual(rows.map(r => [r.seq, r.kind, r.bytes.length]), [[6, 'file-v2', 0]]);
  assert.equal(rows[0].text, desc);
  assert.ok(ev.messages.some(x => x.kind === 'undecryptable' && x.seq === 7), 'invalid descriptor → unopenable, never text');
  assert.ok(!ev.messages.some(x => x.kind === 'text' && x.seq === 7));
  assert.equal(s.state.relaySeq, 7, 'both acked — the MLS messages were processed');
});

test('file-v2 history restore: descriptor rows become lazy attachments again', async () => {
  const {encryptFile, encodeDescriptor} = await import('../file-v2.js');
  const enc = await encryptFile(new Uint8Array([1, 2, 3, 4]));
  const desc = encodeDescriptor({blob: enc.blob, size: enc.size, key: enc.key, nonce: enc.nonce});
  const {bridge, w} = fakeWorker({fresh: false, group: ['owner-pc', 'owner-web-aaaaaa']});
  w.history.push({seq: 9, sender: 'owner-pc', client: '', kind: 'file-v2', text: desc, bytes: []},
    {seq: 10, sender: 'owner-pc', client: '', kind: 'file-v2', text: '{"v":2}', bytes: []});
  const relay = fakeRelay(() => ({status: 200, body: {epoch: 3, events: [], cursor: 10, members: []}}));
  relay.blob = async () => enc.ciphertext;
  const storage = memStorage();
  storage.setItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family', JSON.stringify({joined: true, relaySeq: 10, epoch: 3, roster: ['owner-pc', 'owner-web-aaaaaa']}));
  const {s, events: ev} = session({worker: bridge, relay, storage});
  await s.open(); await s.activate();
  const att = ev.messages.find(x => x.kind === 'attachment' && x.seq === 9);
  assert.ok(att); assert.deepEqual(await att.load(), new Uint8Array([1, 2, 3, 4]));
  assert.equal(att.dims, null, '#647: no w/h in the descriptor → no size hint (legacy photo)');
  assert.ok(ev.messages.some(x => x.kind === 'undecryptable' && x.seq === 10));
  assert.ok(!ev.messages.some(x => x.kind === 'text'));
});

// ---- typing indicator (#562 PR B) ----
const joinedStorage = () => {
  const storage = memStorage();
  storage.setItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family', JSON.stringify({joined: true, relaySeq: 5, epoch: 2, roster: ['owner-pc', 'mom-web-1', 'owner-web-aaaaaa']}));
  return storage;
};

test('typing: GET /events `typing` lands in state; a relay without the key means nobody (#562)', async () => {
  const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'mom-web-1', 'owner-web-aaaaaa']});
  let typing = ['mom-web-1', 'owner-pc'];
  const relay = fakeRelay((m, path) => {
    const body = {epoch: 2, events: [], cursor: 5, members: []};
    if (typing) body.typing = typing;
    return {status: 200, body};
  });
  const {s} = session({worker: bridge, relay, storage: joinedStorage()});
  await s.open(); await s.activate();
  assert.deepEqual(s.state.typing, ['mom-web-1', 'owner-pc']);
  typing = null;   // old relay: no key at all
  await s.sync();
  assert.deepEqual(s.state.typing, []);
  typing = 'junk';   // not a list → nobody, never a crash
  await s.sync();
  assert.deepEqual(s.state.typing, []);
});

// ---- per-room notification setting (server/mute.go) ----
test('muted: GET /events `muted` lands in state; old relay (no key) keeps null; junk ignored', async () => {
  const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'mom-web-1', 'owner-web-aaaaaa']});
  let muted = null;
  const relay = fakeRelay(() => {
    const body = {epoch: 2, events: [], cursor: 5, members: []};
    if (muted !== null) body.muted = muted;
    return {status: 200, body};
  });
  const {s} = session({worker: bridge, relay, storage: joinedStorage()});
  await s.open(); await s.activate();
  assert.equal(s.state.muted, null, 'old relay → unknown');
  muted = true; await s.sync();
  assert.equal(s.state.muted, true);
  muted = 'junk'; await s.sync();
  assert.equal(s.state.muted, true, 'not a boolean → ignored');
  muted = false; await s.sync();
  assert.equal(s.state.muted, false);
});

test('setMuted(): optimistic flip, 200 settles, failure or throw restores and resolves false', async () => {
  const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'mom-web-1', 'owner-web-aaaaaa']});
  let answer = (body) => ({status: 200, body: {muted: body.muted}});
  const relay = fakeRelay((m, path, body) => {
    if (path.endsWith('/mute')) return answer(body);
    return {status: 200, body: {epoch: 2, events: [], cursor: 5, members: [], muted: false}};
  });
  const {s} = session({worker: bridge, relay, storage: joinedStorage()});
  await s.open(); await s.activate();
  const posts = () => relay.calls.filter(c => c.method === 'POST' && c.path === '/v2/rooms/family/mute');
  assert.equal(await s.setMuted(true), true);
  assert.deepEqual(posts()[0].body, {device: 'owner-web-aaaaaa', muted: true});
  assert.equal(s.state.muted, true);
  assert.equal(await s.setMuted('yes'), false, 'non-boolean → refused without a POST');
  assert.equal(posts().length, 1);
  answer = () => ({status: 403, body: {error: 'not_a_member'}});
  assert.equal(await s.setMuted(false), false);
  assert.equal(s.state.muted, true, 'refused → restored');
  answer = () => { throw new Error('offline'); };
  assert.equal(await s.setMuted(false), false);
  assert.equal(s.state.muted, true, 'thrown → restored');
});

// ---- shared read position (#571 B) ----
test('read_seq: GET /events `read_seq` lands in state and never shrinks; a relay without the key means 0 (#571)', async () => {
  const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'mom-web-1', 'owner-web-aaaaaa']});
  let readSeq = 4;
  const relay = fakeRelay(() => {
    const body = {epoch: 2, events: [], cursor: 5, members: []};
    if (readSeq !== null) body.read_seq = readSeq;
    return {status: 200, body};
  });
  const {s} = session({worker: bridge, relay, storage: joinedStorage()});
  await s.open(); await s.activate();
  assert.equal(s.state.readSeq, 4);
  readSeq = null;   // old relay: no key → keeps what it knew
  await s.sync();
  assert.equal(s.state.readSeq, 4);
  readSeq = 2;   // lower → ignored (monotonic within the session)
  await s.sync();
  assert.equal(s.state.readSeq, 4);
  readSeq = 'junk';
  await s.sync();
  assert.equal(s.state.readSeq, 4);
  readSeq = 5;
  await s.sync();
  assert.equal(s.state.readSeq, 5);
});

test('markRead(): one POST per new seq, skipped when the relay already knows as much, 200 lifts state, errors ignored (#571)', async () => {
  const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'mom-web-1', 'owner-web-aaaaaa']});
  let answer = () => ({status: 200, body: {read_seq: 3}});
  const relay = fakeRelay((m, path) => {
    if (path.endsWith('/read')) return answer();
    return {status: 200, body: {epoch: 2, events: [], cursor: 5, members: [], read_seq: 1}};
  });
  const {s, events: ev} = session({worker: bridge, relay, storage: joinedStorage()});
  await s.open(); await s.activate();
  const posts = () => relay.calls.filter(c => c.method === 'POST' && c.path === '/v2/rooms/family/read');
  const tick = () => new Promise(r => setTimeout(r, 0));
  s.markRead(1);
  assert.equal(posts().length, 0, 'relay already at 1 → nothing to post');
  s.markRead(0); s.markRead(-1); s.markRead(NaN);
  assert.equal(posts().length, 0);
  const before = ev.changes;
  s.markRead(3); await tick();
  assert.equal(posts().length, 1);
  assert.deepEqual(posts()[0].body, {device: 'owner-web-aaaaaa', seq: 3});
  assert.equal(s.state.readSeq, 3, '200 read_seq lifts the state');
  assert.equal(ev.changes, before + 1, 'and announces the change');
  s.markRead(3); await tick();
  assert.equal(posts().length, 1, 'same seq again → no second POST');
  // Another device is already further: the answer lifts state above what we posted.
  answer = () => ({status: 200, body: {read_seq: 9}});
  s.markRead(4); await tick();
  assert.equal(posts().length, 2);
  assert.equal(s.state.readSeq, 9);
  s.markRead(8); await tick();
  assert.equal(posts().length, 2, 'relay knows 9 → 8 is not news');
  // Old relay (404) and a thrown transport error: the caller never sees them.
  answer = () => ({status: 404, body: {error: 'no_such_room'}});
  s.markRead(10); await tick();
  assert.equal(posts().length, 3);
  assert.equal(s.state.readSeq, 9);
  answer = () => { throw new Error('offline'); };
  s.markRead(11); await tick();
  assert.equal(posts().length, 4);
  assert.equal(s.state.readSeq, 9);
});

test('typing(): one POST per 3 s, clear posts clear:true and re-arms, errors ignored (#562)', async () => {
  const {bridge} = fakeWorker({fresh: false, group: ['owner-pc', 'mom-web-1', 'owner-web-aaaaaa']});
  let t = 10_000;
  let typingStatus = 204;
  const relay = fakeRelay((m, path) => {
    if (path.endsWith('/typing')) return {status: typingStatus, body: typingStatus === 204 ? null : {error: 'no_such_room'}};
    return {status: 200, body: {epoch: 2, events: [], cursor: 5, members: []}};
  });
  const {s} = session({worker: bridge, relay, storage: joinedStorage(), now: () => t});
  await s.open(); await s.activate();
  const posts = () => relay.calls.filter(c => c.method === 'POST' && c.path === '/v2/rooms/family/typing');
  s.typing();
  assert.equal(posts().length, 1);
  assert.deepEqual(posts()[0].body, {device: 'owner-web-aaaaaa', clear: false});
  t += 2999; s.typing();
  assert.equal(posts().length, 1, 'inside the 3 s window: no second POST');
  t += 1; s.typing();
  assert.equal(posts().length, 2, 'after 3 s: posts again');
  s.typing(true);
  assert.equal(posts().length, 3);
  assert.deepEqual(posts()[2].body, {device: 'owner-web-aaaaaa', clear: true});
  s.typing(true);
  assert.equal(posts().length, 3, 'nothing live to clear → no POST');
  s.typing();
  assert.equal(posts().length, 4, 'clear re-armed the throttle');
  // An old relay answers 404 — the caller never sees it.
  typingStatus = 404; t += 3000;
  s.typing();
  assert.equal(posts().length, 5);
  await new Promise(r => setTimeout(r, 0));
  // A relay that throws (network) is swallowed too.
  relay.api = async () => { throw new Error('offline'); };
  t += 3000;
  assert.doesNotThrow(() => s.typing());
  await new Promise(r => setTimeout(r, 0));
});

test('typing(): no POST before join / after halt; a sent message resets the throttle (#562)', async () => {
  const {bridge} = fakeWorker({fresh: true});
  const relay = fakeRelay(() => ({status: 200, body: {epoch: 0, events: [], cursor: 0, members: []}}));
  const {s} = session({worker: bridge, relay});
  s.typing();
  await s.open(); await s.activate();
  s.typing(); s.typing(true);
  assert.equal(relay.calls.filter(c => c.method === 'POST').length, 0, 'not joined: silent');
  // joined: typing → send → typing again posts immediately (relay cleared it when the event was stored)
  const {bridge: b2} = fakeWorker({fresh: false, group: ['owner-pc', 'mom-web-1', 'owner-web-aaaaaa']});
  let t = 50_000;
  const relay2 = fakeRelay((m, path, body) => {
    if (path.endsWith('/typing')) return {status: 204, body: null};
    if (m === 'POST') return {status: 201, body: {seq: 6, epoch: 2}};
    return {status: 200, body: {epoch: 2, events: [], cursor: 5, members: []}};
  });
  const {s: s2} = session({worker: b2, relay: relay2, storage: joinedStorage(), now: () => t});
  await s2.open(); await s2.activate();
  s2.typing();
  await s2.send('hi');
  s2.typing();
  const typingPosts = relay2.calls.filter(c => c.path === '/v2/rooms/family/typing');
  assert.equal(typingPosts.length, 2, 'the send reset the 3 s throttle');
  assert.ok(relay2.calls.some(c => c.path === '/v2/rooms/family/events' && c.body?.kind === 'application'));
});

// ---- status-v1 (#560): the agent's live 「⏳ Working …」 line ----
test('status-<uuid> event: on.status only — never a timeline message, never history; still acked', async () => {
  const {bridge, w} = fakeWorker({fresh: false, group: ['dungae-bot', 'owner-web-aaaaaa'], decrypt: () => ({sender: 'dungae-bot', client: 'dungae-bot'})});
  const events = [
    {seq: 6, device: 'dungae-bot', kind: 'application', epoch: 3, bytes: b64(Array.from(utf8.encode('⏳ Working — 10s | Bash: ls'))), client_id: 'status-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2', created_at: 1700000006},
    {seq: 7, device: 'dungae-bot', kind: 'application', epoch: 3, bytes: b64(Array.from(utf8.encode('답'))), client_id: 'dungae-bot-echo-1', created_at: 1700000007},
    // `status-` without the uuid tail is a normal message (the relay/bot/iOS rule).
    {seq: 8, device: 'dungae-bot', kind: 'application', epoch: 3, bytes: b64(Array.from(utf8.encode('status-report'))), client_id: 'status-report', created_at: 1700000008},
  ];
  const relay = fakeRelay((m, path) => {
    if (path.includes('ack=')) return {status: 200, body: {epoch: 3, events: [], cursor: 8, members: []}};
    return {status: 200, body: {epoch: 3, revision: 1, events, cursor: 5, first_seq: 1, members: []}};
  });
  const storage = memStorage();
  storage.setItem('hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family', JSON.stringify({joined: true, relaySeq: 5, epoch: 3, roster: ['dungae-bot', 'owner-web-aaaaaa']}));
  const statuses = [];
  const evs = {messages: []};
  const s = createRoomSession({room: 'family', device: 'owner-web-aaaaaa', database: 'family-mls-synthetic-hande-family', worker: bridge, relay, storage, policy: policy(),
    on: {message: m => evs.messages.push(m), status: st => statuses.push(st), log: () => {}, change: () => {}, notice: () => {}},
    setInterval: () => 1, clearInterval: () => {}});
  await s.open(); await s.activate();
  assert.deepEqual(statuses, [{sender: 'dungae-bot', text: '⏳ Working — 10s | Bash: ls', seq: 6, ts: 1700000006000}]);
  assert.ok(!evs.messages.some(x => x.seq === 6), 'a status is never a timeline message');
  assert.deepEqual(evs.messages.filter(x => x.kind === 'text').map(x => x.seq), [7, 8]);
  assert.deepEqual(w.history.map(r => r.seq), [7, 8], 'a status is never stored');
  assert.equal(s.state.relaySeq, 8);
  assert.ok(relay.calls.some(c => c.path.includes('ack=8')), 'the status event is acked like any other');
});

// #755 2a: 앱이 기기 단위 watch 모드면 방별 폴링을 안전망 간격으로 늦춘다(activate 전이면 다음 activate 가 그 간격을 쓴다).
test('setPollInterval: 양의 정수만 받고, 같은 값·잘못된 값은 무시한다', () => {
  const {s} = session({worker: {call: async () => ({ok: true, result: {}})}, relay: fakeRelay(() => ({status: 200, body: {}}))});
  assert.equal(s.pollMs, 4000);
  s.setPollInterval(60000);
  assert.equal(s.pollMs, 60000);
  for (const bad of [0, -1, 1.5, NaN, '4000']) s.setPollInterval(bad);
  assert.equal(s.pollMs, 60000);
  s.setPollInterval(4000);
  assert.equal(s.pollMs, 4000);
});

// #760 후속: sync 가 도는 중에 들어온 요청(기기 단위 watch 의 「바뀜」)은 버리지 않고, 끝난 뒤 한 번만 더 돈다.
// typing 해제·읽음처럼 행이 생기지 않는 변화는 다음 watch 가 다시 알려 주지 않으므로, 버리면 60 s 안전망까지 화면이 멈춘다.
test('sync 중 들어온 요청은 끝난 뒤 한 번 더 돈다 — 몰려도 한 번', async () => {
  let release = () => {};
  let gets = 0;
  let hold = false;
  const relay = fakeRelay(async (m, path) => {
    if (m === 'GET' && path.includes('/events')) {
      gets++;
      if (hold) { hold = false; await new Promise(r => { release = r; }); }
    }
    return {status: 200, body: {epoch: 0, revision: 0, events: [], cursor: 0, first_seq: 0, members: []}};
  });
  const {bridge} = fakeWorker();
  const {s} = session({worker: bridge, relay});
  await s.open(); await s.activate();
  const base = gets;
  hold = true;
  const first = s.sync({quiet: true});
  await new Promise(r => setImmediate(r));
  assert.equal(await s.sync({quiet: true}), undefined, '진행 중이면 바로 돌아온다');
  assert.equal(await s.sync({quiet: true}), undefined);
  assert.equal(gets - base, 1, '진행 중에는 새 요청을 보내지 않는다');
  release();
  await first;
  await new Promise(r => setTimeout(r, 20));
  assert.equal(gets - base, 2, '끝난 뒤 한 번만 더');
});

// #760 후속: 입력중이 보이는 동안 TTL+1 s 뒤 그 방을 한 번 더 본다 — watch 요청 사이 빈틈에 온 typing 해제를 놓쳐도 7 s 안에 지운다.
test('입력중이 보이면 TYPING_RECHECK_MS 뒤 한 번 더 sync — 중복 예약 없음, 입력중 없으면 예약 안 함, stop 이 치운다', async () => {
  const {TYPING_RECHECK_MS} = await import('../room.js');
  let typing = ['mom-web'];
  let gets = 0;
  const relay = fakeRelay((m, path) => {
    if (m === 'GET' && path.includes('/events')) gets++;
    return {status: 200, body: {epoch: 0, revision: 0, events: [], cursor: 0, first_seq: 0, members: [], typing}};
  });
  const timers = [];
  const cleared = [];
  const {bridge} = fakeWorker();
  const s = createRoomSession({room: 'family', device: 'owner-web-aaaaaa', database: 'db', worker: bridge, relay, storage: memStorage(), policy: policy(),
    on: {change: () => {}, message: () => {}, log: () => {}, notice: () => {}},
    setInterval: () => 1, clearInterval: () => {},
    setTimeout: (fn, ms) => { timers.push({fn, ms}); return timers.length; }, clearTimeout: id => cleared.push(id)});
  await s.open(); await s.activate();
  assert.equal(timers.length, 1, '입력중이 보이면 예약');
  assert.equal(timers[0].ms, TYPING_RECHECK_MS);
  await s.sync({quiet: true});
  assert.equal(timers.length, 1, '이미 예약돼 있으면 다시 걸지 않는다');
  typing = [];
  const before = gets;
  timers[0].fn();
  await new Promise(r => setTimeout(r, 10));
  assert.equal(gets, before + 1, '예약 시각에 한 번 sync');
  assert.equal(timers.length, 1, '입력중이 사라졌으면 다시 예약하지 않는다');
  typing = ['mom-web'];
  await s.sync({quiet: true});
  assert.equal(timers.length, 2, '다시 보이면 새로 예약');
  s.stop();
  assert.deepEqual(cleared, [2], 'stop 이 남은 예약을 치운다');
});

// ---- #766 B: 저장분까지만 열고(activate({connect: false})) 첫 sync 는 뒤에서(connect) ----
// 화면은 저장된 명단·대화로 먼저 그려지지만, 첫 sync 시도가 끝나기 전에는 이 방으로 아무것도 보내지 않는다.
const STORED_KEY = 'hande:room:family:owner-web-aaaaaa:family-mls-synthetic-hande-family';
function storedSession({relay, state = {joined: true, relaySeq: 5, epoch: 2, roster: ['owner-pc', 'owner-web-aaaaaa']}}) {
  const {bridge, w} = fakeWorker({fresh: false, group: ['owner-pc', 'owner-web-aaaaaa']});
  w.history.push({seq: 4, sender: 'owner-pc', client: 'owner-pc', kind: 'text', text: '저장된 글', bytes: []});
  const storage = memStorage();
  storage.setItem(STORED_KEY, JSON.stringify(state));
  return {...session({worker: bridge, relay, storage}), w};
}
const quietRoom = () => ({status: 200, body: {epoch: 2, events: [], cursor: 5, members: []}});

test('activate({connect: false}): 저장된 명단·대화만 올리고 릴레이를 부르지 않는다 — connect() 가 첫 sync 와 폴링을 한 번 시작한다 (#766 B)', async () => {
  const relay = fakeRelay(quietRoom);
  const {s, events: ev} = storedSession({relay});
  await s.open(); await s.activate({connect: false});
  assert.equal(relay.calls.length, 0, '저장분을 올리는 데 릴레이 왕복이 없다');
  assert.equal(s.state.started, true); assert.equal(s.state.joined, true);
  assert.deepEqual(s.state.roster, ['owner-pc', 'owner-web-aaaaaa']);
  assert.deepEqual(ev.messages.map(m => m.text), ['저장된 글'], '보관된 대화가 올라온다');
  assert.equal(s.state.live, false); assert.equal(s.state.timer, null); assert.equal(s.state.syncedAt, null);
  await s.connect();
  assert.deepEqual(relay.calls.map(c => `${c.method} ${c.path}`), ['GET /v2/rooms/family/events?device=owner-web-aaaaaa&after=5']);
  assert.equal(s.state.live, true); assert.equal(s.state.timer, 1); assert.notEqual(s.state.syncedAt, null);
  await s.connect();
  assert.equal(relay.calls.length, 1, '두 번 불러도 첫 sync·타이머는 한 번');
  assert.deepEqual(ev.messages.map(m => m.text), ['저장된 글'], '같은 글이 다시 올라오지 않는다');
});

test('첫 sync 전에는 보내기·첨부·초대·제거·방 만들기·키 게시가 거절되고 워커·릴레이에 아무것도 가지 않는다 (#766 B)', async () => {
  let posts = 0;
  const relay = fakeRelay(m => (m === 'GET' ? quietRoom() : (posts++, {status: 201, body: {seq: 6, epoch: 2}})));
  const {s, w} = storedSession({relay});
  await s.open(); await s.activate({connect: false});
  const before = w.calls.length;
  for (const run of [() => s.send('x'), () => s.sendAttachment(null), () => s.invite('mom-web-bbbbbb'), () => s.remove('owner-pc'), () => s.create(), () => s.publishKeyPackage()]) {
    await assert.rejects(run, /대화방이 준비되지 않았습니다/);
  }
  assert.equal(w.calls.length, before, '워커(MLS 상태)에 아무 작업도 가지 않았다');
  assert.equal(relay.calls.length, 0);
  await s.connect();
  assert.equal(await s.send('hello'), 6);
  // 보내기 직전 sync → 암호화 → POST 순서(예전 그대로).
  assert.deepEqual(relay.calls.map(c => c.method), ['GET', 'GET', 'POST']);
  assert.equal(w.calls.filter(c => c[1] === 'encrypt').length, 1);
  assert.equal(posts, 1);
});

test('첫 sync 가 릴레이에 닿지 못해도 시도가 끝나면 예전처럼 열린다 — 보내기는 암호화 전에 연결 실패를 알린다 (#766 B)', async () => {
  const relay = fakeRelay(() => { const e = new Error('연결 실패'); e.network = true; throw e; });
  const {s, w, events: ev} = storedSession({relay});
  await s.open(); await s.activate({connect: false});
  await s.connect();
  assert.equal(s.state.live, true); assert.equal(s.state.timer, 1, '방별 폴링(재시도)은 예전처럼 걸린다');
  assert.equal(s.state.syncedAt, null, '동기화된 적은 없다');
  assert.deepEqual(ev.messages.map(m => m.text), ['저장된 글']);
  await assert.rejects(() => s.send('x'), e => e.network === true);
  assert.equal(w.calls.filter(c => c[1] === 'encrypt').length, 0, '래칫을 쓰기 전에 멈춘다');
});

test('진행 중인 첫 sync 가 끝나기 전에는 열리지 않는다 (#766 B)', async () => {
  let release;
  const held = new Promise(r => { release = r; });
  const relay = fakeRelay(async () => { await held; return quietRoom(); });
  const {s, w} = storedSession({relay});
  await s.open(); await s.activate({connect: false});
  const connecting = s.connect();
  await new Promise(r => setTimeout(r, 5));
  assert.equal(relay.calls.length, 1); assert.equal(s.state.live, false);
  await assert.rejects(() => s.send('x'), /대화방이 준비되지 않았습니다/);
  assert.equal(w.calls.filter(c => c[1] === 'encrypt').length, 0);
  release(); await connecting;
  assert.equal(s.state.live, true);
});

test('activate() 기본값은 예전 그대로 — 돌아왔을 때 첫 sync 가 끝나 있고 폴링이 걸려 있다; 다시 open 하면 닫힌다 (#766 B)', async () => {
  const relay = fakeRelay(quietRoom);
  const {s} = storedSession({relay});
  await s.open(); await s.activate();
  assert.equal(relay.calls.length, 1);
  assert.equal(s.state.live, true); assert.equal(s.state.timer, 1);
  await s.open();
  assert.equal(s.state.live, false, '다시 연 방은 첫 sync 전으로 돌아간다');
});

test('⛔ 정지된 방은 connect 가 아무것도 하지 않는다 (#766 B)', async () => {
  const relay = fakeRelay(quietRoom);
  const halted = {seq: 12, committer: 'owner-pc', reason: 'removed_from_room', detail: '', at: '10:00', removed: true};
  const {s, events: ev} = storedSession({relay, state: {joined: true, relaySeq: 12, epoch: 2, roster: ['owner-pc', 'owner-web-aaaaaa'], halted}});
  await s.open(); await s.activate({connect: false});
  await s.connect();
  assert.equal(relay.calls.length, 0); assert.equal(s.state.timer, null);
  assert.ok(ev.messages.some(m => m.kind === 'system' && m.key === 'halt-12'));
  await assert.rejects(() => s.send('x'));
});

test('#837 send(text, {local}): local 은 내보내는 글에만 실리고 릴레이 POST 에는 없다 — checkSend 는 send 와 같은 검사를 동기로 (#766 B)', async () => {
  const relay = fakeRelay(m => (m === 'GET' ? quietRoom() : {status: 201, body: {seq: 6, epoch: 2}}));
  const {s, w, events: ev} = storedSession({relay});
  await s.open(); await s.activate({connect: false});
  assert.throws(() => s.checkSend(), /대화방이 준비되지 않았습니다/, '첫 sync 전에는 send 와 같이 막는다');
  assert.equal(relay.calls.length, 0);
  await s.connect();
  assert.doesNotThrow(() => s.checkSend());
  assert.equal(await s.send('hello', {local: 'out-1'}), 6);
  const post = relay.calls.find(c => c.method === 'POST');
  assert.deepEqual(Object.keys(post.body).sort(), ['bytes', 'client_id', 'device', 'epoch', 'kind'], '와이어 필드는 예전 그대로');
  assert.ok(!JSON.stringify(post.body).includes('out-1'));
  const own = ev.messages.find(m => m.kind === 'text' && m.text === 'hello');
  assert.equal(own.local, 'out-1');
  assert.equal(own.seq, 6);
  assert.ok(!('local' in w.history.at(-1)), '이력 행에도 없다');
  // local 없이 보내면 예전 모양 그대로(키 없음).
  assert.equal(await s.send('again'), 6);
  assert.ok(!('local' in ev.messages.at(-1)));
});
