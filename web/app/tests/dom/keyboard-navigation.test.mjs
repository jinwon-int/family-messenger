import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { Window } from 'happy-dom';
import { saveSession } from '../../src/session.js';

// Exercise the real bootstrap, UI and document handlers; only the Matrix transport
// is synthetic. No test accounts, network calls or production session data.
const bundle = await build({
  entryPoints: [new URL('../../src/main.js', import.meta.url).pathname],
  bundle: true, write: false, format: 'iife', platform: 'browser',
  plugins: [{ name: 'synthetic-matrix', setup(builder) {
    builder.onResolve({ filter: /\/matrix\/client\.js$/ }, () => ({ path: 'client', namespace: 'fixture' }));
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
      export const createFamilyClient = async () => window.testClient;
      export const loginWithPassword = async () => { throw new Error('Unexpected login'); };
      export class PlaintextRefusedError extends Error {}
    ` }));
  } }],
});

async function app(t, { finePointer = false, split = false, liveEvents = {} } = {}) {
  const window = new Window({ url: 'https://chat.example.test/' });
  t.after(() => window.happyDOM.abort());
  const { document } = window;
  document.body.innerHTML = '<div id="app"></div>';
  window.fetch = async () => ({ ok: true, json: async () => ({}) });
  const matchMedia = window.matchMedia.bind(window);
  window.matchMedia = (query) => {
    if (query === '(pointer: fine)') return { matches: finePointer };
    if (query === '(min-width: 900px)') return { matches: split };
    if (query === '(orientation: landscape) and (min-width: 640px) and (max-width: 899px)') return { matches: false };
    return matchMedia(query);
  };
  let summaries = ['a', 'b', 'c'].map((id) => ({
    roomId: `!${id}:example.test`, displayName: id, kind: 'private', memberCount: 2, agents: [],
  }));
  let refresh;
  // 목록 순서는 SDK 방 순서가 아니라 저장된 고정 순서(account data)를 따른다.
  let order = [];
  let orderChanged = () => {};
  const sent = [];
  window.testClient = {
    enableEncryption: async () => {}, start() {}, onTimeline() {}, onVerificationRequest() {},
    onRoomAdded(callback) { refresh = callback; },
    onTyping() {}, roomSummaries: () => summaries, inviteSummaries: () => [], canLoadEarlier: () => false,
    roomMemberHandles: () => [], sendText: async (...args) => sent.push(args),
    liveTimelineEvents: (roomId) => liveEvents[roomId] ?? [],
    roomOrder: () => order, onRoomOrderChange(callback) { orderChanged = callback; }, setRoomOrder: async (ids) => { order = ids; },
  };
  saveSession({ homeserverUrl: 'https://matrix.example.test', userId: '@reader:example.test', deviceId: 'TEST', accessToken: 'synthetic' }, {
    persistent: window.localStorage, volatile: window.sessionStorage,
  });
  window.eval(bundle.outputFiles[0].text);
  // Bootstrap awaits configuration, client creation and encryption initialization.
  for (let i = 0; i < 20 && !document.querySelector('.room-item'); i++) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(document.querySelectorAll('.room-item').length, 3);
  const buttons = () => [...document.querySelectorAll('.room-item')];
  const key = (value, options = {}) => {
    const target = document.activeElement;
    const event = new window.KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true, ...options });
    target.dispatchEvent(event);
    // happy-dom does not implement the browser's Enter -> button click default.
    if (value === 'Enter' && target.tagName === 'BUTTON' && !event.defaultPrevented) target.click();
    return event;
  };
  return { window, document, buttons, key, sent, refresh, reorder() {
    // 다른 기기에서 b를 맨 위로 옮긴 것과 같다.
    order = [summaries[1], summaries[0], summaries[2]].map((room) => room.roomId);
    orderChanged(order);
    refresh();
  } };
}

test('Enter opens a room and focuses composer even without a fine pointer; Home restores the same row', async (t) => {
  const { document, buttons, key, sent } = await app(t);
  key('PageDown');
  key('PageDown');
  assert.ok(document.activeElement === buttons()[1]);
  assert.equal(document.querySelector('main.shell').dataset.view, 'list', '단일 pane에서는 Enter 전에 방을 열지 않는다');
  assert.equal(document.querySelector('.room-screen'), null);
  key('Enter');
  const input = document.querySelector('.composer textarea');
  assert.ok(document.activeElement === input, "composer must retain focus");
  assert.equal(sent.length, 0, 'opening Enter must not send a message');
  input.value = '작성 중인 초안';
  key('Home');
  assert.equal(document.querySelector('main.shell').dataset.view, 'list');
  assert.equal(document.activeElement.dataset.roomId, '!b:example.test');
  key('PageDown');
  assert.equal(document.activeElement.dataset.roomId, '!c:example.test');
  key('PageUp');
  key('Enter');
  assert.equal(document.activeElement.value, '작성 중인 초안', 'Home must not discard the draft');
});

test('pointer-selected room returns to its row and follows room identity after list reordering', async (t) => {
  const { window, document, buttons, key, reorder, refresh } = await app(t, { finePointer: true });
  buttons()[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }));
  assert.equal(document.activeElement.tagName, 'TEXTAREA');
  reorder();
  key('Home');
  assert.ok(document.activeElement === buttons()[0]);
  assert.equal(document.activeElement.dataset.roomId, '!b:example.test');
  refresh();
  assert.equal(document.activeElement.dataset.roomId, '!b:example.test', 'list refresh keeps keyboard focus');
  key('PageDown');
  assert.equal(document.activeElement.dataset.roomId, '!a:example.test');
});

test('touch taps do not open a software keyboard; hardware Enter does', async (t) => {
  const { window, document, buttons, key } = await app(t);
  buttons()[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }));
  assert.notEqual(document.activeElement.tagName, 'TEXTAREA');
  key('Home');
  assert.ok(document.activeElement === buttons()[0]);
  key('Enter');
  assert.equal(document.activeElement.tagName, 'TEXTAREA');
});

test('IME and open dialogs retain Home; ordinary composer arrows remain text editing', async (t) => {
  const { window, document, key } = await app(t);
  key('PageDown'); key('Enter');
  const input = document.activeElement;
  key('Home', { isComposing: true });
  assert.ok(document.activeElement === input, "composer must retain focus");
  assert.equal(key('PageDown', { isComposing: true }).defaultPrevented, false, 'IME 조합 중 Page Down은 방을 바꾸지 않는다');
  assert.equal(document.querySelector('.room-screen')?.dataset.roomId, '!a:example.test');
  assert.equal(key('ArrowDown').defaultPrevented, false);
  assert.equal(key('Escape', { isComposing: true }).defaultPrevented, false, 'IME 조합 중 Esc는 조합 취소라 뺏지 않는다');
  assert.ok(document.activeElement === input);
  const dialog = document.createElement('dialog');
  document.getElementById('app').append(dialog);
  dialog.showModal();
  key('Home');
  assert.equal(document.querySelector('main.shell').dataset.view, 'room');
  dialog.close(); dialog.remove(); input.focus();
  key('Home');
  assert.equal(document.querySelector('main.shell').dataset.view, 'list');
});

test('2분할에서 Page Up/Down은 Enter 없이 오른쪽 대화를 열고, Enter는 작성창, 다시 Page Down은 목록 탐색이다', async (t) => {
  const { document, buttons, key } = await app(t, { split: true });
  key('PageDown');
  assert.equal(document.querySelector('main.shell').dataset.view, 'room');
  assert.equal(document.querySelector('.room-screen')?.dataset.roomId, '!a:example.test');
  assert.equal(document.activeElement.dataset.roomId, '!a:example.test');
  assert.notEqual(document.activeElement.tagName, 'TEXTAREA', '미리보기는 작성창에 커서를 두지 않는다');
  key('PageDown');
  assert.equal(document.querySelector('.room-screen')?.dataset.roomId, '!b:example.test');
  assert.equal(document.activeElement.dataset.roomId, '!b:example.test');
  key('Enter');
  const input = document.querySelector('.composer textarea');
  assert.ok(document.activeElement === input, 'Enter는 작성창으로 커서를 옮긴다');
  input.value = '작성 중인 초안';
  key('PageDown');
  assert.equal(document.querySelector('main.shell').dataset.view, 'room', '목록 탐색으로 돌아가도 대화는 그대로');
  assert.equal(document.querySelector('.room-screen')?.dataset.roomId, '!c:example.test');
  assert.equal(document.activeElement.dataset.roomId, '!c:example.test');
  assert.notEqual(document.activeElement.tagName, 'TEXTAREA');
  key('PageUp');
  key('Enter');
  assert.equal(document.activeElement.value, '작성 중인 초안', '미리보기 전환은 초안을 버리지 않는다');
  assert.equal(document.querySelector('.room-screen')?.dataset.roomId, '!b:example.test');
});

test('휴대폰 세로(단일 pane) 방 화면에서 Page Up/Down은 목록 순서대로 대화 상대를 바꾼다', async (t) => {
  const { window, document, buttons, key, reorder } = await app(t);
  const screen = () => document.querySelector('.room-screen')?.dataset.roomId;
  const view = () => document.querySelector('main.shell').dataset.view;
  // 터치 탭으로 a를 연다 — 작성창 커서 없음.
  buttons()[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }));
  assert.equal(view(), 'room');
  assert.equal(screen(), '!a:example.test');
  assert.equal(key('PageUp').defaultPrevented, true, '첫 방에서 Page Up은 화면 스크롤 대신 제자리');
  assert.equal(screen(), '!a:example.test');
  key('PageDown');
  assert.equal(view(), 'room', '목록으로 돌아가지 않고 방 화면 그대로');
  assert.equal(screen(), '!b:example.test');
  assert.notEqual(document.activeElement.tagName, 'TEXTAREA', '작성창 밖에서 넘기면 작성창 커서를 두지 않는다');
  key('Enter');
  const inputB = document.querySelector('.composer textarea');
  assert.ok(document.activeElement === inputB, 'Enter는 작성창');
  inputB.value = 'b에 쓰던 초안';
  key('PageDown');
  assert.equal(screen(), '!c:example.test');
  assert.equal(document.activeElement.tagName, 'TEXTAREA', '작성창에서 넘기면 새 방에서도 작성창에 커서');
  assert.equal(document.activeElement.value, '', '다른 방 초안이 따라오지 않는다');
  key('PageDown');
  assert.equal(screen(), '!c:example.test', '마지막 방에서 Page Down은 제자리');
  key('PageUp');
  assert.equal(screen(), '!b:example.test');
  assert.equal(document.activeElement.value, 'b에 쓰던 초안', '돌아오면 초안이 그대로');
  // 다른 기기에서 순서를 바꾸면(b,a,c) 그 순서를 따른다.
  reorder();
  await new Promise((resolve) => window.setTimeout(resolve, 50)); // 방 추가 갱신은 다음 프레임에 그린다
  key('PageDown');
  assert.equal(screen(), '!a:example.test');
  key('Home');
  assert.equal(view(), 'list');
  assert.equal(document.activeElement.dataset.roomId, '!a:example.test', 'Home은 마지막으로 본 방 행으로 돌아간다');
});

test('hybrid devices use the actual touch pointer instead of the primary fine-pointer setting', async (t) => {
  const { window, document, buttons, key } = await app(t, { finePointer: true });
  buttons()[0].dispatchEvent(new window.PointerEvent('click', { bubbles: true, detail: 1, pointerType: 'touch' }));
  assert.notEqual(document.activeElement.tagName, 'TEXTAREA');
  key('Home'); key('Enter');
  assert.equal(document.activeElement.tagName, 'TEXTAREA', 'hardware keyboard still focuses composer');
});

test('Room.timeline을 놓쳐도 방을 열면 SDK live timeline의 최신 메시지를 그린다', async (t) => {
  const latest = {
    getType: () => 'm.room.message',
    getRoomId: () => '!a:example.test',
    getId: () => '$latest',
    getSender: () => '@other:example.test',
    getContent: () => ({ body: '놓친 최신 메시지', msgtype: 'm.text' }),
    getTs: () => Date.now(),
    sender: { name: '상대' },
  };
  const { window, document, buttons } = await app(t, { liveEvents: { '!a:example.test': [latest] } });
  buttons()[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }));
  assert.match(document.querySelector('.timeline')?.textContent ?? '', /놓친 최신 메시지/);
});

test('작성창 Esc는 대화 내용으로 포커스를 옮기고, ↑/↓로 스크롤하며, Enter는 초안 그대로 작성창으로 돌아간다', async (t) => {
  const { document, key } = await app(t);
  key('PageDown'); key('Enter');
  const input = document.activeElement;
  assert.equal(input.tagName, 'TEXTAREA');
  input.value = '쓰던 글';
  const list = document.querySelector('.room-screen .timeline');
  assert.equal(list.getAttribute('tabindex'), '-1', '탭 순서에는 끼지 않는다');
  assert.equal(key('Escape').defaultPrevented, true);
  assert.ok(document.activeElement === list, 'Esc는 대화 내용으로 포커스');
  assert.equal(document.querySelector('main.shell').dataset.view, 'room', 'Esc는 방을 닫지 않는다');
  const scrolls = [];
  list.scrollBy = (options) => scrolls.push(options.top);
  assert.equal(key('ArrowUp').defaultPrevented, true);
  assert.equal(key('ArrowUp').defaultPrevented, true);
  assert.equal(key('ArrowDown').defaultPrevented, true);
  assert.deepEqual(scrolls, [-60, -60, 60]);
  assert.ok(document.activeElement === list, '스크롤 중에도 포커스 유지');
  key('Enter');
  assert.ok(document.activeElement === input, 'Enter는 작성창');
  assert.equal(input.value, '쓰던 글', 'Esc·스크롤은 초안을 버리지 않는다');
  assert.equal(key('ArrowUp').defaultPrevented, false, '작성창 ↑/↓는 텍스트 편집 그대로');
  key('Escape');
  key('Home');
  assert.equal(document.querySelector('main.shell').dataset.view, 'list', '대화 내용에서 Home은 목록');
});
