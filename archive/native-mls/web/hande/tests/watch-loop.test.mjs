// #755 2a: 기기 단위 /v2/watch 루프(watch-loop.js) · relay.watch(relay.js) · 방별 간격(room.js setPollInterval).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createWatchLoop, WATCH_WAIT_MS, DEFAULT_POLL_MS, SAFETY_POLL_MS, MIN_GAP_MS, REPROBE_MS } from '../watch-loop.js';
import { createRelay } from '../relay.js';

function harness({ results, rooms = [{ room: 'family', after: 7 }], device = 'owner-web-aaaaaa' }) {
  let t = 1_000_000;
  const calls = [];
  const sleeps = [];
  const changed = [];
  const modes = [];
  const relay = {
    async watch(dev, list, waitMs) {
      calls.push({ dev, list: list.map((r) => ({ ...r })), waitMs });
      const next = results.shift();
      if (next instanceof Error) throw next;
      t += next.spend ?? 0;
      return next.result;
    },
  };
  const loop = createWatchLoop({
    relay, device: () => device, targets: () => rooms,
    onChanged: async (list) => { changed.push(list); },
    onMode: (on) => modes.push(on),
    sleep: async (ms) => { sleeps.push(ms); t += ms; },
    now: () => t,
  });
  return { loop, calls, sleeps, changed, modes, advance: (ms) => { t += ms; } };
}
const ok = (changedRooms = [], spend = 0) => ({ result: { supported: true, changed: changedRooms, errors: {} }, spend });

test('watch 가 되면 바뀐 방만 sync 하고 watch 모드(onMode true)로 알린다', async () => {
  const h = harness({ results: [ok(['family'], 3000), ok([], 25000)] });
  await h.loop.step();
  assert.deepEqual(h.calls[0], { dev: 'owner-web-aaaaaa', list: [{ room: 'family', after: 7 }], waitMs: WATCH_WAIT_MS });
  assert.deepEqual(h.changed, [['family']]);
  assert.deepEqual(h.modes, [true]);
  assert.deepEqual(h.sleeps, [], '3 s 걸렸으면 추가 대기 없음');
  await h.loop.step();
  assert.deepEqual(h.changed, [['family']], '빈 결과는 sync 없음');
  assert.deepEqual(h.modes, [true], '같은 모드는 다시 알리지 않는다');
});

test('변화가 몰려도 바퀴 사이 최소 간격을 지킨다', async () => {
  const h = harness({ results: [ok(['family'], 50)] });
  await h.loop.step();
  assert.deepEqual(h.sleeps, [MIN_GAP_MS - 50]);
});

test('#424 이전 릴레이(supported=false)면 4초 폴링 모드, REPROBE_MS 동안 watch 를 다시 부르지 않는다', async () => {
  const h = harness({ results: [{ result: { supported: false, changed: [], errors: {} } }, ok([], 25000)] });
  await h.loop.step();
  assert.deepEqual(h.modes, [false]);
  await h.loop.step();
  assert.equal(h.calls.length, 1, '미지원 기간에는 호출 안 함');
  assert.deepEqual(h.sleeps, [DEFAULT_POLL_MS]);
  h.advance(REPROBE_MS);
  await h.loop.step();
  assert.equal(h.calls.length, 2, '재확인');
  assert.deepEqual(h.modes, [false, true]);
});

test('watch 오류면 이번 바퀴는 4초 폴링 모드로 쉬고, 다음 바퀴에 다시 시도한다', async () => {
  const h = harness({ results: [new Error('net'), ok([], 25000)] });
  await h.loop.step();
  assert.deepEqual(h.modes, [false]);
  assert.deepEqual(h.sleeps, [DEFAULT_POLL_MS]);
  await h.loop.step();
  assert.deepEqual(h.modes, [false, true]);
});

test('기기·방이 아직 없으면 watch 를 부르지 않고 4초 쉰다 · 방은 64개까지', async () => {
  const none = harness({ results: [], rooms: [] });
  await none.loop.step();
  assert.equal(none.calls.length, 0);
  assert.deepEqual(none.sleeps, [DEFAULT_POLL_MS]);
  const many = harness({ results: [ok([], 25000)], rooms: Array.from({ length: 70 }, (_, i) => ({ room: `r${i}`, after: 0 })) });
  await many.loop.step();
  assert.equal(many.calls[0].list.length, 64);
});

test('start/stop: stop 하면 루프가 멈춘다', async () => {
  let n = 0;
  const loop = createWatchLoop({
    relay: { watch: async () => { n++; return { supported: true, changed: [], errors: {} }; } },
    device: () => 'd', targets: () => [{ room: 'family', after: 1 }], onChanged: async () => {}, onMode: () => {},
    sleep: async () => { await new Promise((r) => setImmediate(r)); }, now: () => 0,
  });
  loop.start();
  await new Promise((r) => setTimeout(r, 20));
  loop.stop();
  const seen = n;
  await new Promise((r) => setTimeout(r, 20));
  assert.ok(seen > 0);
  assert.ok(n <= seen + 1, 'stop 뒤 최대 한 바퀴');
  assert.equal(loop.running, false);
});

// ---- relay.watch ----

function recordingFetch(status, body) {
  const seen = [];
  const fetch = async (path, init) => {
    seen.push({ path, method: init.method });
    return { status, json: async () => { if (body === undefined) throw new Error('not json'); return body; } };
  };
  return { fetch, seen };
}

test('relay.watch: 질의를 만들고 changed/errors 를 돌려준다', async () => {
  const f = recordingFetch(200, { changed: ['family', 7], errors: { gone: 'room_closed' } });
  const r = await createRelay({ fetch: f.fetch }).watch('owner-web-aaaaaa', [{ room: 'family', after: 12 }, { room: 'gone', after: 0 }], 25000);
  assert.deepEqual(r, { supported: true, changed: ['family'], errors: { gone: 'room_closed' } });
  assert.deepEqual(f.seen, [{ path: '/v2/watch?device=owner-web-aaaaaa&wait=25000&room=family:12&room=gone:0', method: 'GET' }]);
});

test('relay.watch: 봉투 없는 404 = 미지원, 봉투 있는 오류는 throw', async () => {
  assert.deepEqual(await createRelay({ fetch: recordingFetch(404, undefined).fetch }).watch('d', [{ room: 'family', after: 1 }], 1000),
    { supported: false, changed: [], errors: {} });
  await assert.rejects(createRelay({ fetch: recordingFetch(400, { error: 'too_many_rooms' }).fetch }).watch('d', [{ room: 'family', after: 1 }], 1000), /too_many_rooms/);
  await assert.rejects(createRelay({ fetch: recordingFetch(502, undefined).fetch }).watch('d', [{ room: 'family', after: 1 }], 1000), /watch 502/);
});

// ---- 배포 목록 ----

test('watch-loop.js 가 build.sh 배포 목록과 SHELL_ASSETS 에 있다', async () => {
  const { SHELL_ASSETS } = await import('../sw-policy.js');
  assert.ok(SHELL_ASSETS.includes('./watch-loop.js'));
  assert.match(readFileSync(new URL('../build.sh', import.meta.url), 'utf8'), /\swatch-loop\.js\s/);
  assert.ok(SAFETY_POLL_MS > DEFAULT_POLL_MS);
});
