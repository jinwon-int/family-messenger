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

test('터치 탭으로 방에 들어가도 바로 작성창에 커서가 있다; Home 뒤 Enter도 같다', async (t) => {
  const { window, document, buttons, key } = await app(t);
  buttons()[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }));
  assert.equal(document.activeElement.tagName, 'TEXTAREA', '방에 들어가면 따로 누르지 않아도 작성창');
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

test('2분할에서 Page Up/Down은 오른쪽 대화를 열고 바로 작성창에 커서, 작성창에서 다시 누르면 다음 방이다', async (t) => {
  const { document, key } = await app(t, { split: true });
  const screen = () => document.querySelector('.room-screen')?.dataset.roomId;
  const input = () => document.querySelector('.composer textarea');
  key('PageDown');
  assert.equal(document.querySelector('main.shell').dataset.view, 'room');
  assert.equal(screen(), '!a:example.test');
  assert.ok(document.activeElement === input(), '방을 열면 Enter 없이도 작성창에 커서');
  key('PageDown');
  assert.equal(screen(), '!b:example.test');
  assert.ok(document.activeElement === input());
  input().value = '작성 중인 초안';
  key('PageDown');
  assert.equal(document.querySelector('main.shell').dataset.view, 'room');
  assert.equal(screen(), '!c:example.test');
  assert.ok(document.activeElement === input(), '넘긴 방에서도 작성창에 커서');
  assert.equal(input().value, '', '다른 방 초안이 따라오지 않는다');
  key('PageUp');
  assert.equal(screen(), '!b:example.test');
  assert.equal(document.activeElement.value, '작성 중인 초안', '방 전환은 초안을 버리지 않는다');
});

test('휴대폰 세로(단일 pane) 방 화면에서 Page Up/Down은 목록 순서대로 대화 상대를 바꾼다', async (t) => {
  const { window, document, buttons, key, reorder } = await app(t);
  const screen = () => document.querySelector('.room-screen')?.dataset.roomId;
  const view = () => document.querySelector('main.shell').dataset.view;
  // 터치 탭으로 a를 연다 — 바로 작성창에 커서.
  buttons()[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }));
  assert.equal(view(), 'room');
  assert.equal(screen(), '!a:example.test');
  assert.equal(document.activeElement.tagName, 'TEXTAREA');
  assert.equal(key('PageUp').defaultPrevented, true, '첫 방에서 Page Up은 화면 스크롤 대신 제자리');
  assert.equal(screen(), '!a:example.test');
  key('PageDown');
  assert.equal(view(), 'room', '목록으로 돌아가지 않고 방 화면 그대로');
  assert.equal(screen(), '!b:example.test');
  const inputB = document.querySelector('.composer textarea');
  assert.ok(document.activeElement === inputB, '넘긴 방에서도 바로 작성창');
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

test('하이브리드 기기의 터치 탭·Esc 뒤 대화 내용에서 방을 넘겨도 작성창에 커서', async (t) => {
  const { window, document, buttons, key } = await app(t, { finePointer: true });
  buttons()[0].dispatchEvent(new window.PointerEvent('click', { bubbles: true, detail: 1, pointerType: 'touch' }));
  assert.equal(document.activeElement.tagName, 'TEXTAREA');
  key('Escape');
  assert.ok(document.activeElement === document.querySelector('.room-screen .timeline'));
  key('PageDown');
  assert.equal(document.querySelector('.room-screen')?.dataset.roomId, '!b:example.test');
  assert.equal(document.activeElement.tagName, 'TEXTAREA', '대화 내용에서 넘겨도 새 방은 작성창');
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

test('작성창 End도 대화 내용으로 포커스를 옮기고, Shift+End는 편집 그대로 둔다', async (t) => {
  const { document, key } = await app(t);
  key('PageDown'); key('Enter');
  const input = document.activeElement;
  assert.equal(input.tagName, 'TEXTAREA');
  input.value = '쓰던 글';
  const list = document.querySelector('.room-screen .timeline');
  assert.equal(key('End', { shiftKey: true }).defaultPrevented, false, 'Shift+End는 텍스트 선택 그대로');
  assert.equal(key('End', { ctrlKey: true }).defaultPrevented, false, 'Ctrl+End는 글 끝으로 그대로');
  assert.ok(document.activeElement === input, '수정키 End는 작성창에 남는다');
  assert.equal(key('End').defaultPrevented, true);
  assert.ok(document.activeElement === list, 'End는 대화 내용으로 포커스');
  assert.equal(document.querySelector('main.shell').dataset.view, 'room', 'End는 방을 닫지 않는다');
  assert.equal(key('End').defaultPrevented, false, '대화 내용 End는 브라우저 기본(맨 아래 스크롤)');
  key('Enter');
  assert.ok(document.activeElement === input, 'Enter는 작성창');
  assert.equal(input.value, '쓰던 글', 'End는 초안을 버리지 않는다');
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

function latestMessage(body) {
  return {
    getType: () => 'm.room.message',
    getRoomId: () => '!a:example.test',
    getId: () => '$caret',
    getSender: () => '@other:example.test',
    getContent: () => ({ body, msgtype: 'm.text' }),
    getTs: () => Date.now(),
    sender: { name: '상대' },
  };
}

test('대화 내용에서 Esc 한 번 더 = 캐럿 모드: 기존 단축키를 뺏지 않고, 편집은 막고, Esc·Enter로 빠진다 (#284)', async (t) => {
  const { window, document, key } = await app(t, { liveEvents: { '!a:example.test': [latestMessage('복사할 대화 내용')] } });
  key('PageDown'); key('Enter');
  const input = document.activeElement;
  assert.equal(input.tagName, 'TEXTAREA');
  input.value = '쓰던 글';
  const list = document.querySelector('.room-screen .timeline');
  const scrolls = [];
  list.scrollBy = (options) => scrolls.push(options.top);
  key('End');
  assert.ok(document.activeElement === list, 'End는 대화 내용(스크롤 모드)');
  assert.equal(list.hasAttribute('contenteditable'), false, '스크롤 모드는 편집 가능 상태가 아니다');

  assert.equal(key('Escape').defaultPrevented, true);
  assert.equal(list.getAttribute('contenteditable'), 'true', 'Esc 한 번 더 = 캐럿 모드');
  assert.equal(list.getAttribute('inputmode'), 'none', '가상 키보드를 띄우지 않는다');
  assert.equal(list.getAttribute('spellcheck'), 'false');
  assert.equal(list.dataset.caret, 'on');
  assert.ok(document.activeElement === list);
  const selection = document.getSelection();
  assert.equal(selection.anchorNode?.nodeValue, '복사할 대화 내용', '보이는 마지막 말풍선 본문 시작에 캐럿');
  assert.equal(selection.anchorOffset, 0);

  for (const [value, options] of [['ArrowUp'], ['ArrowDown'], ['ArrowLeft', { shiftKey: true }], ['Home'], ['End', { shiftKey: true }], ['PageDown'], ['PageUp', { shiftKey: true }]]) {
    assert.equal(key(value, options).defaultPrevented, false, `${value}는 브라우저 기본(캐럿 이동·선택)`);
  }
  assert.deepEqual(scrolls, [], '캐럿 모드 ↑/↓는 60px 스크롤로 가로채지 않는다');
  assert.equal(document.querySelector('main.shell').dataset.view, 'room', 'Home이 목록으로 가지 않는다');
  assert.equal(document.querySelector('.room-screen')?.dataset.roomId, '!a:example.test', 'Page Up/Down이 방을 넘기지 않는다');
  assert.ok(document.activeElement === list);

  const before = list.innerHTML;
  for (const type of ['beforeinput', 'paste', 'cut', 'drop', 'dragover']) {
    const event = new window.Event(type, { bubbles: true, cancelable: true });
    list.querySelector('.body').dispatchEvent(event);
    assert.equal(event.defaultPrevented, true, `${type}는 막는다(읽기 전용)`);
  }
  assert.equal(list.innerHTML, before);

  assert.equal(key('Escape').defaultPrevented, true);
  assert.equal(list.hasAttribute('contenteditable'), false, 'Esc는 스크롤 모드로 복귀');
  assert.equal(list.hasAttribute('inputmode'), false);
  assert.equal(list.dataset.caret, undefined);
  assert.ok(document.activeElement === list, '포커스는 대화 내용에 남는다');
  key('ArrowUp');
  assert.deepEqual(scrolls, [-60], '스크롤 모드 ↑는 다시 스크롤');
  const blocked = new window.Event('paste', { bubbles: true, cancelable: true });
  list.dispatchEvent(blocked);
  assert.equal(blocked.defaultPrevented, false, '캐럿 모드를 끄면 막던 리스너도 걷힌다');

  key('Escape');
  assert.equal(list.dataset.caret, 'on');
  key('Enter');
  assert.ok(document.activeElement === input, '캐럿 모드 Enter는 작성창');
  assert.equal(list.hasAttribute('contenteditable'), false, '작성창으로 가면 캐럿 모드 해제');
  assert.equal(input.value, '쓰던 글', '초안은 그대로');
});

test('캐럿 모드는 포커스가 대화 내용을 벗어나거나 IME 조합이 시작되면 풀린다 (#284)', async (t) => {
  const { window, document, key } = await app(t, { liveEvents: { '!a:example.test': [latestMessage('본문')] } });
  key('PageDown'); key('Enter');
  const input = document.activeElement;
  const list = document.querySelector('.room-screen .timeline');
  key('End'); key('Escape');
  assert.equal(list.dataset.caret, 'on');
  input.focus();
  assert.equal(list.hasAttribute('contenteditable'), false, '다른 곳으로 포커스가 가면 해제');

  key('Escape'); key('Escape');
  assert.ok(document.activeElement === list);
  assert.equal(list.dataset.caret, 'on');
  const blur = list.blur.bind(list);
  let blurred = 0;
  list.blur = () => { blurred++; blur(); };
  list.dispatchEvent(new window.Event('compositionstart', { bubbles: true }));
  assert.equal(list.hasAttribute('contenteditable'), false, 'IME 조합은 취소가 안 되므로 시작 즉시 해제');
  assert.equal(blurred, 0, '크롬은 핸들러 뒤에 조합을 만든다 — 빼는 것은 다음 태스크');
  await new Promise((resolve) => window.setTimeout(resolve, 10));
  assert.equal(blurred, 1, '포커스를 한 번 빼서 브라우저가 조합을 끝내게 한다(남은 조합이 Esc·Enter를 먹는 회귀)');
  assert.ok(document.activeElement === list, '스크롤 모드로 남는다');
  assert.equal(key('Escape').defaultPrevented, true, '해제 뒤 Esc가 다시 듣는다');
  assert.equal(list.dataset.caret, 'on');
  key('Enter');
  assert.ok(document.activeElement === input, '해제 뒤 Enter도 작성창');

  // 브라우저에 조합이 남아 keydown이 isComposing으로 와도, 편집할 수 없는 대화 내용에서는 Esc·Enter가 듣는다.
  key('Escape');
  assert.ok(document.activeElement === list);
  assert.equal(key('Escape', { isComposing: true }).defaultPrevented, true, '조합 중 표시가 남은 Esc도 캐럿 모드로');
  assert.equal(list.dataset.caret, 'on');
  assert.equal(key('Escape', { isComposing: true }).defaultPrevented, false, '캐럿 모드(편집 가능)에서는 조합 키를 뺏지 않는다');
  assert.equal(list.dataset.caret, 'on');
  key('Escape');
  assert.equal(list.dataset.caret, undefined);
  key('Enter', { isComposing: true });
  assert.ok(document.activeElement === input, '조합 중 표시가 남은 Enter도 작성창');
  assert.equal(key('Escape', { isComposing: true }).defaultPrevented, false, '작성창의 조합 Esc는 그대로(조합 취소)');
  assert.ok(document.activeElement === input);
});
