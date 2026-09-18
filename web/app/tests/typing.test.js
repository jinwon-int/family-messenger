import test from 'node:test';
import assert from 'node:assert/strict';
import {
  TYPING_MAX_AGE_MS,
  applyTypingEvent,
  createTypingState,
  pruneTyping,
  typingIndicator,
  typingNames,
} from '../src/typing.js';

const T0 = 1_000_000;

test('applyTypingEvent: 추가→변화 있음, 반복 알림→변화 없음, 해제→변화 있음', () => {
  const state = createTypingState();
  const mom = '@mom:example.com';
  assert.equal(applyTypingEvent(state, { roomId: '!r:x', userId: mom, name: '엄마', typing: true, ts: T0 }), true);
  assert.deepEqual(typingNames(state, '!r:x', { now: T0 }), ['엄마']);
  // 같은 사람의 반복 "입력 중" — 표시 집합은 그대로(타임스탬프만 갱신).
  assert.equal(applyTypingEvent(state, { roomId: '!r:x', userId: mom, name: '엄마', typing: true, ts: T0 + 5_000 }), false);
  assert.deepEqual(typingNames(state, '!r:x', { now: T0 + 5_000 }), ['엄마']);
  assert.equal(applyTypingEvent(state, { roomId: '!r:x', userId: mom, name: '엄마', typing: false, ts: T0 + 6_000 }), true);
  assert.deepEqual(typingNames(state, '!r:x', { now: T0 + 6_000 }), []);
  // 빈 방 Map은 치운다 — 상태가 부풀지 않는다.
  assert.equal(state.has('!r:x'), false);
});

test('applyTypingEvent: 방·사용자 식별자가 없으면 무시한다', () => {
  const state = createTypingState();
  assert.equal(applyTypingEvent(state, { roomId: '', userId: '@a:x', typing: true }), false);
  assert.equal(applyTypingEvent(state, { roomId: '!r:x', userId: null, typing: true }), false);
  assert.equal(state.size, 0);
});

test('typingNames: 나를 제외하고(대소문자 무시), 만료된 항목은 숨긴다', () => {
  const state = createTypingState();
  applyTypingEvent(state, { roomId: '!r:x', userId: '@Mom:Example.com', name: '엄마', typing: true, ts: T0 });
  applyTypingEvent(state, { roomId: '!r:x', userId: '@me:example.com', name: '나', typing: true, ts: T0 });
  applyTypingEvent(state, { roomId: '!r:x', userId: '@dad:example.com', name: '아빠', typing: true, ts: T0 - TYPING_MAX_AGE_MS - 1 });
  assert.deepEqual(typingNames(state, '!r:x', { myUserId: '@me:example.com', now: T0 }), ['엄마']);
  assert.deepEqual(typingNames(state, '!r:x', { myUserId: '@ME:example.com', now: T0 }), ['엄마']);
  assert.deepEqual(typingNames(state, '!r:x', { myUserId: null, now: T0 }), ['엄마', '나']);
  // 다른 방은 영향이 없다.
  assert.deepEqual(typingNames(state, '!other:x', { now: T0 }), []);
});

test('pruneTyping: 만료된 항목을 걷고 영향받은 방 id를 돌려준다', () => {
  const state = createTypingState();
  applyTypingEvent(state, { roomId: '!r1:x', userId: '@mom:x', name: '엄마', typing: true, ts: T0 });
  applyTypingEvent(state, { roomId: '!r2:x', userId: '@dad:x', name: '아빠', typing: true, ts: T0 + 1_000 });
  assert.deepEqual(pruneTyping(state, T0 + TYPING_MAX_AGE_MS + 1), ['!r1:x']);
  // r1은 비어 사라지고 r2는 아직 살아 있다.
  assert.equal(state.has('!r1:x'), false);
  assert.deepEqual(typingNames(state, '!r2:x', { now: T0 + TYPING_MAX_AGE_MS + 1 }), ['아빠']);
  // 아무것도 만료하지 않으면 빈 배열 — 재렌더를 일으키지 않는다.
  assert.deepEqual(pruneTyping(state, T0 + TYPING_MAX_AGE_MS + 1), []);
});

test('typingIndicator: 누군가 입력 중이면 단일 문구, 없으면 빈 문자열', () => {
  assert.equal(typingIndicator([], '입력중..'), '');
  assert.equal(typingIndicator(['엄마'], '입력중..'), '입력중..');
  assert.equal(typingIndicator(['엄마', '아빠'], '입력중..'), '입력중..');
});
