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

function fakeWorker({fresh = true, group = null, decrypt = () => ({sender: 'owner-pc', client: 'owner-pc'}), joinRefuses = () => false} = {}) {
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
