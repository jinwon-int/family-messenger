import test from 'node:test';
import assert from 'node:assert/strict';
import { composerKeyAction, viewKeyAction } from '../src/keyboard.js';

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
