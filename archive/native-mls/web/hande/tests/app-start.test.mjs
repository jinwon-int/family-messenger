// #766 B: 저장된 방·대화로 먼저 그리고 릴레이 동기화는 뒤에서 — app.js startApp 을 가짜 화면(ui)·워커·릴레이로 돌린다.
// DOM·wasm·IndexedDB 없음(node --test). 화면은 ui.renderShell 에 넘어간 모델로 본다(실제 DOM 반영은 브라우저 스모크 몫).
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {startApp} from '../app.js';
import {REQUEST_TIMEOUT_MS} from '../relay.js';
import {b64} from '../room.js';

const ME = 'mom-web-aaaaaa';
const utf8 = new TextEncoder();
const realSetTimeout = globalThis.setTimeout;
const sleep = ms => new Promise(r => realSetTimeout(r, ms));
async function until(cond, what, ms = 5000) {
  for (let waited = 0; waited < ms; waited += 2) { if (cond()) return; await sleep(2); }
  assert.fail(`기다리다 끝남: ${what}`);
}
/** 틀에 넣은 멤버 목록(u32 수, u32 길이 ‖ 이름 ‖ 32바이트 키) — room.js parseMembers · commit-policy 가 읽는 모양. */
function frame(members) {
  const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return [...b]; };
  return [...u32(members.length), ...members.flatMap(id => { const name = utf8.encode(id); return [...u32(name.length), ...name, ...new Uint8Array(32).fill(1)]; })];
}
function memStorage() {
  const m = new Map();
  return {getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => { m.set(k, String(v)); }, removeItem: k => { m.delete(k); }};
}
const text = (seq, sender, body) => ({seq, sender, client: sender, kind: 'text', text: body, bytes: []});

/**
 * 이 브라우저에 남아 있는 것: 신원(localStorage) + rooms 의 방마다 페이지 상태(참여·릴레이 커서)와 워커 쪽 그룹·보관된 대화.
 * rooms 가 비면 「이름은 정했지만 참여한 방이 없는 기기」(첫 실행 뒤와 같다).
 */
function device(rooms = []) {
  const storage = memStorage();
  storage.setItem('hande:identity', JSON.stringify({actor: 'mom', device: ME, createdAt: 1}));
  storage.setItem('hande:passphrase', 'p'.repeat(64));
  const stores = new Map();
  if (rooms.length) storage.setItem(`hande:rooms:${ME}`, JSON.stringify(rooms.map(r => r.room)));
  for (const r of rooms) {
    storage.setItem(`hande:room:${r.room}:${ME}:family-mls-synthetic-hande-${r.room}`,
      JSON.stringify({joined: true, pending: false, relaySeq: r.relaySeq, epoch: 1, roster: [ME, 'owner-pc'], halted: null}));
    stores.set(r.room, {group: [ME, 'owner-pc'], history: r.history});
  }
  return {storage, stores};
}
/** 다중 스토어 워커 대역: 방마다 그룹·보관 대화. ops 는 파사드 작업(`방:메서드`) 순서. */
function fakeWorker(stores) {
  const ops = [];
  const key = Array.from(new Uint8Array(32).fill(7));
  const out = (output = [], extra = {}) => ({ok: true, result: {cursor: 1, output, ...extra}});
  return {ops, has: () => true, spawn: async () => {}, stop() {},
    async call(_name, method, a) {
      if (method === 'unlock_cache') return {ok: true, result: {}};
      if (method === 'init_multi') return {ok: true, result: {fresh: false, migrated: false, unlock: 'cache', public_key: key}};
      if (method === 'open_room') {
        const fresh = !stores.has(a.room);
        if (fresh) stores.set(a.room, {group: null, history: []});
        return {ok: true, result: {revision: 0, cursor: 0, fresh, history: true, public_key: key}};
      }
      const store = stores.get(a.room);
      if (method === 'history_list') return {ok: true, result: store.history.map(r => ({...r, size: 0, received_at: 1700000000000 + r.seq}))};
      if (method === 'history_put') { store.history.push(a); return {ok: true, result: {seq: a.seq}}; }
      if (method !== 'operation') return {ok: true, result: {}};
      ops.push(`${a.room}:${a.method}`);
      switch (a.method) {
        case 'members': return store.group ? out(frame(store.group)) : {ok: false};
        case 'decrypt': return out(a.bytes, {sender: 'owner-pc', client: 'owner-pc'});
        // 다른 기기(owner-pc)가 이 기기를 내보내는 commit 의 stage 보고: 추가 없음 · 제거 = 나 · 갱신 없음 · 커밋 경로 = owner-pc.
        case 'stage_commit': return out([...frame([]), ...frame([ME]), ...frame([]), ...frame(['owner-pc'])], {transient: true});
        default: return out(a.bytes);
      }
    }};
}
/**
 * 릴레이 대역(fetch). hold 면 응답을 release() 까지 붙잡고(왕복이 진행 중), down 이면 닿지 못한다.
 * seen = 보낸 요청 순서, answered = 돌려준 응답 수.
 */
function fakeRelay(routes, {hold = false, down = false} = {}) {
  const waiting = [];
  const net = {seen: [], answered: 0, down,
    release() { hold = false; for (const go of waiting.splice(0)) go(); },
    async fetch(path, init = {}) {
      const method = init.method ?? 'GET';
      net.seen.push(`${method} ${path}`);
      if (hold) await new Promise(r => waiting.push(r));
      if (net.down) throw new TypeError('fetch failed');
      const r = routes(method, path) ?? {status: 404, body: null};
      net.answered++;
      return {status: r.status, json: async () => { if (r.body === null) throw new Error('본문 없음'); return r.body; }};
    }};
  return net;
}
/** 방별 events 와 방 목록만 답하는 릴레이. 나머지(/v2/watch·로비·순서 …)는 「그 경로를 모르는 옛 릴레이」(404, 본문 없음). */
function relayRoutes({listed, events = {}, enrolled = true}) {
  return (method, path) => {
    if (path === '/v2/me') return {status: 200, body: {subject: 'sub-1'}};
    if (path.startsWith('/v2/rooms?device=')) return enrolled ? {status: 200, body: {rooms: listed.map(room => ({room, member: true}))}} : {status: 403, body: {error: 'device_not_allowed'}};
    const m = /^\/v2\/rooms\/([a-z0-9-]+)\/(events|read)/.exec(path);
    if (!m) return null;
    if (m[2] === 'read') return {status: 200, body: {read_seq: 0}};
    if (method === 'POST') return {status: 201, body: {seq: 9, epoch: 1}};
    if (!(m[1] in events)) return {status: 404, body: {error: 'no_such_room'}};
    const after = Number(new URL(path, 'http://relay.invalid').searchParams.get('after'));
    return {status: 200, body: {epoch: 5, events: events[m[1]].filter(e => e.seq > after), cursor: 99, first_seq: 1, members: []}};
  };
}
const said = (seq, body) => ({seq, device: 'owner-pc', kind: 'application', epoch: 1, bytes: b64(utf8.encode(body)), client_id: `owner-pc-${seq}`, created_at: 1700000100 + seq});

/** startApp 을 띄운다. 화면은 calls(그린 순서)·shell()(마지막 renderShell 모델)로, 타이머는 걸린 것만 모아 둔다(돌리지 않음). */
function launch(t, {dev, net, wide = true, perf}) {
  const timers = {intervals: [], timeouts: []};
  const listeners = {};   // window 에 건 리스너(탭·온라인 복귀 — sync-recovery.js)
  const globals = {
    window: {matchMedia: () => ({matches: wide}), addEventListener(name, fn) { listeners[name] = fn; }},
    document: {addEventListener() {}, removeEventListener() {}, visibilityState: 'visible'},
    indexedDB: {databases: async () => [], deleteDatabase: () => ({})},
    Worker: class {},
    setInterval: (fn, ms) => { timers.intervals.push({fn, ms}); return timers.intervals.length; }, clearInterval() {},
    setTimeout: (fn, ms) => { timers.timeouts.push({fn, ms}); return timers.timeouts.length; }, clearTimeout() {},
  };
  const saved = Object.keys(globals).map(k => [k, Object.getOwnPropertyDescriptor(globalThis, k)]);
  for (const [k, value] of Object.entries(globals)) Object.defineProperty(globalThis, k, {value, configurable: true, writable: true});
  const info = console.info; console.info = () => {};
  t.after(() => {
    console.info = info;
    for (const [k, d] of saved) { if (d) Object.defineProperty(globalThis, k, d); else delete globalThis[k]; }
  });
  const calls = [];
  const ui = new Proxy({}, {get: (_, name) => (_root, model) => { calls.push({name, model}); return true; }});
  const root = {ownerDocument: globals.document, querySelector: () => null, querySelectorAll: () => []};
  const worker = fakeWorker(dev.stores);
  let clock = 0;
  const app = startApp(root, {storage: dev.storage, fetch: net.fetch, now: () => (clock += 7), perf, ui, worker}).state;
  const shell = () => calls.findLast(c => c.name === 'renderShell')?.model ?? null;
  const startupLines = () => app.logs.filter(l => l.includes('첫 화면까지'));
  return {app, calls, shell, worker, timers, startupLines, fire: name => listeners[name]()};
}
const bodies = room => room.timeline.map(e => e.body);
const rows = model => Object.fromEntries(model.list.rooms.map(r => [r.roomId, r.state]));
const firstAt = (seen, test) => seen.findIndex(test);
const isListing = p => p.startsWith('GET /v2/rooms?device=');
const isEvents = room => p => p.startsWith(`GET /v2/rooms/${room}/events`);

/** 저장된 방 하나: 보관된 대화 두 줄(seq 1·2)과 페이지 커서. */
const family = (relaySeq = 2) => ({room: 'family', relaySeq, history: [text(1, 'owner-pc', '안녕'), text(2, ME, '잘 받았어요')]});

test('저장된 방이 있으면 릴레이 응답을 하나도 받기 전에 방 목록·대화를 그리고, 응답이 오면 제자리에서 맞춘다', async t => {
  // 보관된 대화는 seq 2 까지인데 페이지 커서는 1(새로고침이 sync 중간에 끼어든 경우) — 릴레이가 seq 2 를 다시 줘도 말풍선이 겹치면 안 된다.
  const net = fakeRelay(relayRoutes({listed: ['family', 'fam2'], events: {family: [said(2, '잘 받았어요'), said(3, '새 글')], fam2: []}}), {hold: true});
  const h = launch(t, {dev: device([family(1)]), net});
  await until(() => h.shell(), '저장분으로 그린 첫 화면');
  const first = h.shell();
  assert.equal(net.answered, 0, '첫 화면은 릴레이 응답을 기다리지 않는다');
  assert.ok(!net.seen.some(isListing), '/v2/rooms 는 아직 묻지도 않았다');
  assert.equal(h.app.phase, 'ready');
  assert.deepEqual(rows(first), {family: 'joined'});
  assert.equal(first.room.roomId, 'family');
  assert.deepEqual(bodies(first.room), ['안녕', '잘 받았어요']);
  assert.equal(first.room.joined, true);
  // 계측 줄: 저장분 화면이라고 남고, 방 목록 구간이 없다.
  assert.equal(h.startupLines().length, 1);
  assert.match(h.startupLines()[0], /첫 화면까지 \d+ ms \(대화 화면 · 저장분\) — 스크립트 \d+ · 설정 \d+ · 신원 열기 \d+ · 방 열기 \d+( · 그리기 \d+)?$/);
  assert.equal(h.app.startup.phase, 'stored');
  // 첫 sync 가 끝나기 전: 작성창·선택지는 잠겨 있고, 보내기를 불러도 암호화·POST 가 없다.
  assert.equal(first.room.syncing, true);
  assert.equal(await first.room.onSend('미리 보냄'), false);
  assert.ok(h.calls.some(c => c.name === 'setStatus' && c.model === '대화방이 준비되지 않았습니다'));
  assert.ok(!h.worker.ops.includes('family:encrypt'));
  assert.ok(!net.seen.some(p => p.startsWith('POST /v2/rooms/family/events')));
  // 그 사이 온라인 복귀가 와도 기기 refresh(/v2/me·/v2/rooms …)는 방별 첫 sync 를 앞지르지 않는다.
  h.fire('online');
  await sleep(20);
  assert.ok(h.app.logs.some(l => l.includes('복귀 동기화')));
  assert.equal(net.seen.filter(p => p === 'GET /v2/me').length, 1, '시작 때의 한 번뿐');

  net.release();
  await until(() => h.app.dev.state.enrolled === true && h.app.rooms.get('fam2')?.session.state.live && !h.shell().room.syncing, '릴레이 반영');
  await until(() => !h.app.sending && h.app.tick !== null, '시작 마무리');
  const later = h.shell();
  assert.deepEqual(bodies(later.room), ['안녕', '잘 받았어요', '새 글'], '새 글은 뒤에 붙고 겹치지 않는다');
  assert.equal(new Set(later.room.timeline.map(e => e.key)).size, 3);
  assert.equal(later.room.timeline, first.room.timeline, '타임라인을 새로 만들지 않고 같은 목록에 붙인다(화면은 행만 맞춘다)');
  assert.equal(later.list.currentRoomId, 'family', '보던 방이 그대로다');
  assert.deepEqual(rows(later), {family: 'joined', fam2: 'pending'}, '릴레이 목록의 새 방이 나타난다');
  assert.equal(later.room.syncing, false);
  // 릴레이 호출 순서는 예전 그대로: 방별 첫 sync → 방 목록.
  assert.ok(firstAt(net.seen, isEvents('family')) < firstAt(net.seen, isListing));
  assert.equal(h.startupLines().length, 1, '계측 줄은 한 번만');
  assert.ok(h.app.logs.some(l => /저장분으로 먼저 그림 — 방 동기화까지 \d+ ms$/.test(l)));
  assert.ok(!h.calls.some(c => c.name === 'renderStarting' && h.calls.indexOf(c) > h.calls.findIndex(x => x.name === 'renderShell')), '시작 화면으로 돌아가지 않는다');
  // 동기화 뒤에는 예전처럼 보낸다: 직전 sync → 암호화 → POST(#837: 뒤에서 — 말풍선은 누르는 즉시).
  assert.equal(await later.room.onSend('이제 보냄'), true);
  await until(() => h.app.rooms.get('family').entries.some(e => e.body === '이제 보냄' && e.state === null && e.seq === 9), '릴레이가 받은 내 글');
  assert.ok(h.worker.ops.includes('family:encrypt'));
  assert.ok(net.seen.some(p => p.startsWith('POST /v2/rooms/family/events')));
});

// #853: 첫 sync 요청이 응답 없이 멈추면(절전 복귀·망 전환) 예전엔 작성창이 영영 잠겼다 — 시간 제한이 지나면 풀린다.
test('#853 첫 sync 요청이 멈춰도 릴레이 시간 제한이 지나면 작성창 잠금이 풀리고 연결 표시가 뜬다', async t => {
  const net = fakeRelay(relayRoutes({listed: ['family'], events: {family: []}}), {hold: true});
  const h = launch(t, {dev: device([family()]), net});
  await until(() => h.shell() && net.seen.some(isEvents('family')), '저장분 화면 + 첫 sync 요청');
  assert.equal(h.shell().room.syncing, true, '응답 전에는 잠겨 있다');
  await sleep(30);
  assert.equal(h.shell().room.syncing, true, '시간 제한 전에는 계속 잠겨 있다(예전엔 여기서 영영 멈췄다)');
  const fired = h.timers.timeouts.filter(x => x.ms === REQUEST_TIMEOUT_MS);
  assert.ok(fired.length > 0, '릴레이 요청마다 시간 제한 타이머가 걸린다');
  for (const x of fired) x.fn();
  await until(() => h.shell().room.syncing === false, '시간 제한 뒤 작성창 잠금 해제');
  assert.equal(h.shell().room.offline, true, '연결 배너');
  assert.equal(h.app.rooms.get('family').session.state.live, true);
  net.release();
});

// 이 시험은 화면·릴레이 호출 순서만 본다(새로 생긴 상태 값은 보지 않는다) — 이 변경 전의 app.js 에서도 그대로 통과한다.
test('저장된 방이 없으면(첫 실행·참여 전) 예전처럼 방 sync 와 방 목록 응답 뒤에야 시작 화면을 벗어난다', async t => {
  const net = fakeRelay(relayRoutes({listed: []}), {hold: true});
  const h = launch(t, {dev: device(), net, wide: false});
  await until(() => net.seen.some(isEvents('family')), '기본 방의 첫 sync 요청');
  await sleep(30);
  assert.equal(h.shell(), null, '릴레이 응답 전에는 대화 화면을 그리지 않는다');
  assert.equal(h.calls.at(-1).name, 'renderStarting');
  assert.equal(h.app.phase, 'starting');
  assert.ok(!net.seen.some(isListing), '방 목록은 방 sync 뒤에 묻는다');
  assert.deepEqual(h.startupLines(), []);

  net.release();
  await until(() => h.shell(), '릴레이 응답 뒤 첫 화면');
  assert.ok(net.answered > 0);
  assert.ok(firstAt(net.seen, isEvents('family')) < firstAt(net.seen, isListing));
  assert.deepEqual(rows(h.shell()), {family: 'pending'});
  assert.equal(h.shell().room, null);
  assert.notEqual(h.app.rooms.get('family').session.state.syncedAt, null, '그릴 때는 방의 첫 sync 가 끝나 있다');
  assert.ok(!h.shell().room?.syncing);
  assert.equal(h.startupLines().length, 1);
  assert.match(h.startupLines()[0], /첫 화면까지 \d+ ms \(대화 화면\) — 스크립트 \d+ · 설정 \d+ · 신원 열기 \d+ · 방 열기 \d+ · 방 목록 \d+/);
  assert.equal(h.app.startup.phase, 'ready');
  assert.ok(!h.app.logs.some(l => l.includes('저장분으로 먼저 그림')));
});

test('릴레이에 닿지 않아도 저장된 대화가 보이고 연결 표시가 뜬다 — 재시도 타이머는 예전처럼 걸리고, 닿으면 이어서 맞춘다', async t => {
  const net = fakeRelay(relayRoutes({listed: ['family'], events: {family: [said(3, '돌아와서 받은 글')]}}), {down: true});
  const h = launch(t, {dev: device([family()]), net});
  await until(() => h.shell()?.room?.offline && h.app.tick !== null, '저장분 + 연결 끊김 표시');
  const down = h.shell();
  assert.equal(h.app.phase, 'ready');
  assert.deepEqual(bodies(down.room), ['안녕', '잘 받았어요']);
  assert.equal(down.list.sync.reconnecting, true, '목록의 연결 상태줄');
  assert.equal(down.room.offline, true, '대화의 연결 배너');
  assert.equal(h.app.startup.phase, 'stored');
  assert.ok(h.app.logs.some(l => l.includes('방 목록 실패')));
  // 예전과 같은 재시도: 방별 폴링(4초)과 기기 틱(8초)이 걸려 있다. 첫 sync 시도는 끝났으므로 작성창은 예전처럼 열려 있고,
  // 보내기는 암호화 전에 연결 실패로 끝난다 — #837: 말풍선은 바로 뜨고 「전송 안 됨」으로 바뀐다(래칫은 쓰지 않는다).
  assert.deepEqual(h.timers.intervals.map(i => i.ms).sort((a, b) => a - b), [4000, 8000]);
  assert.equal(down.room.syncing, false);
  assert.equal(await down.room.onSend('못 보냄'), true);
  await until(() => h.shell().room.timeline.some(e => e.body === '못 보냄' && e.state === 'failed'), '전송 안 됨 말풍선');
  assert.ok(!h.worker.ops.includes('family:encrypt'));
  assert.equal(h.shell().room.timeline.filter(e => e.body === '못 보냄').length, 1);

  net.down = false;
  for (const timer of h.timers.intervals) timer.fn();
  await until(() => h.app.dev.state.enrolled === true && !h.shell().room.offline && h.shell().room.timeline.length === 4, '다시 닿은 뒤 반영');
  assert.deepEqual(bodies(h.shell().room), ['안녕', '잘 받았어요', '돌아와서 받은 글', '못 보냄'], '보내지 못한 글은 맨 아래에 「전송 안 됨」으로 남는다');
  assert.equal(h.shell().list.sync.reconnecting, false);
  // 「다시 보내기」: 같은 글을 새 보내는 글로 — 이번에는 릴레이가 받고, 말풍선은 여전히 하나다.
  const failed = h.shell().room.timeline.find(e => e.state === 'failed');
  h.shell().room.onRetrySend(failed);
  assert.equal(h.shell().room.timeline.filter(e => e.body === '못 보냄').length, 1);
  await until(() => h.shell().room.timeline.some(e => e.body === '못 보냄' && e.state === null && e.seq === 9), '다시 보낸 글 확정');
  assert.deepEqual(bodies(h.shell().room), ['안녕', '잘 받았어요', '돌아와서 받은 글', '못 보냄']);
  assert.ok(h.worker.ops.includes('family:encrypt'));
});

test('뒤에서 맞추기: 새 방은 나타나고, 그새 내보내진 방은 ⛔ 로 바뀐다 — 보던 방과 그 대화는 그대로다', async t => {
  const removal = {seq: 2, device: 'owner-pc', kind: 'commit', epoch: 1, bytes: b64([0]), created_at: 1700000200};
  const net = fakeRelay(relayRoutes({listed: ['family', 'fam3'], events: {family: [], fam2: [removal], fam3: []}}), {hold: true});
  const dev = device([family(), {room: 'fam2', relaySeq: 1, history: [text(1, 'owner-pc', '둘째 방 글')]}]);
  const h = launch(t, {dev, net});
  await until(() => h.shell(), '저장분으로 그린 첫 화면');
  const first = h.shell();
  assert.equal(net.answered, 0);
  assert.deepEqual(rows(first), {family: 'joined', fam2: 'joined'});

  net.release();
  await until(() => h.app.rooms.get('fam3')?.session.state.live && h.app.tick !== null, '릴레이 반영');
  const later = h.shell();
  assert.deepEqual(rows(later), {family: 'joined', fam2: 'halted', fam3: 'pending'});
  assert.equal(h.app.rooms.get('fam2').session.state.halted.removed, true);
  assert.deepEqual(h.app.rooms.get('fam2').entries.map(e => e.kind), ['text', 'system'], '내보내진 방의 저장된 글은 남고 안내 한 줄이 붙는다');
  assert.equal(later.list.currentRoomId, 'family');
  assert.equal(later.room.timeline, first.room.timeline);
  assert.deepEqual(bodies(later.room), ['안녕', '잘 받았어요']);
  assert.deepEqual([...h.app.relayRooms].sort(), ['fam3', 'family']);
});

test('저장분으로 그린 뒤 릴레이가 이 기기를 받지 않으면(403) 예전처럼 등록 화면으로 간다', async t => {
  const net = fakeRelay(relayRoutes({listed: [], events: {family: []}, enrolled: false}), {hold: true});
  const h = launch(t, {dev: device([family()]), net});
  await until(() => h.shell(), '저장분으로 그린 첫 화면');
  net.release();
  await until(() => h.calls.at(-1).name === 'renderEnroll', '등록 화면');
  assert.equal(h.app.phase, 'enroll');
  assert.equal(h.app.startup.phase, 'stored', '계측 줄은 처음 그린 화면 기준으로 한 번');
});

test('시작 네트워크 줄: 첫 화면 줄 바로 뒤에 한 번 남고 진단 복사 요약에는 startup: 다음 줄 — 주소·식별값은 없다', async t => {
  // 브라우저 타이밍 대역. 대본 시계는 7 ms 씩 가므로 앱 스크립트 시작(script 구간)은 7 이다 — 그 전에 끝난 파일만 센다.
  const asked = [];
  const perf = {getEntriesByType(type) {
    asked.push(type);
    if (type === 'navigation') return [{name: 'https://app.example/?from=login', redirectStart: 0, redirectEnd: 0, workerStart: 0, fetchStart: 1, responseStart: 2, responseEnd: 3}];
    return [
      {name: 'https://app.example/app.js?v=1', responseEnd: 5, transferSize: 300, encodedBodySize: 9000, decodedBodySize: 30000, workerStart: 4},
      {name: 'https://app.example/ui.js', responseEnd: 6, transferSize: 4396, encodedBodySize: 4096, decodedBodySize: 9000, workerStart: 4},
      {name: 'https://app.example/config.json', responseEnd: 9, transferSize: 500, encodedBodySize: 200, decodedBodySize: 200, workerStart: 0},
      {name: `https://app.example/v2/rooms?device=${ME}`, responseEnd: 6, transferSize: 900, encodedBodySize: 600, decodedBodySize: 600, workerStart: 0},
    ];
  }};
  const net = fakeRelay(relayRoutes({listed: ['family'], events: {family: []}}));
  const h = launch(t, {dev: device([family()]), net, perf});
  await until(() => h.shell() && h.app.tick !== null, '첫 화면과 시작 마무리');
  const expected = '시작 네트워크: 리다이렉트 0 · HTML 요청 1 · HTML 응답 2 · HTML 끝 3 · 파일 2개 (캐시 0 · 재검증 1 · 받음 1 · 전송 5 KB) · 마지막 파일 ui.js 6 · 서비스 워커 경유 2 · 파일 뒤 실행 1 · 스크립트 시작 7';
  assert.equal(h.app.startupNet, expected);
  const at = h.app.logs.findIndex(l => l.includes('첫 화면까지'));
  assert.ok(h.app.logs[at + 1].endsWith(` ${expected}`), '첫 화면 줄 바로 다음 기록');
  assert.equal(h.app.logs.filter(l => l.includes('시작 네트워크')).length, 1, '다시 그려도 한 번만');
  assert.equal(h.startupLines().length, 1, '기존 줄은 그대로 한 번');
  assert.deepEqual(asked, ['navigation', 'resource'], '브라우저 타이밍은 첫 화면에서 한 번만 읽는다');

  // 진단 기록 복사: startup: 줄 바로 아래에 startup-net: 줄.
  let copied = null;
  const nav = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  Object.defineProperty(globalThis, 'navigator', {value: {clipboard: {writeText: async text => { copied = text; }}}, configurable: true, writable: true});
  t.after(() => { if (nav) Object.defineProperty(globalThis, 'navigator', nav); else delete globalThis.navigator; });
  h.shell().list.onOpenNotify();
  assert.equal(await h.calls.findLast(c => c.name === 'openNotifySheet').model.onCopyLogs(), true);
  const lines = copied.split('\n');
  const i = lines.findIndex(l => l.startsWith('startup: '));
  assert.match(lines[i], /^startup: 첫 화면까지 \d+ ms \(대화 화면 · 저장분\) — /);
  assert.equal(lines[i + 1], `startup-net: ${expected}`);
  assert.equal(lines[i + 2], 'rooms:');
  assert.doesNotMatch(lines[i + 1], /https?|example|[/?=]|v2|login|config|mom-web/);
});

// launch 는 전역(window·타이머 …)을 시험 하나에 한 번 바꿔 끼우므로 경우마다 시험을 따로 둔다.
for (const [what, perf] of [['API 없음', {}], ['읽다가 던짐', {getEntriesByType() { throw new Error('blocked'); }}], ['문서 항목 없음', {getEntriesByType: () => []}]]) {
  test(`시작 네트워크 줄: 브라우저 타이밍을 읽지 못하면(${what}) 줄 없이 그대로 시작한다`, async t => {
    const net = fakeRelay(relayRoutes({listed: ['family'], events: {family: []}}));
    const h = launch(t, {dev: device([family()]), net, perf});
    await until(() => h.shell() && h.app.tick !== null, '첫 화면과 시작 마무리');
    assert.equal(h.startupLines().length, 1);
    assert.equal(h.app.startupNet, '');
    assert.ok(!h.app.logs.some(l => l.includes('시작 네트워크')));
    assert.equal(h.app.phase, 'ready');
  });
}

test('화면 배선: 작성창은 syncing 동안 잠기고(끌어다 놓기 포함), 풀릴 때 넓은 화면에서만 커서를 둔다', () => {
  const ui = readFileSync(new URL('../ui.js', import.meta.url), 'utf8');
  assert.match(ui, /const canCompose = Boolean\(room\.joined\) && !room\.halted && !room\.consentRequired && !room\.syncing;/);
  assert.match(ui, /current\.joined && !current\.halted && !current\.consentRequired && !current\.syncing\) current\.onAttach/);
  assert.match(ui, /const wasSyncing = Boolean\(liveProps\.get\(screen\)\?\.syncing\);\s*liveProps\.set\(screen, room\);/);
  assert.match(ui, /if \(wasSyncing && built\.canCompose && isWide\(\) && document\.activeElement === document\.body\) \{/);
});

// ---- #837: 보내는 즉시 「보내는 중」 말풍선 — 작성창이 릴레이 응답을 기다리지 않는다 ----

/** POST 를 붙잡을 수 있는 릴레이: 보낸 글(가짜 워커의 encrypt 는 평문 그대로)을 순서대로 적고, seq 는 10 부터 하나씩. */
function sendRelay({post = null} = {}) {
  const routes = relayRoutes({listed: ['family'], events: {family: []}});
  const net = fakeRelay(routes);
  const posted = [], held = [];
  let seq = 9, holding = false;
  const fetch = net.fetch;
  net.fetch = async (path, init = {}) => {
    if (init.method === 'POST' && /\/events$/.test(path)) {
      const payload = JSON.parse(init.body);
      if (holding) await new Promise(r => held.push(r));
      posted.push(new TextDecoder().decode(Uint8Array.from(atob(payload.bytes), c => c.charCodeAt(0))));
      const r = post?.(payload, posted.length) ?? {status: 201, body: {seq: ++seq, epoch: 1}};
      return {status: r.status, json: async () => r.body};
    }
    return fetch(path, init);
  };
  return {net, posted, hold() { holding = true; }, release() { holding = false; for (const go of held.splice(0)) go(); }, get waiting() { return held.length; }};
}
const mine = room => room.timeline.filter(e => e.isMe && !['안녕', '잘 받았어요'].includes(e.body));
const ready = h => h.shell() && h.app.tick !== null && !h.shell().room.syncing;

test('#837 보내기를 누르면 릴레이 응답 전에 「보내는 중」 말풍선이 뜨고 작성창은 잠기지 않는다 — 받으면 그 자리에서 확정, 순서도 그대로', async t => {
  const r = sendRelay();
  const dev = device([family()]);
  const h = launch(t, {dev, net: r.net});
  await until(() => ready(h), '시작 마무리');
  r.hold();
  assert.equal(await h.shell().room.onSend('첫째'), true);
  // 응답 전: 말풍선 하나(보내는 중), 작성창은 보내는 중 표시 없이 열려 있다 — 곧바로 다음 글을 보낼 수 있다.
  assert.deepEqual(mine(h.shell().room).map(e => [e.body, e.state]), [['첫째', 'sending']]);
  assert.equal(h.shell().room.sending, false, '작성창을 잠그지 않는다');
  assert.equal(await h.shell().room.onSend('둘째'), true);
  assert.equal(await h.shell().room.onSend('셋째'), true);
  assert.deepEqual(mine(h.shell().room).map(e => [e.body, e.state]), [['첫째', 'sending'], ['둘째', 'sending'], ['셋째', 'sending']]);
  await until(() => r.waiting === 1, '첫째 POST 대기');
  assert.equal(r.waiting, 1, '한 번에 하나씩 — 앞 글이 끝나야 다음 글의 sync·암호화·POST');
  const first = mine(h.shell().room)[0];
  r.release();
  await until(() => mine(h.shell().room).every(e => e.state === null), '모두 확정');
  assert.deepEqual(r.posted, ['첫째', '둘째', '셋째'], '누른 순서대로 나간다');
  assert.deepEqual(mine(h.shell().room).map(e => [e.body, e.seq]), [['첫째', 10], ['둘째', 11], ['셋째', 12]]);
  assert.equal(mine(h.shell().room)[0], first, '새 줄이 아니라 같은 말풍선이 확정된다');
  assert.equal(new Set(h.shell().room.timeline.map(e => e.key)).size, h.shell().room.timeline.length);
  assert.deepEqual(dev.stores.get('family').history.slice(2).map(row => [row.text, row.seq]), [['첫째', 10], ['둘째', 11], ['셋째', 12]], '확정된 글은 예전처럼 이력에');
});

test('#837 보내는 중 글은 이력·저장소에 남지 않는다 — 새로고침 뒤 유령 말풍선이 없다', async t => {
  const r = sendRelay();
  const dev = device([family()]);
  const h = launch(t, {dev, net: r.net});
  await until(() => ready(h), '시작 마무리');
  r.hold();
  await h.shell().room.onSend('가는 중');
  await until(() => r.waiting === 1, 'POST 대기');
  const history = () => dev.stores.get('family').history.map(row => row.text);
  assert.ok(!history().includes('가는 중'), '응답 전에는 보관 이력에 없다');
  assert.ok(!dev.storage.getItem(`hande:room:family:${ME}:family-mls-synthetic-hande-family`).includes('가는 중'), '방 페이지 상태에도 없다');
  r.release();
  await until(() => history().includes('가는 중'), '받은 뒤 이력에 들어감');
  assert.equal(history().filter(x => x === '가는 중').length, 1);
});

test('#837 실패하면 그 말풍선이 「전송 안 됨」이 되고, 다시 보내기는 같은 글을 새로 보낸다 — 말풍선은 하나', async t => {
  const r = sendRelay({post: (_payload, n) => (n === 1 ? {status: 500, body: {error: 'internal'}} : null)});
  const h = launch(t, {dev: device([family()]), net: r.net});
  await until(() => ready(h), '시작 마무리');
  assert.equal(await h.shell().room.onSend('다시 갈 글'), true);
  await until(() => mine(h.shell().room).some(e => e.state === 'failed'), '전송 안 됨');
  assert.deepEqual(mine(h.shell().room).map(e => [e.body, e.state]), [['다시 갈 글', 'failed']]);
  assert.ok(h.calls.some(c => c.name === 'setStatus' && /보내지 못했습니다/.test(c.model)), '사유는 상태줄에');
  const failed = mine(h.shell().room)[0];
  h.shell().room.onRetrySend(failed);
  assert.deepEqual(mine(h.shell().room).map(e => [e.body, e.state]), [['다시 갈 글', 'sending']], '실패 말풍선 대신 새 보내는 중 말풍선');
  await until(() => mine(h.shell().room).every(e => e.state === null), '다시 보낸 글 확정');
  assert.deepEqual(mine(h.shell().room).map(e => [e.body, e.seq]), [['다시 갈 글', 10]]);
  assert.deepEqual(r.posted, ['다시 갈 글', '다시 갈 글'], '다시 보내기는 새로 암호화해 한 번 더 POST');
});

test('#837 릴레이가 이미 있는 seq 로 답해도(겹쳐 받음) 말풍선은 하나만 남는다', async t => {
  // seq 2 는 보관 이력에 이미 있는 내 글 — 릴레이가 그 seq 를 다시 돌려주는 경우(중복 POST 의 duplicate 응답).
  const r = sendRelay({post: () => ({status: 201, body: {seq: 2, epoch: 1, duplicate: true}})});
  const h = launch(t, {dev: device([family()]), net: r.net});
  await until(() => ready(h), '시작 마무리');
  await h.shell().room.onSend('잘 받았어요');
  await until(() => !h.shell().room.timeline.some(e => e.state === 'sending'), '정리');
  assert.deepEqual(bodies(h.shell().room), ['안녕', '잘 받았어요']);
  assert.ok(!h.shell().room.timeline.some(e => e.state));
});

test('#837 화면 배선: 말풍선 아래 전송 상태와 「다시 보내기」는 실패한 내 글에만', () => {
  const ui = readFileSync(new URL('../ui.js', import.meta.url), 'utf8');
  assert.match(ui, /entry\.state === 'sending' \|\| entry\.state === 'queued' \|\| entry\.state === 'failed'/);
  assert.match(ui, /const retrySend = sendState === 'failed' && onRetrySend/);
  assert.match(ui, /\(entry\) => liveProps\.get\(screen\)\?\.onRetrySend\?\.\(entry\)/);
});
