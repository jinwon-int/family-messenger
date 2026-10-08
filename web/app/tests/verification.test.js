import test from 'node:test';
import assert from 'node:assert/strict';
import { EMOJI_KO, VerificationState, emojiLabel, transition } from '../src/verification.js';

const EMOJIS = [
  ['🐶', 'dog'],
  ['🐱', 'cat'],
  ['🦊', 'fox'],
];

test('기기 검증 흐름은 요청 → 이모지 대조 → 상대 확인 → 완료 순서다', () => {
  let state = transition({ state: VerificationState.idle }, { type: 'request' });
  assert.equal(state.state, VerificationState.requested);
  state = transition(state, { type: 'ready', emojis: EMOJIS });
  assert.equal(state.state, VerificationState.ready);
  assert.deepEqual(state.emojis, EMOJIS);
  state = transition(state, { type: 'accept' });
  assert.equal(state.state, VerificationState.waiting);
  state = transition(state, { type: 'confirm' });
  assert.equal(state.state, VerificationState.matched);
});

test('이모지 없이는 대조 단계로 갈 수 없다', () => {
  const requested = { state: VerificationState.requested };
  assert.equal(transition(requested, { type: 'ready', emojis: [] }).state, VerificationState.requested);
  assert.equal(transition(requested, { type: 'ready' }).state, VerificationState.requested);
});

test('어긋나면 검증은 실패로 끝난다', () => {
  const ready = transition({ state: VerificationState.requested }, { type: 'ready', emojis: EMOJIS });
  assert.equal(transition(ready, { type: 'mismatch' }).state, VerificationState.mismatched);
  const waiting = transition(ready, { type: 'accept' });
  assert.equal(transition(waiting, { type: 'mismatch' }).state, VerificationState.mismatched);
});

test('종료 상태에서는 더 이상 전이하지 않는다', () => {
  for (const terminal of [VerificationState.matched, VerificationState.mismatched, VerificationState.cancelled]) {
    const frozen = { state: terminal };
    assert.equal(transition(frozen, { type: 'cancel' }).state, terminal);
    assert.equal(transition(frozen, { type: 'ready', emojis: EMOJIS }).state, terminal);
  }
});

test('취소는 진행 중 어느 단계에서든 가능하다', () => {
  assert.equal(transition({ state: VerificationState.idle }, { type: 'cancel' }).state, VerificationState.cancelled);
  assert.equal(transition({ state: VerificationState.ready, emojis: EMOJIS }, { type: 'cancel' }).state, VerificationState.cancelled);
});

test('SDK 이모지([이모지, 이름] 배열)를 한국어로 보여준다', () => {
  assert.equal(emojiLabel(['🐶', 'dog']), '강아지');
  assert.equal(emojiLabel(['🐱', 'cat']), '고양이');
});

test('객체 형태와 한국어 외 이모지도 안전하게 처리한다', () => {
  assert.equal(emojiLabel({ emoji: '🔥', name: 'fire' }), '불');
  // 매핑에 없는 이모지는 SDK가 준 영어 이름으로 표시한다 (빈 칸 없음).
  assert.equal(emojiLabel(['🦊', 'fox']), 'fox');
  assert.equal(emojiLabel(['🧿']), '🧿');
  assert.equal(emojiLabel({}), '');
  assert.equal(emojiLabel(null), '');
});

test('한국어 라벨표는 실제 문자와 대응한다', () => {
  for (const [glyph, label] of Object.entries(EMOJI_KO)) {
    assert.ok(typeof glyph === 'string' && glyph.length > 0);
    assert.ok(/[\uAC00-\uD7A3]/.test(label), `non-Korean label for ${glyph}: ${label}`);
    assert.equal(emojiLabel([glyph, 'english']), label);
  }
});

// #331 — 시트가 떠 있을 때 들어온 검증 요청을 버리지 않는다.
import { IncomingAction, classifyIncoming, createIncomingHolder, isRequestPending } from '../src/verification.js';

const dialogWith = (...classes) => ({ classList: { contains: (name) => classes.includes(name) } });

test('들어온 검증 요청: 시트 없음 → 바로 열고, 메뉴 시트 → 닫고 열고, 다른 시트 → 보관', () => {
  assert.equal(classifyIncoming(null), IncomingAction.open);
  assert.equal(classifyIncoming(undefined), IncomingAction.open);
  assert.equal(classifyIncoming(dialogWith('sheet', 'menu')), IncomingAction.closeMenu);
  assert.equal(classifyIncoming(dialogWith('sheet')), IncomingAction.hold);
  assert.equal(classifyIncoming({}), IncomingAction.hold); // classList 없는 노드도 보관 쪽으로
});

test('보관한 요청은 시트가 닫힐 때 꺼내 열고, 그 사이 만료·취소된 요청은 버린다', () => {
  const holder = createIncomingHolder();
  assert.equal(holder.has(), false);
  assert.equal(holder.take(), null);

  const live = { pending: true, phase: 2 };
  holder.hold(live);
  assert.equal(holder.has(), true);
  assert.equal(holder.take(), live);
  assert.equal(holder.has(), false, 'take 는 한 번만 꺼낸다');

  const cancelled = { pending: false, phase: 5 };
  holder.hold(cancelled);
  assert.equal(holder.take(), null, '취소된 요청은 열지 않는다');

  const first = { pending: true, phase: 2, id: 1 };
  const second = { pending: true, phase: 2, id: 2 };
  holder.hold(first);
  holder.hold(second);
  assert.equal(holder.take(), second, '나중 요청이 먼저 것을 덮는다');

  holder.hold(live);
  holder.clear();
  assert.equal(holder.take(), null);
});

test('isRequestPending: pending=false 또는 Cancelled(5)/Done(6) 는 끝난 요청, 정보가 없으면 살아 있다고 본다', () => {
  assert.equal(isRequestPending(null), false);
  assert.equal(isRequestPending({ pending: false }), false);
  assert.equal(isRequestPending({ phase: 5 }), false);
  assert.equal(isRequestPending({ phase: 6 }), false);
  assert.equal(isRequestPending({ pending: true, phase: 3 }), true);
  assert.equal(isRequestPending({}), true);
});
