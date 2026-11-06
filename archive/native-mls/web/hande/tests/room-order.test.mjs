// 대화 목록 고정 순서 테스트 — 패밀리챗 web/app/tests/room_order.test.js 이식(#480 A). node --test archive/native-mls/web/hande/tests/room-order.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  orderRooms, defaultRoomCompare, parseRoomOrder, moveRoom, readRoomOrder, writeRoomOrder, storageKeyFor, ROOM_ORDER_LIMIT,
  parseServerOrder, shouldAdopt, shouldSeed, adoptServerOrder, uploadOrder, createRoomOrderSync, ROOM_ORDER_SYNC_LIMIT, ROOM_ORDER_PULL_INTERVAL_MS,
} from '../room-order.js';

const room = (roomId, order, name = roomId, ts = 0) => ({ roomId, order, name, lastTs: ts });

test('orderRooms: 저장된 순서가 없으면 참여한 순서(order) — 메시지 시각은 보지 않는다', () => {
  const rooms = [room('c', 2, '다', 9_000), room('a', 0, '가', 1), room('b', 1, '나', 5_000)];
  assert.deepEqual(orderRooms(rooms, []).map((r) => r.roomId), ['a', 'b', 'c']);
  assert.deepEqual(orderRooms(rooms, null).map((r) => r.roomId), ['a', 'b', 'c']);
});

test('orderRooms: 새 메시지가 와도 순서가 그대로다(최근 활동순이 아니다)', () => {
  const rooms = [room('a', 0, '가', 1), room('b', 1, '나', 999_999)];
  assert.deepEqual(orderRooms(rooms, []).map((r) => r.roomId), ['a', 'b']);
});

test('orderRooms: 저장된 순서를 따르고, 거기 없는 방(새로 참여한 방)은 기본 순서로 뒤에 붙는다', () => {
  const rooms = [room('a', 0), room('b', 1), room('c', 2), room('d', 3)];
  assert.deepEqual(orderRooms(rooms, ['c', 'a', 'zzz']).map((r) => r.roomId), ['c', 'a', 'b', 'd']);
});

test('defaultRoomCompare: 참여 순서가 같으면 이름(ko) → 방 ID 로 결정해 기기마다 순서가 같다', () => {
  assert.ok(defaultRoomCompare(room('x', 1, '가'), room('y', 1, '나')) < 0);
  assert.ok(defaultRoomCompare(room('b', 1, '같음'), room('a', 1, '같음')) > 0);
  assert.ok(defaultRoomCompare(room('b', 0, '나'), room('a', 1, '가')) < 0, '참여 순서가 이름보다 먼저');
  assert.ok(defaultRoomCompare(room('q', undefined), room('p', 3)) > 0, '순서가 없으면 뒤로');
});

test('parseRoomOrder: 형식이 틀리면 빈 배열, 문자열이 아닌 값·중복·빈 문자열은 버린다, 상한을 넘지 않는다', () => {
  assert.deepEqual(parseRoomOrder(null), []);
  assert.deepEqual(parseRoomOrder('not json'), []);
  assert.deepEqual(parseRoomOrder({ rooms: 'a' }), []);
  assert.deepEqual(parseRoomOrder(['a', 1, '', 'a', 'b']), ['a', 'b']);
  assert.deepEqual(parseRoomOrder(JSON.stringify({ rooms: ['b', 'a'] })), ['b', 'a']);
  const many = Array.from({ length: ROOM_ORDER_LIMIT + 5 }, (_, i) => `r${i}`);
  assert.equal(parseRoomOrder(many).length, ROOM_ORDER_LIMIT);
});

test('moveRoom: 위·아래·끝으로 옮기고, 지금 안 보이는 저장된 방은 뒤에 보존한다', () => {
  assert.deepEqual(moveRoom(['a', 'b', 'c'], 'c', 0), ['c', 'a', 'b']);
  assert.deepEqual(moveRoom(['a', 'b', 'c'], 'a', 99), ['b', 'c', 'a']);
  assert.deepEqual(moveRoom(['a', 'b', 'c'], 'b', 2, ['hidden', 'a', 'b', 'c']), ['a', 'c', 'b', 'hidden']);
});

test('moveRoom: 없는 방·같은 자리·숫자가 아닌 위치면 null', () => {
  assert.equal(moveRoom(['a', 'b'], 'zzz', 0), null);
  assert.equal(moveRoom(['a', 'b'], 'a', 0), null);
  assert.equal(moveRoom(['a', 'b'], 'a', Number.NaN), null);
});

test('read/writeRoomOrder: 이 기기 localStorage 키에 저장하고, 깨진 값은 빈 순서로 읽는다', () => {
  const store = new Map();
  const storage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, v) };
  assert.deepEqual(readRoomOrder(storage, 'owner-web-1'), []);
  assert.equal(writeRoomOrder(storage, 'owner-web-1', ['b', 'a', 'a']), true);
  assert.equal(store.get(storageKeyFor('owner-web-1')), '["b","a"]');
  assert.deepEqual(readRoomOrder(storage, 'owner-web-1'), ['b', 'a']);
  store.set(storageKeyFor('owner-web-1'), '{broken');
  assert.deepEqual(readRoomOrder(storage, 'owner-web-1'), []);
  const throwing = { getItem: () => { throw new Error('quota'); }, setItem: () => { throw new Error('quota'); } };
  assert.deepEqual(readRoomOrder(throwing, 'x'), []);
  assert.equal(writeRoomOrder(throwing, 'x', ['a']), false);
});

// ---- room-order v1 릴레이 동기화(#715) ----

test('parseServerOrder: 200·409 본문 → {rooms, revision, updatedAt}, 형식이 틀리면 null', () => {
  assert.deepEqual(parseServerOrder({ rooms: ['b', 'a', 'a'], revision: 3, updated_at: 1700 }), { rooms: ['b', 'a'], revision: 3, updatedAt: 1700 });
  assert.deepEqual(parseServerOrder({ error: 'revision_conflict', rooms: [], revision: 0, updated_at: 0 }), { rooms: [], revision: 0, updatedAt: 0 });
  assert.equal(parseServerOrder(null), null);
  assert.equal(parseServerOrder({ rooms: ['a'] }), null, 'revision 없음');
  assert.equal(parseServerOrder({ rooms: ['a'], revision: -1 }), null);
  assert.equal(parseServerOrder({ rooms: ['a'], revision: 1.5 }), null);
  assert.equal(parseServerOrder({ rooms: 'a', revision: 1 }), null);
  assert.equal(parseServerOrder({ error: 'not_found' }), null);
});

test('shouldAdopt/shouldSeed: revision>0 이면 채택, revision 0 이고 로컬 순서가 있을 때만 시드', () => {
  assert.equal(shouldAdopt({ rooms: [], revision: 1 }), true, '빈 순서라도 저장된 적 있으면 채택');
  assert.equal(shouldAdopt({ rooms: ['a'], revision: 0 }), false);
  assert.equal(shouldAdopt(null), false);
  assert.equal(shouldSeed({ rooms: [], revision: 0 }, ['a']), true);
  assert.equal(shouldSeed({ rooms: [], revision: 0 }, []), false, '로컬 순서 없음 → 시드 안 함(기본 순서)');
  assert.equal(shouldSeed({ rooms: [], revision: 0 }, ['bad id!']), false, '올릴 수 있는 ID 가 없음');
  assert.equal(shouldSeed({ rooms: ['a'], revision: 2 }, ['a']), false);
  assert.equal(shouldSeed(null, ['a']), false);
});

test('adoptServerOrder: 서버 순서로 덮어쓴다(정리된 배열), 쓸 수 없는 값이면 null', () => {
  assert.deepEqual(adoptServerOrder({ rooms: ['c', 'a', 'c'], revision: 4 }), ['c', 'a']);
  assert.deepEqual(adoptServerOrder({ rooms: [], revision: 2 }), []);
  assert.equal(adoptServerOrder(null), null);
  assert.equal(adoptServerOrder({ rooms: ['a'] }), null);
});

test('uploadOrder: 릴레이 식별자 형식만, 중복 없이, 앞에서부터 64개', () => {
  assert.deepEqual(uploadOrder(['family', 'bad id', 'a_b-1', 'family', 'x'.repeat(65), 'Up']), ['family', 'a_b-1', 'Up']);
  const many = Array.from({ length: ROOM_ORDER_SYNC_LIMIT + 10 }, (_, i) => `r${i}`);
  assert.deepEqual(uploadOrder(many), many.slice(0, ROOM_ORDER_SYNC_LIMIT));
  assert.deepEqual(uploadOrder(null), []);
});

/** 가짜 릴레이: 서버 상태(rooms, revision)와 계약대로의 GET/PUT, 호출 기록. mode 로 404·네트워크 오류를 흉내 낸다. */
function fakeRelay({ rooms = [], revision = 0 } = {}) {
  const server = { rooms: [...rooms], revision, updated_at: revision ? 1000 : 0, mode: 'ok' };
  const calls = [];
  const fail = () => { const e = new Error('네트워크 오류'); e.network = true; throw e; };
  const transport = {
    async get() {
      calls.push(['GET']);
      if (server.mode === 'network') fail();
      if (server.mode === '404') return { status: 404, body: { error: 'not_found' } };
      return { status: 200, body: { rooms: [...server.rooms], revision: server.revision, updated_at: server.updated_at } };
    },
    async put(rooms, base) {
      calls.push(['PUT', [...rooms], base]);
      if (server.mode === 'network') fail();
      if (server.mode === '404') return { status: 404, body: { error: 'not_found' } };
      if (base !== server.revision) return { status: 409, body: { error: 'revision_conflict', rooms: [...server.rooms], revision: server.revision, updated_at: server.updated_at } };
      server.rooms = [...rooms]; server.revision += 1; server.updated_at += 1;
      return { status: 200, body: { rooms: [...server.rooms], revision: server.revision, updated_at: server.updated_at } };
    },
  };
  return { server, calls, transport };
}

/** 가짜 앱: 로컬 순서(app.roomOrder 자리), 다시 그린 횟수, 가짜 시계. */
function harness(relayOpts, local = []) {
  const relay = fakeRelay(relayOpts);
  const app = { order: [...local], renders: 0, clock: 1_000_000, logs: [] };
  const sync = createRoomOrderSync({
    transport: relay.transport,
    getLocal: () => app.order,
    setLocal: (order) => { app.order = order; },
    onChange: () => { app.renders += 1; },
    log: (line) => app.logs.push(line),
    now: () => app.clock,
  });
  return { relay, app, sync };
}

test('sync: 서버에 저장된 적 없고(revision 0) 로컬 순서가 있으면 base 0 으로 시드한다', async () => {
  const { relay, app, sync } = harness({}, ['b', 'a']);
  assert.equal(await sync.pull(), 'seeded');
  assert.deepEqual(relay.calls, [['GET'], ['PUT', ['b', 'a'], 0]]);
  assert.deepEqual(relay.server.rooms, ['b', 'a']);
  assert.equal(sync.state.revision, 1);
  assert.equal(app.renders, 0, '로컬 순서 그대로 — 다시 그릴 필요 없음');
});

test('sync: revision 0 이고 로컬 순서도 없으면 아무것도 올리지 않는다', async () => {
  const { relay, sync } = harness({}, []);
  assert.equal(await sync.pull(), 'empty');
  assert.deepEqual(relay.calls, [['GET']]);
  assert.equal(sync.state.revision, 0);
});

test('sync: revision>0 이면 서버 순서를 채택해 로컬을 덮어쓰고 다시 그린다', async () => {
  const { relay, app, sync } = harness({ rooms: ['c', 'a'], revision: 5 }, ['a', 'b', 'c']);
  assert.equal(await sync.pull(), 'adopted');
  assert.deepEqual(app.order, ['c', 'a']);
  assert.equal(app.renders, 1);
  assert.equal(sync.state.revision, 5);
  assert.deepEqual(relay.calls, [['GET']], '채택만 — PUT 없음');
  // 표시 규칙(규칙 3): 서버 순서의 방 먼저, 거기 없는 방은 기본 순서로 뒤에.
  const rooms = [room('a', 0), room('b', 1), room('c', 2)];
  assert.deepEqual(orderRooms(rooms, app.order).map((r) => r.roomId), ['c', 'a', 'b']);
});

test('sync: 시드하려는데 다른 기기가 먼저 시드했으면(409) 서버 것을 채택한다', async () => {
  const { relay, app, sync } = harness({}, ['b', 'a']);
  const get = relay.transport.get;
  // GET 이 revision 0 을 본 직후 다른 기기(아이폰)가 먼저 시드한다.
  relay.transport.get = async () => { const r = await get(); relay.server.rooms = ['a', 'z']; relay.server.revision = 1; return r; };
  assert.equal(await sync.pull(), 'adopted');
  assert.deepEqual(relay.calls, [['GET'], ['PUT', ['b', 'a'], 0]]);
  assert.deepEqual(app.order, ['a', 'z']);
  assert.equal(app.renders, 1);
  assert.equal(sync.state.revision, 1);
  assert.deepEqual(relay.server.rooms, ['a', 'z'], '서버는 먼저 온 시드를 지킨다');
});

test('sync: 사용자가 옮기면 PUT base=<마지막 revision>, 성공하면 revision 을 따라간다', async () => {
  const { relay, app, sync } = harness({ rooms: ['a', 'b'], revision: 2 }, ['a', 'b']);
  await sync.pull();
  app.order = ['b', 'a'];
  assert.equal(await sync.changed(), 'saved');
  assert.deepEqual(relay.calls.at(-1), ['PUT', ['b', 'a'], 2]);
  assert.equal(sync.state.revision, 3);
  assert.equal(sync.state.dirty, false);
  assert.deepEqual(relay.server.rooms, ['b', 'a']);
});

test('sync: 옮긴 사이 다른 기기가 바꿨으면(409) 서버 순서를 채택하고 다시 그린다', async () => {
  const { relay, app, sync } = harness({ rooms: ['a', 'b', 'c'], revision: 2 }, []);
  await sync.pull();
  const rendersBefore = app.renders;
  relay.server.rooms = ['c', 'b', 'a']; relay.server.revision = 3;   // 아이폰에서 바꿈
  app.order = ['b', 'a', 'c'];                                       // 웹에서 옮김(아직 revision 2 기준)
  assert.equal(await sync.changed(), 'adopted');
  assert.deepEqual(relay.calls.at(-1), ['PUT', ['b', 'a', 'c'], 2]);
  assert.deepEqual(app.order, ['c', 'b', 'a']);
  assert.equal(app.renders, rendersBefore + 1);
  assert.equal(sync.state.revision, 3);
  assert.equal(sync.state.dirty, false);
});

test('sync: 404(옛 릴레이)면 이 세션 동안 끈다 — 다시 묻지도 올리지도 않는다', async () => {
  const { relay, app, sync } = harness({}, ['b', 'a']);
  relay.server.mode = '404';
  assert.equal(await sync.pull(), 'disabled');
  app.clock += ROOM_ORDER_PULL_INTERVAL_MS * 10;
  assert.equal(await sync.pull(), 'disabled');
  assert.equal(await sync.pull({ force: true }), 'disabled');
  app.order = ['a', 'b'];
  assert.equal(await sync.changed(), 'disabled');
  assert.deepEqual(relay.calls, [['GET']], 'GET 한 번 뒤로는 네트워크 없음');
  assert.deepEqual(app.order, ['a', 'b'], '로컬 순서는 그대로 쓴다');
  assert.equal(sync.state.disabled, true);
});

test('sync: PUT 이 404 여도 끈다', async () => {
  const { relay, sync } = harness({}, ['a']);
  const get = relay.transport.get;
  relay.transport.get = async () => { const r = await get(); relay.server.mode = '404'; return r; };
  assert.equal(await sync.pull(), 'disabled');
  assert.equal(sync.state.disabled, true);
});

test('sync: GET 은 최소 60초 간격 — 그 안의 목록 새로고침·탭 복귀는 건너뛴다', async () => {
  const { relay, app, sync } = harness({ rooms: ['a'], revision: 1 }, []);
  assert.equal(await sync.pull(), 'adopted');
  app.clock += 8_000;
  assert.equal(await sync.pull(), 'skipped');
  app.clock += ROOM_ORDER_PULL_INTERVAL_MS - 8_001;
  assert.equal(await sync.pull(), 'skipped');
  app.clock += 1;
  assert.equal(await sync.pull(), 'adopted');
  assert.deepEqual(relay.calls, [['GET'], ['GET']]);
});

test('sync: 네트워크 오류는 다음 주기에 다시 — 못 올린 이동은 같은 revision 이면 다음 GET 뒤에 올린다', async () => {
  const { relay, app, sync } = harness({ rooms: ['a', 'b'], revision: 2 }, []);
  await sync.pull();
  relay.server.mode = 'network';
  app.order = ['b', 'a'];
  assert.equal(await sync.changed(), 'error');
  assert.equal(sync.state.dirty, true);
  app.clock += ROOM_ORDER_PULL_INTERVAL_MS;
  assert.equal(await sync.pull(), 'error', 'GET 도 실패 — 끄지 않는다');
  assert.equal(sync.state.disabled, false);
  relay.server.mode = 'ok';
  app.clock += ROOM_ORDER_PULL_INTERVAL_MS;
  assert.equal(await sync.pull(), 'saved', '서버가 그새 안 바뀌었으니(revision 2) 덮어쓰지 않고 이 기기 이동을 올린다');
  assert.deepEqual(relay.calls.at(-1), ['PUT', ['b', 'a'], 2]);
  assert.deepEqual(app.order, ['b', 'a']);
  assert.deepEqual(relay.server.rooms, ['b', 'a']);
});

test('sync: 못 올린 이동이 있어도 서버 revision 이 바뀌었으면 서버 것을 채택한다(충돌)', async () => {
  const { relay, app, sync } = harness({ rooms: ['a', 'b'], revision: 2 }, []);
  await sync.pull();
  relay.server.mode = 'network';
  app.order = ['b', 'a'];
  await sync.changed();
  relay.server.mode = 'ok'; relay.server.rooms = ['x', 'a', 'b']; relay.server.revision = 4;
  app.clock += ROOM_ORDER_PULL_INTERVAL_MS;
  assert.equal(await sync.pull(), 'adopted');
  assert.deepEqual(app.order, ['x', 'a', 'b']);
  assert.equal(sync.state.dirty, false);
});

test('sync: PUT 이 오가는 사이 또 옮겨도 마지막 순서가 올라간다(요청은 한 번에 하나씩)', async () => {
  const { relay, app, sync } = harness({ rooms: ['a', 'b', 'c'], revision: 1 }, []);
  await sync.pull();
  app.order = ['b', 'a', 'c'];
  const first = sync.changed();
  app.order = ['c', 'b', 'a'];
  const second = sync.changed();
  await Promise.all([first, second]);
  assert.deepEqual(relay.server.rooms, ['c', 'b', 'a']);
  assert.equal(sync.state.dirty, false);
  assert.ok(relay.calls.filter((c) => c[0] === 'PUT').every((c, i, all) => i === 0 || c[2] > all[i - 1][2]), 'base 가 순서대로 올라간다 — 409 없음');
});

test('sync: 4xx 거절(bad_identifier 등)은 같은 내용을 되풀이해 올리지 않는다, 5xx 는 다음 주기에 다시', async () => {
  const { relay, app, sync } = harness({ rooms: ['a'], revision: 1 }, []);
  await sync.pull();
  relay.transport.put = async () => ({ status: 400, body: { error: 'bad_identifier' } });
  app.order = ['a', 'b'];
  assert.equal(await sync.changed(), 'error');
  assert.equal(sync.state.dirty, false);
  relay.transport.put = async () => ({ status: 503, body: { error: 'unavailable' } });
  app.order = ['b', 'a'];
  assert.equal(await sync.changed(), 'error');
  assert.equal(sync.state.dirty, true);
});
