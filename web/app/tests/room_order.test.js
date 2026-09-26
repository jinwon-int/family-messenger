import test from 'node:test';
import assert from 'node:assert/strict';
import { ROOM_ORDER_LIMIT, defaultRoomCompare, moveRoom, orderRooms, parseRoomOrder } from '../src/room-order.js';

const room = (roomId, kind, displayName, ts = null) => ({ roomId, kind, displayName, lastMessage: ts == null ? null : { ts } });
const ids = (rooms) => rooms.map((r) => r.roomId);

test('orderRooms: 저장된 순서가 없으면 가족방 → 개인방 → 다른 방, 같은 종류는 이름순 — 메시지 시각은 보지 않는다', () => {
  const rooms = [
    room('!p2', 'private', '엄마', 900),
    room('!o', 'other', '테스트방', 999),
    room('!f', 'family', '우리 가족', 1),
    room('!p1', 'private', '누나', 5),
  ];
  assert.deepEqual(ids(orderRooms(rooms, [])), ['!f', '!p1', '!p2', '!o']);
  assert.deepEqual(ids(orderRooms(rooms, null)), ['!f', '!p1', '!p2', '!o']);
  assert.deepEqual(ids(rooms), ['!p2', '!o', '!f', '!p1'], '입력은 바꾸지 않는다');
});

test('orderRooms: 새 메시지가 와도 순서가 그대로다(최근 활동순이 아니다)', () => {
  const before = [room('!a', 'family', '가족', 100), room('!b', 'private', '엄마', 50)];
  const after = [room('!a', 'family', '가족', 100), room('!b', 'private', '엄마', 5_000)];
  assert.deepEqual(ids(orderRooms(before, ['!a', '!b'])), ids(orderRooms(after, ['!a', '!b'])));
  assert.deepEqual(ids(orderRooms(after, [])), ['!a', '!b']);
});

test('orderRooms: 저장된 순서를 따르고, 거기 없는 방(새로 참여한 방)은 기본 순서로 뒤에 붙는다', () => {
  const rooms = [room('!f', 'family', '가족'), room('!p', 'private', '엄마'), room('!n2', 'private', '형'), room('!n1', 'family', '친척')];
  assert.deepEqual(ids(orderRooms(rooms, ['!p', '!f'])), ['!p', '!f', '!n1', '!n2']);
  assert.deepEqual(ids(orderRooms(rooms, ['!gone', '!f', '!p'])), ['!f', '!p', '!n1', '!n2'], '나간 방 ID는 무시한다');
});

test('defaultRoomCompare: 이름이 같으면 방 ID로 결정해 기기마다 순서가 같다', () => {
  const a = room('!a', 'private', '엄마');
  const b = room('!b', 'private', '엄마');
  assert.ok(defaultRoomCompare(a, b) < 0);
  assert.ok(defaultRoomCompare(b, a) > 0);
  assert.ok(defaultRoomCompare(room('!z', 'weird', '가'), room('!y', 'other', '나')) < 0, '모르는 종류는 다른 방으로 본다');
});

test('parseRoomOrder: 형식이 틀리면 빈 배열, 문자열이 아닌 값·중복·빈 문자열은 버린다, 상한을 넘지 않는다', () => {
  assert.deepEqual(parseRoomOrder(undefined), []);
  assert.deepEqual(parseRoomOrder({ rooms: 'x' }), []);
  assert.deepEqual(parseRoomOrder({ rooms: ['!a', 3, '', '!b', '!a', null] }), ['!a', '!b']);
  const many = Array.from({ length: ROOM_ORDER_LIMIT + 20 }, (_, i) => `!r${i}`);
  assert.equal(parseRoomOrder({ rooms: many }).length, ROOM_ORDER_LIMIT);
});

test('moveRoom: 위·아래·끝으로 옮기고, 지금 안 보이는 저장된 방은 뒤에 보존한다', () => {
  const visible = ['!a', '!b', '!c', '!d'];
  assert.deepEqual(moveRoom(visible, '!c', 1), ['!a', '!c', '!b', '!d']);
  assert.deepEqual(moveRoom(visible, '!a', 3), ['!b', '!c', '!d', '!a']);
  assert.deepEqual(moveRoom(visible, '!d', -5), ['!d', '!a', '!b', '!c'], '범위 밖은 끝으로 맞춘다');
  assert.deepEqual(moveRoom(visible, '!b', 2, ['!b', '!hidden', '!a']), ['!a', '!c', '!b', '!d', '!hidden']);
  assert.deepEqual(visible, ['!a', '!b', '!c', '!d'], '입력은 바꾸지 않는다');
});

test('moveRoom: 없는 방·같은 자리·숫자가 아닌 위치면 null', () => {
  assert.equal(moveRoom(['!a', '!b'], '!x', 0), null);
  assert.equal(moveRoom(['!a', '!b'], '!a', 0), null);
  assert.equal(moveRoom(['!a', '!b'], '!a', Number.NaN), null);
});
