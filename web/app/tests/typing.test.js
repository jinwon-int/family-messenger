import test from 'node:test';
import assert from 'node:assert/strict';
import {
  TYPING_IDLE_MS,
  TYPING_MAX_AGE_MS,
  TYPING_MAX_MS,
  TYPING_REFRESH_MS,
  TYPING_TIMEOUT_MS,
  applyTypingEvent,
  createTypingSender,
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

// --- 보내기(createTypingSender) — 오너 결정 2026-09-30: 분명히 쓰고 있으면 "입력중.."이 끊기지 않아야 한다 ---

test('타이핑 상수: 서버 유지 창 30초·재알림 20초는 그대로, 유휴 15초, 상한 3분', () => {
  assert.equal(TYPING_TIMEOUT_MS, 30_000);
  assert.equal(TYPING_REFRESH_MS, 20_000);
  assert.equal(TYPING_IDLE_MS, 15_000);
  assert.equal(TYPING_MAX_MS, 180_000);
  assert.ok(TYPING_REFRESH_MS < TYPING_TIMEOUT_MS, '재알림은 서버 만료 전에 와야 한다');
  assert.ok(TYPING_IDLE_MS < TYPING_MAX_MS);
});

const ROOM = '!r:example.com';

/**
 * 가짜 시계(setTimeout·Date) 위에서 전송기를 만든다. 보낸 알림은 calls에 [typing, 시각(초)]로 쌓인다.
 * tick은 1초씩 나눠 진행한다 — node:test 모의 타이머는 한 번의 tick 안에서 Date.now()를 끝 시각으로
 * 옮긴 뒤 콜백을 돌리고, 콜백이 새로 건 타이머는 그 tick에서 돌리지 않으므로 keep-alive 연쇄가 어긋난다.
 */
function senderFixture(t, { focused = true, visible = true, ...opts } = {}) {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
  const env = { focused, visible };
  const calls = [];
  const sender = createTypingSender({
    send: (roomId, typing, timeoutMs) => {
      calls.push({ roomId, typing, timeoutMs, at: Date.now() / 1000 });
    },
    isFocused: () => env.focused,
    isVisible: () => env.visible,
    ...opts,
  });
  const tick = (ms) => {
    for (let left = ms; left > 0; left -= 1_000) t.mock.timers.tick(Math.min(1_000, left));
  };
  return { sender, calls, env, tick };
}

test('sender: 첫 키 입력에 typing=true를 서버 유지 창과 함께 보내고, 그 뒤 키 입력은 재알림 주기 전엔 다시 보내지 않는다', (t) => {
  const { sender, calls, tick } = senderFixture(t);
  sender.activity(ROOM, true);
  assert.deepEqual(calls, [{ roomId: ROOM, typing: true, timeoutMs: TYPING_TIMEOUT_MS, at: 0 }]);
  assert.equal(sender.activeRoomId, ROOM);
  tick(5_000);
  sender.activity(ROOM, true);
  tick(5_000);
  sender.activity(ROOM, true);
  assert.equal(calls.length, 1, '20초 안의 키 입력은 서버를 다시 두드리지 않는다');
});

test('sender: 키 입력 없이도 포커스·표시·글 있음이면 20초마다 keep-alive 재알림한다(6초 유휴로 꺼지지 않는다)', (t) => {
  const { sender, calls, tick } = senderFixture(t);
  sender.activity(ROOM, true);
  tick(TYPING_IDLE_MS + 1_000); // 예전 6초 유휴·새 15초 점검을 지나도 켜져 있다
  assert.equal(calls.length, 1);
  assert.equal(sender.activeRoomId, ROOM);
  tick(TYPING_REFRESH_MS - TYPING_IDLE_MS - 1_000); // t = 20s
  assert.deepEqual(calls.map((c) => [c.typing, c.at]), [[true, 0], [true, 20]]);
  tick(TYPING_REFRESH_MS * 2); // t = 60s
  assert.deepEqual(calls.map((c) => [c.typing, c.at]), [[true, 0], [true, 20], [true, 40], [true, 60]]);
  assert.ok(calls.every((c) => c.typing && c.timeoutMs === TYPING_TIMEOUT_MS && c.roomId === ROOM));
});

test('sender: 키 입력이 재알림을 일으키면 keep-alive 주기는 그 시점에서 다시 센다', (t) => {
  const { sender, calls, tick } = senderFixture(t);
  sender.activity(ROOM, true); // t=0 → 보냄
  tick(20_000); // t=20 keep-alive
  tick(5_000);
  sender.activity(ROOM, true); // t=25: 마지막 전송 20에서 5초 — 보내지 않음
  assert.deepEqual(calls.map((c) => c.at), [0, 20]);
  tick(15_000); // t=40 keep-alive(20+20)
  assert.deepEqual(calls.map((c) => c.at), [0, 20, 40]);
  tick(20_000); // t=60
  sender.activity(ROOM, true); // t=60: 방금 keep-alive가 보냈으니 중복 없음
  assert.deepEqual(calls.map((c) => c.at), [0, 20, 40, 60]);
});

test('sender: 창이 blur되면 즉시 typing=false, 타이머도 모두 멎는다(되찾아도 다음 키 입력까지 켜지 않는다)', (t) => {
  const { sender, calls, env, tick } = senderFixture(t);
  sender.activity(ROOM, true);
  tick(3_000);
  env.focused = false;
  sender.focusChanged(false);
  assert.deepEqual(calls.map((c) => [c.typing, c.at]), [[true, 0], [false, 3]]);
  assert.equal(sender.activeRoomId, null);
  tick(TYPING_MAX_MS);
  assert.equal(calls.length, 2, '꺼진 뒤에는 keep-alive·상한 타이머가 아무것도 보내지 않는다');
  env.focused = true;
  sender.focusChanged(true);
  assert.equal(calls.length, 2, '포커스를 되찾는 것만으로는 켜지 않는다');
  sender.activity(ROOM, true);
  assert.deepEqual(calls.at(-1), { roomId: ROOM, typing: true, timeoutMs: TYPING_TIMEOUT_MS, at: 183 });
});

test('sender: 탭이 hidden이 되면 즉시 typing=false', (t) => {
  const { sender, calls, env, tick } = senderFixture(t);
  sender.activity(ROOM, true);
  tick(1_000);
  env.visible = false;
  sender.visibilityChanged(false);
  assert.deepEqual(calls.map((c) => [c.typing, c.at]), [[true, 0], [false, 1]]);
  tick(TYPING_MAX_MS);
  assert.equal(calls.length, 2);
});

test('sender: blur 이벤트를 놓쳐도 15초 유휴 점검이 포커스 없음·숨김을 보면 끈다(포커스 중이면 끄지 않는다)', (t) => {
  const { sender, calls, env, tick } = senderFixture(t);
  sender.activity(ROOM, true);
  env.focused = false; // 이벤트 없이 포커스만 사라진 상황
  tick(TYPING_IDLE_MS - 1);
  assert.equal(calls.length, 1);
  tick(1);
  assert.deepEqual(calls.map((c) => [c.typing, c.at]), [[true, 0], [false, 15]]);
  // 대조: 포커스·표시 중이면 15초 점검은 아무것도 하지 않는다.
  env.focused = true;
  sender.activity(ROOM, true); // t=15
  tick(TYPING_IDLE_MS);
  assert.equal(calls.length, 3);
  assert.equal(calls.at(-1).typing, true);
  assert.equal(sender.activeRoomId, ROOM);
});

test('sender: 작성창을 비우면 즉시 typing=false', (t) => {
  const { sender, calls, tick } = senderFixture(t);
  sender.activity(ROOM, true);
  tick(2_000);
  sender.activity(ROOM, false);
  assert.deepEqual(calls.map((c) => [c.typing, c.at]), [[true, 0], [false, 2]]);
  assert.equal(sender.activeRoomId, null);
  // 비어 있는데 또 비움 — 중복 false는 없다.
  sender.activity(ROOM, false);
  assert.equal(calls.length, 2);
});

test('sender: 전송 뒤 stop()은 즉시 typing=false, 이미 꺼져 있으면 아무것도 보내지 않는다', (t) => {
  const { sender, calls } = senderFixture(t);
  sender.stop();
  assert.equal(calls.length, 0);
  sender.activity(ROOM, true);
  sender.stop();
  assert.deepEqual(calls.map((c) => c.typing), [true, false]);
  sender.stop();
  assert.equal(calls.length, 2);
});

test('sender: 키 입력 없이 3분(상한)이 지나면 keep-alive를 멈추고 typing=false — 실제 키 입력은 상한을 다시 센다', (t) => {
  const { sender, calls, tick } = senderFixture(t);
  sender.activity(ROOM, true); // t=0
  tick(TYPING_MAX_MS - 1); // t=179.999
  const trues = calls.filter((c) => c.typing).map((c) => c.at);
  assert.deepEqual(trues, [0, 20, 40, 60, 80, 100, 120, 140, 160]);
  assert.equal(calls.filter((c) => !c.typing).length, 0);
  tick(1); // t=180: 상한
  assert.deepEqual(calls.at(-1), { roomId: ROOM, typing: false, timeoutMs: TYPING_TIMEOUT_MS, at: 180 });
  assert.equal(calls.filter((c) => !c.typing).length, 1, 'false는 한 번만');
  assert.equal(sender.activeRoomId, null);
  tick(60_000);
  assert.equal(calls.length, 10, '상한 뒤에는 조용하다');

  // 상한은 마지막 실제 키 입력 기준이다: 170초에 한 글자 치면 350초까지 이어진다.
  calls.length = 0;
  sender.activity(ROOM, true); // t=240 → 보냄
  tick(170_000); // t=410: keep-alive 20초마다
  sender.activity(ROOM, true); // t=410 실제 키 입력 — 상한 리셋(420에 안 꺼진다)
  tick(10_000); // t=420
  assert.equal(calls.filter((c) => !c.typing).length, 0, '원래 상한 시점(240+180)에도 꺼지지 않는다');
  tick(TYPING_MAX_MS - 10_000); // t=590 = 410+180
  assert.equal(calls.filter((c) => !c.typing).length, 1);
  assert.equal(calls.at(-1).at, 590);
});

test('sender: 방 전환 — stop()은 알림을 켜 둔 방에 false를 보내고, 다른 방 활동이 오면 먼저 예전 방을 끈다', (t) => {
  const { sender, calls, tick } = senderFixture(t);
  const OTHER = '!other:example.com';
  sender.activity(ROOM, true);
  tick(1_000);
  sender.stop(); // main.js openRoom/openRooms 경로
  assert.deepEqual(calls.map((c) => [c.roomId, c.typing]), [[ROOM, true], [ROOM, false]]);
  sender.activity(OTHER, true);
  tick(TYPING_REFRESH_MS);
  assert.deepEqual(calls.slice(2).map((c) => [c.roomId, c.typing]), [[OTHER, true], [OTHER, true]], 'keep-alive는 새 방으로만 간다');
  // stop 없이 다른 방 활동이 들어와도 예전 방을 먼저 끈다 — 방 사이로 상태가 새지 않는다.
  sender.activity(ROOM, true);
  assert.deepEqual(calls.slice(4).map((c) => [c.roomId, c.typing]), [[OTHER, false], [ROOM, true]]);
  assert.equal(sender.activeRoomId, ROOM);
});

test('sender: reset()은 서버에 보내지 않고 상태·타이머만 비운다(로그아웃)', (t) => {
  const { sender, calls, tick } = senderFixture(t);
  sender.activity(ROOM, true);
  sender.reset();
  assert.equal(calls.length, 1);
  assert.equal(sender.activeRoomId, null);
  tick(TYPING_MAX_MS);
  assert.equal(calls.length, 1);
});

test('sender: 방 id가 없으면 무시하고, send가 throw/reject해도 onError로만 흘리며 상태는 유지한다', async (t) => {
  const errors = [];
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
  let mode = 'throw';
  const sender = createTypingSender({
    send: () => {
      if (mode === 'throw') throw new Error('sync');
      return Promise.reject(new Error('async'));
    },
    onError: (error) => errors.push(error.message),
  });
  sender.activity('', true);
  sender.activity(null, true);
  assert.equal(errors.length, 0);
  sender.activity(ROOM, true);
  assert.deepEqual(errors, ['sync']);
  assert.equal(sender.activeRoomId, ROOM, '전송 실패는 표시 기능일 뿐 — 상태는 그대로');
  mode = 'reject';
  sender.stop();
  await Promise.resolve();
  await Promise.resolve();
  assert.deepEqual(errors, ['sync', 'async']);
});
