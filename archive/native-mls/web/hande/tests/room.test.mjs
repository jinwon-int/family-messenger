// room.js against a fake durable worker and a scripted relay (pure node:test, no
// wasm, no DOM): the relay-app flow order, 403 enrollment wait, Welcome join,
// application decrypt → history → ack, send with one CAS retry, invite commit →
// own echo → targeted Welcome, refused commit halt, removal halt, #296 resume.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRoomSession, parseMembers, nextDeviceId, b64} from '../room.js';

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

function fakeWorker({fresh = true, group = null, decrypt = () => ({sender: 'owner-pc', client: 'owner-pc'})} = {}) {
  const w = {group, calls: [], history: [], spawned: true, pendingGroup: null, acked: [], opened: [], reset: []};
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
      const out = o => ({ok: true, result: {cursor: 1, output: o ?? [], ...(m === 'stage_commit' ? {transient: true} : {})}});
      switch (m) {
        case 'fingerprint': return out(Array.from(utf8.encode('f'.repeat(64))));
        case 'members': return w.group ? out(frameMembers(w.group)) : {ok: false};
        case 'members_after_pending': return out(frameMembers(w.pendingGroup ?? w.group));
        case 'create': w.group = ['owner-web-aaaaaa']; return out();
        case 'join': w.group = ['bot-1', 'owner-pc', 'owner-web-aaaaaa']; return out();
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
function session({worker, relay, pol, storage = memStorage(), device = 'owner-web-aaaaaa'}) {
  const events = {messages: [], logs: [], notices: [], changes: 0};
  const s = createRoomSession({room: 'family', device, database: 'family-mls-synthetic-hande-family', worker, relay, storage, policy: pol ?? policy(),
    on: {change: () => events.changes++, message: m => events.messages.push(m), log: l => events.logs.push(l), notice: (t, tone) => events.notices.push([t, tone])},
    setInterval: () => 1, clearInterval: () => {}});
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
  await assert.rejects(() => s.send('again'), /403 not_a_member/);
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
  const desc = encodeDescriptor({blob: enc.blob, size: enc.size, key: enc.key, nonce: enc.nonce, name: '../사진.jpg'});
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
  assert.ok(ev.messages.some(x => x.kind === 'undecryptable' && x.seq === 10));
  assert.ok(!ev.messages.some(x => x.kind === 'text'));
});
