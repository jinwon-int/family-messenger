import test from 'node:test';
import assert from 'node:assert/strict';
import { composerKeyAction, viewKeyAction, listArrowMove } from '../src/keyboard.js';

test('작성창 Enter는 전송이다', () => {
  assert.equal(composerKeyAction({ key: 'Enter', shiftKey: false, isComposing: false }), 'send');
});

test('작성창 Shift+Enter는 줄바꿈이다', () => {
  assert.equal(composerKeyAction({ key: 'Enter', shiftKey: true, isComposing: false }), 'newline');
});

test('한글 조합 중 Enter는 무시한다(조합 확정)', () => {
  assert.equal(composerKeyAction({ key: 'Enter', shiftKey: false, isComposing: true }), null);
  assert.equal(composerKeyAction({ key: 'Enter', shiftKey: true, isComposing: true }), 'newline');
});

test('작성창 다른 키는 판정 대상이 아니다', () => {
  assert.equal(composerKeyAction({ key: 'a', shiftKey: false, isComposing: false }), null);
  assert.equal(composerKeyAction({ key: 'Escape', shiftKey: false, isComposing: false }), null);
  assert.equal(composerKeyAction(), null);
});

test('대화형 요소 밖 Enter는 작성창으로 커서를 옮긴다', () => {
  assert.equal(viewKeyAction({ key: 'Enter', target: { tagName: 'BODY' } }), 'focus-composer');
  assert.equal(viewKeyAction({ key: 'Enter', target: {} }), 'focus-composer');
  assert.equal(viewKeyAction({ key: 'Enter' }), 'focus-composer');
});

test('대화형 요소 위 Enter는 뺏지 않는다(버튼 활성화 등 원래 동작)', () => {
  for (const tag of ['INPUT', 'TEXTAREA', 'BUTTON', 'A', 'SELECT', 'LABEL', 'SUMMARY']) {
    assert.equal(viewKeyAction({ key: 'Enter', target: { tagName: tag } }), null);
  }
  assert.equal(viewKeyAction({ key: 'Enter', target: { tagName: 'DIV', isContentEditable: true } }), null);
});

test('Esc는 어디서든 방 목록 뒤로가기다', () => {
  assert.equal(viewKeyAction({ key: 'Escape', target: { tagName: 'BODY' } }), 'back');
  assert.equal(viewKeyAction({ key: 'Escape', target: { tagName: 'TEXTAREA' } }), 'back');
});

test('다른 키는 뷰 판정 대상이 아니다', () => {
  assert.equal(viewKeyAction({ key: 'a', target: { tagName: 'BODY' } }), null);
  assert.equal(viewKeyAction(), null);
});

test('대화목록 ↑/↓: 선택이 없으면 ↓는 첫 항목, ↑는 마지막 항목에서 시작한다', () => {
  assert.equal(listArrowMove({ key: 'ArrowDown', count: 3, currentIndex: -1 }), 0);
  assert.equal(listArrowMove({ key: 'ArrowUp', count: 3, currentIndex: -1 }), 2);
});

test('대화목록 ↑/↓: 한 항목씩 옮기고 끝에서 멈춘다', () => {
  assert.equal(listArrowMove({ key: 'ArrowDown', count: 3, currentIndex: 0 }), 1);
  assert.equal(listArrowMove({ key: 'ArrowDown', count: 3, currentIndex: 2 }), 2, '마지막에서 ↓는 제자리');
  assert.equal(listArrowMove({ key: 'ArrowUp', count: 3, currentIndex: 2 }), 1);
  assert.equal(listArrowMove({ key: 'ArrowUp', count: 3, currentIndex: 0 }), 0, '첫 항목에서 ↑는 제자리');
});

test('대화목록 ↑/↓: 범위를 벗난 현재 위치는 시작점 규칙으로 돌아온다', () => {
  assert.equal(listArrowMove({ key: 'ArrowDown', count: 2, currentIndex: 5 }), 0);
  assert.equal(listArrowMove({ key: 'ArrowUp', count: 2, currentIndex: 5 }), 1);
});

test('대화목록 ↑/↓: 빈 목록이거나 ↑/↓가 아니면 판정하지 않는다', () => {
  assert.equal(listArrowMove({ key: 'ArrowDown', count: 0 }), null);
  assert.equal(listArrowMove({ key: 'ArrowDown', count: -1 }), null);
  assert.equal(listArrowMove({ key: 'Enter', count: 3, currentIndex: 0 }), null);
  assert.equal(listArrowMove({ key: 'a', count: 3, currentIndex: 0 }), null);
  assert.equal(listArrowMove({}), null);
});
