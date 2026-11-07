// 작성창 IME 조합 중 End·Esc·Home 회귀 검사.
// 2026-11-07 오너(안드로이드 한데 웹): 「End 키나 Esc 키 같은 단축키가 잘 안 된다」 — 안드로이드 키보드는 쓰는 동안
// 거의 늘 조합 중(isComposing / keyCode 229)이라 onRoomKeys 의 조합 가드가 작성창 End·Esc·Home 을 모두 버렸다.
// DOM 없이 실제 installShortcuts 의 keydown 처리기를 돌린다(shortcuts-switch.test.mjs 와 같은 방식).
import test from 'node:test';
import assert from 'node:assert/strict';
import { installShortcuts } from '../shortcuts.js';

function fakeRoom({ sheet = false, withTimeline = true } = {}) {
  const handlers = [];
  const doc = { body: { tagName: 'BODY' }, activeElement: null, addEventListener: (_type, fn) => handlers.push(fn), removeEventListener() {} };
  doc.activeElement = doc.body;
  const timeline = { tagName: 'UL', isContentEditable: false, classList: { contains: (name) => name === 'timeline' }, focus() { doc.activeElement = timeline; } };
  const input = {
    tagName: 'TEXTAREA', disabled: false, blurs: 0,
    focus() { doc.activeElement = input; },
    blur() { input.blurs += 1; if (doc.activeElement === input) doc.activeElement = doc.body; },
  };
  const shell = { dataset: { view: 'room' } };
  const state = { current: 'r1', sheet, backs: 0 };
  const root = {
    ownerDocument: doc,
    querySelector: (selector) => {
      if (selector === 'main.shell') return shell;
      if (selector === 'dialog[open]') return state.sheet ? {} : null;
      if (selector === '.room-screen .timeline') return withTimeline ? timeline : null;
      if (selector === '.room-screen form.composer textarea[name=body]') return input;
      return null;
    },
    querySelectorAll: () => [],
  };
  const queue = [];
  installShortcuts(root, {
    document: doc,
    matchMedia: () => ({ matches: false }),
    openRoom: (roomId) => { state.current = roomId; },
    openRooms: () => { state.backs += 1; state.current = null; },
    currentRoomId: () => state.current,
    defer: (fn) => queue.push(fn),
  });
  const key = (value, { code = value, composing = true, ...mods } = {}) => {
    const event = {
      key: value, code, target: doc.activeElement, defaultPrevented: false,
      isComposing: composing, keyCode: composing ? 229 : 0,
      shiftKey: false, ctrlKey: false, altKey: false, metaKey: false, ...mods,
      preventDefault() { this.defaultPrevented = true; }, stopPropagation() {},
    };
    for (const handler of handlers) handler(event);
    return event;
  };
  const flush = () => { while (queue.length) queue.shift()(); };
  input.focus();
  return { doc, timeline, input, state, key, flush, queue };
}

test('조합 중 작성창 End → (다음 태스크에) 대화 내용으로', () => {
  const room = fakeRoom();
  const event = room.key('End');
  assert.equal(event.defaultPrevented, true);
  assert.equal(room.doc.activeElement, room.input, 'keydown 안에서는 조합을 건드리지 않는다');
  room.flush();
  assert.equal(room.doc.activeElement, room.timeline);
});

test('조합 중 작성창 Esc — 안드로이드 크롬 형태(key=Unidentified, code=Escape)도 대화 내용으로', () => {
  const room = fakeRoom();
  const event = room.key('Unidentified', { code: 'Escape' });
  assert.equal(event.defaultPrevented, true, '처리 안 된 Esc 가 안드로이드 「뒤로」로 바뀌지 않게');
  room.flush();
  assert.equal(room.doc.activeElement, room.timeline);
});

test('조합 중 작성창 Home(PC 윈도 IME 형태 key=Process) → 조합 확정(blur) 후 목록으로', () => {
  const room = fakeRoom();
  room.key('Process', { code: 'Home' });
  room.flush();
  assert.equal(room.input.blurs, 1);
  assert.equal(room.state.backs, 1);
});

test('조합 중 한글 자모·Enter·Shift+End 는 그대로 둔다', () => {
  const room = fakeRoom();
  for (const [key, opts] of [['Process', { code: 'KeyR' }], ['Enter', {}], ['End', { shiftKey: true }], ['Unidentified', { code: '' }]]) {
    const event = room.key(key, opts);
    assert.equal(event.defaultPrevented, false, `${key} ${opts.code ?? ''}`);
  }
  assert.equal(room.queue.length, 0);
  assert.equal(room.doc.activeElement, room.input);
});

test('미뤄 둔 사이 방을 바꿨거나 포커스가 옮겨갔으면 아무것도 하지 않는다', () => {
  const moved = fakeRoom();
  moved.key('End');
  moved.state.current = 'r2';
  moved.flush();
  assert.equal(moved.doc.activeElement, moved.input);

  const tapped = fakeRoom();
  tapped.key('Home');
  tapped.doc.activeElement = tapped.doc.body;
  tapped.flush();
  assert.equal(tapped.state.backs, 0);
});

test('시트(dialog[open])가 떠 있으면 조합 중 End·Esc·Home 을 가로채지 않는다', () => {
  const room = fakeRoom({ sheet: true });
  for (const key of ['End', 'Escape', 'Home']) assert.equal(room.key(key).defaultPrevented, false, key);
  assert.equal(room.queue.length, 0);
});

test('조합이 아닐 때 작성창 End·Esc·Home 은 예전처럼 바로 동작한다', () => {
  const room = fakeRoom();
  room.key('End', { composing: false });
  assert.equal(room.doc.activeElement, room.timeline);
  room.input.focus();
  room.key('Escape', { composing: false });
  assert.equal(room.doc.activeElement, room.timeline);
  room.input.focus();
  room.key('Home', { composing: false });
  assert.equal(room.state.backs, 1);
  assert.equal(room.queue.length, 0, '미루지 않는다');
});
