// 작성창 IME 조합 중 Page Up/Down(방 넘기기) 회귀 검사 — #722(End·Esc·Home) 후속.
// 안드로이드 키보드는 쓰는 동안 거의 늘 조합 중(isComposing / keyCode 229)이라 onListNav 의 조합 가드가
// 작성창에서 누른 Page Up/Down 을 모두 버렸다. DOM 없이 실제 installShortcuts 의 keydown 처리기를 돌린다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { installShortcuts } from '../shortcuts.js';

const IDS = ['r0', 'r1', 'r2', 'r3'];

function fakeApp({ split = false, current = 'r1', sheet = false, ordering = false } = {}) {
  const handlers = [];
  const doc = { body: { tagName: 'BODY' }, activeElement: null, addEventListener: (_type, fn) => handlers.push(fn), removeEventListener() {} };
  doc.activeElement = doc.body;
  const shell = { dataset: { view: current ? 'room' : 'list' } };
  const pane = { scrollTop: 0 };
  const buttons = IDS.map((roomId) => {
    const button = { tagName: 'BUTTON', dataset: { roomId }, closest: () => pane, focus() { doc.activeElement = button; } };
    return button;
  });
  const timeline = { tagName: 'UL', isContentEditable: false, classList: { contains: (name) => name === 'timeline' }, focus() { doc.activeElement = timeline; } };
  const input = {
    tagName: 'TEXTAREA', disabled: false, blurs: 0,
    focus() { doc.activeElement = input; },
    blur() { input.blurs += 1; if (doc.activeElement === input) doc.activeElement = doc.body; },
  };
  const state = { current, sheet, ordering, opened: [], backs: 0 };
  const root = {
    ownerDocument: doc,
    querySelector: (selector) => {
      if (selector === 'main.shell') return shell;
      if (selector === 'dialog[open]') return state.sheet ? {} : null;
      if (selector === '.room-screen .timeline') return state.current ? timeline : null;
      if (selector === '.room-screen form.composer textarea[name=body]') return state.current ? input : null;
      return null;
    },
    querySelectorAll: (selector) => (selector === '.pane-list button.room-item' ? buttons : []),
  };
  const queue = [];
  installShortcuts(root, {
    document: doc,
    matchMedia: () => ({ matches: split }),
    openRoom: (roomId) => { state.opened.push(roomId); state.current = roomId; shell.dataset.view = 'room'; input.focus(); },
    openRooms: () => { state.backs += 1; state.current = null; shell.dataset.view = 'list'; doc.activeElement = doc.body; },
    currentRoomId: () => state.current,
    orderEditing: () => state.ordering,
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
  if (current) input.focus();
  return { doc, input, timeline, state, key, flush, queue };
}

test('단일 pane: 조합 중 작성창 Page Down → (다음 태스크에) 조합 확정 후 다음 방', () => {
  const app = fakeApp();
  const event = app.key('PageDown');
  assert.equal(event.defaultPrevented, true);
  assert.equal(app.state.current, 'r1', 'keydown 안에서는 조합을 건드리지 않는다');
  assert.equal(app.input.blurs, 0);
  app.flush();
  assert.equal(app.input.blurs, 1, '포커스를 빼서 조합을 확정한다(쓰던 글자는 초안으로 보존)');
  assert.deepEqual(app.state.opened, ['r2']);
});

test('조합 중 Page Up — 안드로이드 크롬 형태(key=Unidentified, code=PageUp)·PC 윈도 IME(key=Process)도 넘긴다', () => {
  const app = fakeApp({ current: 'r2' });
  app.key('Unidentified', { code: 'PageUp' });
  app.flush();
  assert.equal(app.state.current, 'r1');
  app.key('Process', { code: 'PageUp' });
  app.flush();
  assert.equal(app.state.current, 'r0');
});

test('2분할: 조합 중 작성창 Page Down 도 오른쪽에 다음 방을 연다', () => {
  const app = fakeApp({ split: true });
  app.key('PageDown');
  app.flush();
  assert.deepEqual(app.state.opened, ['r2']);
});

test('첫·마지막 방에서는 제자리 — 포커스를 빼지 않아 조합이 그대로 이어진다', () => {
  const app = fakeApp({ current: 'r3' });
  const event = app.key('PageDown');
  assert.equal(event.defaultPrevented, true, '화면 스크롤로도 쓰지 않는다(조합 아닐 때와 같게)');
  app.flush();
  assert.equal(app.input.blurs, 0);
  assert.equal(app.doc.activeElement, app.input);
  assert.deepEqual(app.state.opened, []);
});

test('조합 중 Shift+Page Down·글자·알 수 없는 키는 건드리지 않는다', () => {
  const app = fakeApp();
  for (const [key, opts] of [['PageDown', { shiftKey: true }], ['PageUp', { ctrlKey: true }], ['Process', { code: 'KeyR' }], ['Unidentified', { code: '' }]]) {
    assert.equal(app.key(key, opts).defaultPrevented, false, `${key} ${opts.code ?? ''}`);
  }
  assert.equal(app.queue.length, 0);
  assert.equal(app.doc.activeElement, app.input);
});

test('시트(dialog[open])·순서 편집 중에는 조합 중 Page Up/Down 을 가로채지 않는다', () => {
  for (const opts of [{ sheet: true }, { ordering: true }]) {
    const app = fakeApp(opts);
    assert.equal(app.key('PageDown').defaultPrevented, false, JSON.stringify(opts));
    assert.equal(app.queue.length, 0);
  }
});

test('작성창이 아닌 곳(대화 내용)의 조합 중 Page Up/Down 은 가로채지 않는다', () => {
  const app = fakeApp();
  app.timeline.focus();
  assert.equal(app.key('PageDown').defaultPrevented, false);
  assert.equal(app.queue.length, 0);
});

test('미뤄 둔 사이 방을 바꿨거나 포커스가 옮겨갔거나 시트가 열렸으면 아무것도 하지 않는다', () => {
  const moved = fakeApp();
  moved.key('PageDown');
  moved.state.current = 'r3';
  moved.flush();
  assert.deepEqual(moved.state.opened, []);

  const tapped = fakeApp();
  tapped.key('PageDown');
  tapped.doc.activeElement = tapped.doc.body;
  tapped.flush();
  assert.deepEqual(tapped.state.opened, []);

  const sheet = fakeApp();
  sheet.key('PageDown');
  sheet.state.sheet = true;
  sheet.flush();
  assert.deepEqual(sheet.state.opened, []);
  assert.equal(sheet.input.blurs, 0);
});

test('조합이 아닐 때 작성창 Page Up/Down 은 예전처럼 바로 넘긴다(미루지 않음)', () => {
  const app = fakeApp();
  app.key('PageDown', { composing: false });
  assert.equal(app.state.current, 'r2');
  assert.equal(app.queue.length, 0);
  assert.equal(app.input.blurs, 0);
});
