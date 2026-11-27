// 형제 초대 대기열·빠진 방 재탐색 공용 벡터(#366 3h-a, #616) — host-core `sibling_queue`(ios-ffi)·Android `core/SelfService`·
// `SiblingRescan` 과 같은 파일 archive/native-mls/tests/fixtures/sibling-queue-vectors.json 을 웹 self-service.js 로 돌린다.
// 웹 코드는 바꾸지 않았다(같은 규칙을 JS 로 갖고 있다). `*_text_*` 절은 Android 저장 형식이라 웹은 건너뛴다(웹은 JSON 으로 저장).
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {
  SIBLING_INVITE_TTL_MS, SIBLING_LOBBY_RECHECK_MS, SIBLING_RESCAN_INTERVAL_MS, SIBLING_RESCAN_DEFER_MS,
  enqueueSiblingInvites, splitSiblingQueue, siblingInviteBudget, nextSiblingEntry, siblingDevices, rescanDue, siblingRescanTurn,
} from '../self-service.js';

const vectors = JSON.parse(readFileSync(new URL('../../../tests/fixtures/sibling-queue-vectors.json', import.meta.url), 'utf8'));
const cases = (key) => {
  assert.ok(vectors[key].length > 0, key);
  return vectors[key];
};
// 벡터 항목 {target, rooms, since, progress, recheck_at, origin}(null = 없음) ↔ 웹 항목(없는 칸은 빠짐, recheckAt).
const toWeb = (e) => {
  const o = {target: e.target, rooms: [...e.rooms], since: e.since};
  if (e.progress !== null) o.progress = e.progress;
  if (e.recheck_at !== null) o.recheckAt = e.recheck_at;
  if (e.origin !== null) o.origin = e.origin;
  return o;
};
const fromWeb = (e) => (e === null ? null : {
  target: e.target, rooms: e.rooms, since: e.since,
  progress: Number.isFinite(e.progress) ? e.progress : null,
  recheck_at: Number.isFinite(e.recheckAt) ? e.recheckAt : null,
  origin: e.origin ?? null,
});
const stateToWeb = (s) => ({last: s.last, pending: Object.fromEntries(s.pending.map((p) => [p.key, p.seen]))});

test('constants: same values as host-core and Android', () => {
  const c = vectors.constants;
  assert.equal(SIBLING_RESCAN_INTERVAL_MS, c.rescan_interval_ms);
  assert.equal(SIBLING_RESCAN_DEFER_MS, c.rescan_deferral_ms);
  assert.equal(SIBLING_LOBBY_RECHECK_MS, c.sibling_lobby_recheck_ms);
  assert.equal(SIBLING_INVITE_TTL_MS, c.sibling_invite_ttl_ms);
});

test('queue rules: enqueue · split · budget · next entry', () => {
  for (const c of cases('enqueue')) {
    const got = enqueueSiblingInvites(c.queue.map(toWeb), c.target, c.rooms, c.now, {origin: c.origin});
    assert.deepEqual(got.map(fromWeb), c.expect, c.name);
  }
  for (const c of cases('split')) {
    const r = splitSiblingQueue(c.queue.map(toWeb), c.now, c.ttl);
    assert.deepEqual({live: r.live.map((e) => e.target), expired: r.expired.map((e) => e.target)}, c.expect, c.name);
  }
  for (const c of cases('budget')) {
    const b = siblingInviteBudget(c.live === null ? null : {live: c.live});
    assert.equal(b === Infinity ? null : b, c.expect, c.name);
  }
  for (const c of cases('next_entry')) {
    const got = nextSiblingEntry(toWeb(c.entry), c.remaining, {now: c.now, progressed: c.progressed, starved: c.starved});
    assert.deepEqual(fromWeb(got), c.expect, c.name);
  }
});

test('rescan rules: siblings · due · turn', () => {
  for (const c of cases('rescan_siblings')) {
    assert.deepEqual(siblingDevices(c.me === null ? null : vectors.mes[c.me], c.device), c.expect, c.name);
  }
  for (const c of cases('rescan_due')) assert.equal(rescanDue(stateToWeb(c.state), c.now), c.expect, c.name);
  for (const c of cases('rescan_turn')) {
    const rooms = c.rooms.map((r) => ({roomId: r.room, joined: r.joined, halted: r.halted, pending: r.pending, roster: r.roster, synced: r.synced}));
    const r = siblingRescanTurn({rooms, device: c.device, siblings: c.siblings, excluded: new Map(Object.entries(c.excluded)), state: stateToWeb(c.state), now: c.now});
    const got = {ready: r.ready, enqueue: r.enqueue.map((e) => ({target: e.target, rooms: e.rooms})),
      state: {last: r.state.last, pending: Object.entries(r.state.pending).map(([key, seen]) => ({key, seen}))}};
    assert.deepEqual(got, c.expect, c.name);
  }
});
