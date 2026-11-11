// #752: 방 열기 동시성 상한(room-open-pool.js) — 순서·상한·실패 격리 + 합성 지연 before/after.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { openRoomsLimited, ROOM_OPEN_CONCURRENCY } from '../room-open-pool.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test('입력 순서대로 시작하고 동시에 limit 개를 넘지 않는다', async () => {
  const started = [];
  let inFlight = 0;
  let peak = 0;
  const delays = [30, 5, 20, 1, 15, 2, 25, 3];
  const result = await openRoomsLimited(delays.map((d, i) => ({ id: `r${i}`, d })), async ({ id, d }) => {
    started.push(id);
    inFlight++; peak = Math.max(peak, inFlight);
    await sleep(d);
    inFlight--;
  }, { limit: 3 });
  assert.deepEqual(started, delays.map((_, i) => `r${i}`));
  assert.equal(peak, 3);
  assert.deepEqual(result, { opened: 8, failed: 0 });
});

test('한 방이 실패해도 나머지는 열리고 onError 로 알린다', async () => {
  const errors = [];
  const opened = [];
  const result = await openRoomsLimited(['a', 'bad', 'c', 'd'], async (id) => {
    await sleep(1);
    if (id === 'bad') throw new Error('boom');
    opened.push(id);
  }, { limit: 2, onError: (id, error) => errors.push(`${id}:${error.message}`) });
  assert.deepEqual(errors, ['bad:boom']);
  assert.deepEqual(opened.sort(), ['a', 'c', 'd']);
  assert.deepEqual(result, { opened: 3, failed: 1 });
});

test('onError 가 던져도 다른 방 열기는 계속된다', async () => {
  const opened = [];
  const result = await openRoomsLimited([1, 2, 3], async (n) => { if (n === 1) throw new Error('x'); opened.push(n); },
    { limit: 1, onError: () => { throw new Error('log failed'); } });
  assert.deepEqual(opened, [2, 3]);
  assert.deepEqual(result, { opened: 2, failed: 1 });
});

test('빈 목록·잘못된 limit — 거부하지 않고 limit 은 1 로 본다', async () => {
  assert.deepEqual(await openRoomsLimited([], async () => { throw new Error('never'); }), { opened: 0, failed: 0 });
  let inFlight = 0; let peak = 0;
  for (const limit of [0, -2, 1.5, NaN, undefined]) {
    peak = 0;
    await openRoomsLimited([1, 2, 3], async () => { inFlight++; peak = Math.max(peak, inFlight); await sleep(1); inFlight--; },
      limit === undefined ? {} : { limit });
    assert.equal(peak, limit === undefined ? 3 : 1, String(limit));
  }
  assert.equal(ROOM_OPEN_CONCURRENCY, 6);
});

test('ensureRoom 처럼 첫 await 전에 Map 에 넣으면 방 순서는 직렬 때와 같다(넓은 화면 첫 방 선택)', async () => {
  const rooms = new Map();
  const ids = ['family', 'bangtong', 'gwakga', 'sogyo', 'nosuk'];
  const finish = { family: 25, bangtong: 1, gwakga: 15, sogyo: 3, nosuk: 8 };
  await openRoomsLimited(ids, async (id) => {
    rooms.set(id, { order: rooms.size });   // app.js ensureRoom: set → await open/activate
    await sleep(finish[id]);
  });
  assert.deepEqual([...rooms.keys()], ids);
  assert.equal([...rooms.keys()][0], 'family');
});

// 합성 측정: 방 21개(2026-11 운영 방 수), 방마다 워커 작업 3번(open_room·members·history_list — 워커는 Promise 큐라
// 전역 직렬) + 릴레이 왕복 1번(sync). 실측 왕복 0.3 s(한국↔순욱 FRA)를 1/10 로 줄여 30 ms, 워커 1번 2 ms.
test('합성 지연: 방 21개 시작이 직렬 대비 크게 줄어든다(before/after)', async (t) => {
  const ROOMS = 21; const RTT = 30; const WORKER_OP = 2;
  async function boot(limit) {
    let queue = Promise.resolve();
    const workerCall = () => (queue = queue.then(() => sleep(WORKER_OP)));
    const t0 = performance.now();
    await openRoomsLimited(Array.from({ length: ROOMS }, (_, i) => `room-${i}`), async () => {
      await workerCall(); await workerCall(); await workerCall();   // open_room · members · history_list
      await sleep(RTT);                                               // GET /events (sync)
    }, { limit });
    return performance.now() - t0;
  }
  const before = await boot(1);
  const after = await boot(ROOM_OPEN_CONCURRENCY);
  t.diagnostic(`rooms=${ROOMS} rtt=${RTT}ms worker_op=${WORKER_OP}ms → before(직렬) ${before.toFixed(0)} ms · after(limit ${ROOM_OPEN_CONCURRENCY}) ${after.toFixed(0)} ms · ratio ${(after / before).toFixed(2)}`);
  // 이론값: 직렬 ≈ 21×(6+30)=756 ms, 병렬 ≈ ceil(21/6)×30 + 워커 합 126 ms 안팎 ≈ 250 ms. 느린 CI 여유를 두고 0.6.
  assert.ok(after < before * 0.6, `after ${after} vs before ${before}`);
});

test('room-open-pool.js 가 build.sh 배포 목록과 SHELL_ASSETS 에 있다', async () => {
  const { SHELL_ASSETS } = await import('../sw-policy.js');
  assert.ok(SHELL_ASSETS.includes('./room-open-pool.js'));
  const build = readFileSync(new URL('../build.sh', import.meta.url), 'utf8');
  assert.match(build, /\sroom-open-pool\.js\s/);
});
