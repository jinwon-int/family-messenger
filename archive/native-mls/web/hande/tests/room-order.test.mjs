// 대화 목록 고정 순서 테스트 — 패밀리챗 web/app/tests/room_order.test.js 이식(#480 A). node --test archive/native-mls/web/hande/tests/room-order.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { orderRooms, defaultRoomCompare, parseRoomOrder, moveRoom, readRoomOrder, writeRoomOrder, storageKeyFor, ROOM_ORDER_LIMIT } from '../room-order.js';

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
