// 단일 pane(휴대폰 세로) 방 화면의 Page Up/Down 방 넘기기 기준점 회귀 검사.
// 2026-11-01 오너(안드로이드 크롬): 「어떤 채팅창에서는 Page Up/Down 으로 방이 넘어가는데 어떤 채팅창에서는 안 된다」 —
// 기준점이 목록에서 마지막으로 Page Up/Down 한 방(listFocusRoomId)에 묶여, 방 화면에서 한 번 넘긴 뒤·터치로 연 방에서는
// 「다음 방」이 지금 방과 같아 멈추거나 엉뚱한 방으로 뛰었다. DOM 없이 실제 installShortcuts 의 keydown 처리기를 돌린다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { installShortcuts } from '../shortcuts.js';

function fakeApp(ids) {
  const handlers = [];
  const doc = { body: { tagName: 'BODY' }, activeElement: null, addEventListener: (_type, fn) => handlers.push(fn), removeEventListener() {} };
  doc.activeElement = doc.body;
  const shell = { dataset: { view: 'list' } };
  const pane = { scrollTop: 0 };
  const buttons = ids.map((roomId) => {
    const button = { tagName: 'BUTTON', dataset: { roomId }, closest: () => pane, focus() { doc.activeElement = button; } };
    return button;
  });
  const composer = { tagName: 'TEXTAREA' };
  let current = null;
  const opened = [];
  const root = {
    ownerDocument: doc,
    querySelector: (selector) => (selector === 'main.shell' ? shell : null),
    querySelectorAll: (selector) => (selector === '.pane-list button.room-item' ? buttons : []),
  };
  const open = (roomId) => { current = roomId; shell.dataset.view = 'room'; doc.activeElement = composer; };
  installShortcuts(root, {
    document: doc,
    matchMedia: () => ({ matches: false }), // 휴대폰 세로 = 단일 pane
    openRoom: (roomId) => { opened.push(roomId); open(roomId); },
    openRooms: () => { current = null; shell.dataset.view = 'list'; doc.activeElement = doc.body; },
    currentRoomId: () => current,
    orderEditing: () => false,
  });
  const key = (value) => {
    const event = {
      key: value, target: doc.activeElement, defaultPrevented: false, isComposing: false, keyCode: 0,
      shiftKey: false, ctrlKey: false, altKey: false, metaKey: false,
      preventDefault() { this.defaultPrevented = true; }, stopPropagation() {},
    };
    for (const handler of handlers) handler(event);
    return event;
  };
  return { key, tapOpen: open, opened, get current() { return current; }, get focused() { return doc.activeElement?.dataset?.roomId ?? null; } };
}

const IDS = ['r0', 'r1', 'r2', 'r3', 'r4', 'r5'];

test('방 화면에서 Page Down 을 이어 누르면 다음 방으로 계속 넘어간다(옛 기준점에 멈추지 않는다)', () => {
  const app = fakeApp(IDS);
  app.key('PageDown'); app.key('PageDown');
  assert.equal(app.focused, 'r1', '목록에서 r1 까지 내려왔다');
  app.tapOpen('r1'); // Enter = 그 방 열기
  app.key('PageDown'); assert.equal(app.current, 'r2');
  app.key('PageDown'); assert.equal(app.current, 'r3', '예전에는 여기서 r2 에 멈췄다');
  app.key('PageDown'); assert.equal(app.current, 'r4');
  app.key('PageUp'); assert.equal(app.current, 'r3', '예전에는 옛 기준점(r1) 위인 r0 으로 뛰었다');
});

test('터치로 연 방에서도 그 방 기준으로 넘어간다', () => {
  const app = fakeApp(IDS);
  app.key('PageDown'); app.key('PageDown'); // 목록 키 위치 r1
  app.tapOpen('r4');                        // 그다음 r4 를 손으로 연다
  app.key('PageDown'); assert.equal(app.current, 'r5', '예전에는 r1 기준으로 r2 로 뛰었다');
  app.key('PageUp'); assert.equal(app.current, 'r4');
});

test('첫·마지막 방에서는 제자리 — 다시 열지 않지만 화면 스크롤도 하지 않는다', () => {
  const app = fakeApp(IDS);
  app.tapOpen('r5');
  const event = app.key('PageDown');
  assert.equal(app.current, 'r5');
  assert.deepEqual(app.opened, [], '같은 방을 다시 열지 않는다');
  assert.equal(event.defaultPrevented, true);
  app.tapOpen('r0');
  app.key('PageUp');
  assert.equal(app.current, 'r0');
});

test('방에서 넘긴 뒤 Home 으로 목록에 가면 그 방 다음 행부터 이어진다', () => {
  const app = fakeApp(IDS);
  app.tapOpen('r1');
  app.key('PageDown'); app.key('PageDown');
  assert.equal(app.current, 'r3');
  app.key('Home');
  assert.equal(app.current, null, 'Home = 목록');
  app.key('PageDown');
  assert.equal(app.focused, 'r4', '목록 키 위치가 마지막으로 본 방(r3)을 따라온다');
});
