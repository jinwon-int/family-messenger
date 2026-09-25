import test from 'node:test';
import assert from 'node:assert/strict';
import { POINTER_HOLD_MAX_MS, SELECTION_HOLD_MAX_MS, renderHold, selectionInRenderedArea } from '../src/render-guard.js';

test('아무것도 잡고 있지 않으면 바로 그린다', () => {
  assert.deepEqual(renderHold({}), { hold: false, retryInMs: 0 });
  assert.deepEqual(renderHold(), { hold: false, retryInMs: 0 });
});

test('마우스를 누르고 있으면 상한까지 미루고, 남은 시간 뒤 다시 판정한다', () => {
  assert.deepEqual(renderHold({ pointerDown: true }), { hold: true, retryInMs: POINTER_HOLD_MAX_MS });
  assert.deepEqual(renderHold({ pointerDown: true, heldMs: 4_000 }), { hold: true, retryInMs: POINTER_HOLD_MAX_MS - 4_000 });
  assert.equal(renderHold({ pointerDown: true, heldMs: POINTER_HOLD_MAX_MS }).hold, false);
});

test('선택해 둔 글자는 더 짧은 상한까지만 미룬다 — 새 메시지가 끝없이 막히지 않게', () => {
  assert.deepEqual(renderHold({ selectionActive: true }), { hold: true, retryInMs: SELECTION_HOLD_MAX_MS });
  assert.equal(renderHold({ selectionActive: true, heldMs: SELECTION_HOLD_MAX_MS + 1 }).hold, false);
  assert.ok(SELECTION_HOLD_MAX_MS < POINTER_HOLD_MAX_MS);
  // 드래그 중(포인터)이 선택보다 우선한다.
  assert.equal(renderHold({ pointerDown: true, selectionActive: true, heldMs: SELECTION_HOLD_MAX_MS + 1 }).hold, true);
});

test('잘못된 heldMs는 0으로 본다', () => {
  assert.equal(renderHold({ pointerDown: true, heldMs: Number.NaN }).retryInMs, POINTER_HOLD_MAX_MS);
  assert.equal(renderHold({ pointerDown: true, heldMs: -5 }).retryInMs, POINTER_HOLD_MAX_MS);
});

const element = (inside) => ({ nodeType: 1, closest: (selector) => (inside && selector.includes('.timeline') ? {} : null) });
const textIn = (parent) => ({ nodeType: 3, parentElement: parent });

test('선택이 타임라인·목록 안에 걸려 있을 때만 보호한다', () => {
  const inTimeline = textIn(element(true));
  const outside = textIn(element(false));
  assert.equal(selectionInRenderedArea(null), false);
  assert.equal(selectionInRenderedArea({ isCollapsed: true, rangeCount: 1, anchorNode: inTimeline, focusNode: inTimeline }), false);
  assert.equal(selectionInRenderedArea({ isCollapsed: false, rangeCount: 0, anchorNode: inTimeline, focusNode: inTimeline }), false);
  assert.equal(selectionInRenderedArea({ isCollapsed: false, rangeCount: 1, anchorNode: inTimeline, focusNode: inTimeline }), true);
  assert.equal(selectionInRenderedArea({ isCollapsed: false, rangeCount: 1, anchorNode: outside, focusNode: inTimeline }), true);
  assert.equal(selectionInRenderedArea({ isCollapsed: false, rangeCount: 1, anchorNode: outside, focusNode: outside }), false);
});
