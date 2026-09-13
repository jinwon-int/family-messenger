import test from 'node:test';
import assert from 'node:assert/strict';
import { ROOM_KINDS, classifyRoom, roomDisplayName } from '../src/rooms.js';

test('다이렉트 표시가 있는 방은 개인방이다', () => {
  assert.equal(classifyRoom({ isDirect: true, memberCount: 2 }), ROOM_KINDS.private);
  assert.equal(classifyRoom({ isDirect: true, memberCount: 9 }), ROOM_KINDS.private);
});

test('셋 이상이 모인 방은 가족방이다', () => {
  assert.equal(classifyRoom({ isDirect: false, memberCount: 3 }), ROOM_KINDS.family);
  assert.equal(classifyRoom({ isDirect: false, memberCount: 7 }), ROOM_KINDS.family);
});

test('두 명 방(다이렉트 표시 없음)은 개인방으로 본다', () => {
  assert.equal(classifyRoom({ isDirect: false, memberCount: 2 }), ROOM_KINDS.private);
});

test('판단할 수 없는 방은 other로 보수적으로 분류한다', () => {
  assert.equal(classifyRoom({}), ROOM_KINDS.other);
  assert.equal(classifyRoom(null), ROOM_KINDS.other);
  assert.equal(classifyRoom({ isDirect: false, memberCount: 0 }), ROOM_KINDS.other);
});

test('표시 이름은 이름 → 다른 멤버 이름 순으로 정한다', () => {
  assert.equal(roomDisplayName({ name: '우리 가족' }), '우리 가족');
  assert.equal(roomDisplayName({ name: '  여행 준비방  ' }), '여행 준비방');
  assert.equal(roomDisplayName({ otherMemberNames: ['민서', '하준'] }), '민서·하준');
  assert.equal(roomDisplayName({ name: '', otherMemberNames: [] }), '');
  assert.equal(roomDisplayName(null), '');
});
