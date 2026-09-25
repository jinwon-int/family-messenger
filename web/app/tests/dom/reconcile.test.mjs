// #194 — 같은 방 재렌더가 DOM을 통째 교체해 PC 크롬에서 드래그·선택한 글자가 사라지고
// (Chromium 실측: 선택 "" / 드래그 앵커가 대화 맨 위로 튐), 호버가 깜빡이고, 목록 포커스가
// body로 떨어지고, 보관함 iframe이 매번 다시 로드됐다. 크롬은 선택이 걸린 노드가 떨어져 나갈 때
// 선택을 버리므로, 여기서는 "바뀌지 않은 노드는 그대로 붙어 있다"를 검사한다.
// DOM 노드는 assert.equal로 비교하지 않는다 — 실패 메시지가 happy-dom 객체를 diff하다 힙이 터진다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Window } from 'happy-dom';

const window = new Window({ url: 'https://chat.example.test/' });
for (const key of ['HTMLElement', 'Node', 'Event', 'CSS', 'FormData']) globalThis[key] = window[key] ?? globalThis[key];
globalThis.window = window;
globalThis.document = window.document;
if (!globalThis.CSS) globalThis.CSS = window.CSS;

const ui = await import('../../src/ui.js');

const same = (a, b, message) => assert.ok(a != null && a === b, message);
const root = () => {
  document.body.innerHTML = '<div id="app"></div>';
  return document.getElementById('app');
};
const now = Date.now();
const rooms = (typing = '') => [
  { roomId: '!a:x', displayName: '우리 가족', kind: 'family', memberCount: 4, agents: [], typing, lastMessage: { sender: '아빠', text: '저녁 먹자', ts: now - 30_000, eventId: '$e1' } },
  { roomId: '!b:x', displayName: '엄마', kind: 'private', memberCount: 2, agents: [], lastMessage: { sender: '엄마', text: '잘자', ts: now - 10_000, eventId: '$e9' } },
];
const photo = { kind: 'photo', name: 'menu.jpg', url: 'mxc://x/1' };
const baseTimeline = () => [
  { eventId: '$e1', name: '아빠', isMe: false, kind: 'text', body: '저녁 먹자', ts: now - 60_000 },
  { eventId: '$e2', name: '나', isMe: true, kind: 'photo', body: 'menu.jpg', attachment: photo, ts: now - 50_000 },
];
const previews = (status = 'ready', src = 'blob:one') => ({ get: () => ({ status, src }), fail() {}, retry() {} });
const box = (overrides = {}) => ({ open: false, tab: 'filebox', attachments: [], filebox: { url: 'https://files.example.test/?r=0', homeUrl: 'https://files.example.test/', title: '파일보관함' }, onToggle() {}, onTab() {}, onRefresh() {}, onOpen() {}, ...overrides });
const props = ({ typing = '', timeline = baseTimeline(), photoPreviews = previews(), listTyping = '', boxProps = box(), roomOverrides = {}, list = {} } = {}) => ({
  list: { summaries: rooms(listTyping), syncState: 'live', onSelect() {}, onOpenVerification() {}, onOpenRecovery() {}, onOpenMenu() {}, ...list },
  room: { room: rooms()[0], timeline, onSend() {}, onAttach() {}, onBack() {}, hasMore: false, photoPreviews, typing, ...roomOverrides },
  box: boxProps,
});
const q = (app, selector) => app.querySelector(selector);

test('re-rendering identical data keeps every mounted node (timeline, bubbles, photo, list, header, filebox)', () => {
  const app = root();
  ui.renderShell(app, props());
  const nodes = ['.timeline', 'li.bubble', '.photo-preview img', '.room-item', 'header.appbar', '.filebox-frame iframe', '.pane-list', 'textarea[name=body]'].map((s) => [s, q(app, s)]);
  ui.renderShell(app, props());
  for (const [selector, node] of nodes) same(q(app, selector), node, `${selector} 가 교체됐다`);
});

test('a typing label change swaps only the room header, not the timeline or the bubble under a selection', () => {
  const app = root();
  ui.renderShell(app, props());
  const timeline = q(app, '.timeline');
  const bubble = q(app, 'li.bubble .body');
  const header = q(app, '.room-screen > header.appbar');
  ui.renderShell(app, props({ typing: '입력중..', listTyping: '입력중..' }));
  same(q(app, '.timeline'), timeline, '입력중 표시로 타임라인이 교체됐다');
  same(q(app, 'li.bubble .body'), bubble, '입력중 표시로 말풍선이 교체됐다');
  assert.ok(q(app, '.room-screen > header.appbar') !== header, '머리글은 새 입력중 표시로 바뀌어야 한다');
  assert.match(q(app, '.room-screen .typing').textContent, /입력중/);
  // 목록에서는 입력중이 붙은 방 항목만 바뀐다.
  assert.match(q(app, '.room-item[data-room-id="!a:x"]').textContent, /입력중/);
});

test('a new message appends one bubble and keeps the existing ones', () => {
  const app = root();
  ui.renderShell(app, props());
  const [first, second] = app.querySelectorAll('li.bubble');
  const other = q(app, '.room-item[data-room-id="!b:x"]');
  ui.renderShell(app, props({ timeline: [...baseTimeline(), { eventId: '$e3', name: '엄마', isMe: false, kind: 'text', body: '다녀왔어', ts: now }] }));
  const bubbles = [...app.querySelectorAll('li.bubble')];
  assert.equal(bubbles.length, 3);
  same(bubbles[0], first, '기존 말풍선이 교체됐다');
  same(bubbles[1], second, '기존 사진 말풍선이 교체됐다');
  assert.match(bubbles[2].textContent, /다녀왔어/);
  same(q(app, '.room-item[data-room-id="!b:x"]'), other, '바뀌지 않은 방 항목이 교체됐다');
});

test('an edited message replaces only that bubble; order follows the timeline', () => {
  const app = root();
  ui.renderShell(app, props());
  const [first, second] = app.querySelectorAll('li.bubble');
  const edited = baseTimeline();
  edited[0] = { ...edited[0], body: '저녁은 김치찌개' };
  ui.renderShell(app, props({ timeline: edited }));
  const bubbles = [...app.querySelectorAll('li.bubble')];
  assert.ok(bubbles[0] !== first, '수정된 말풍선은 다시 그려야 한다');
  assert.match(bubbles[0].textContent, /김치찌개/);
  same(bubbles[1], second, '수정되지 않은 말풍선이 교체됐다');
  ui.renderShell(app, props({ timeline: [edited[1], edited[0]] }));
  const reordered = [...app.querySelectorAll('li.bubble')].map((node) => node.dataset.eventId);
  assert.deepEqual(reordered, ['$e2', '$e1']);
  assert.equal(app.querySelectorAll('li.load-earlier').length, 1);
});

test('a photo keeps its <img> until the preview itself changes', () => {
  const app = root();
  ui.renderShell(app, props());
  const img = q(app, '.photo-preview img');
  ui.renderShell(app, props({ photoPreviews: previews('ready', 'blob:one') }));
  same(q(app, '.photo-preview img'), img, '같은 미리보기인데 img를 다시 만들었다');
  ui.renderShell(app, props({ photoPreviews: previews('ready', 'blob:two') }));
  assert.ok(q(app, '.photo-preview img') !== img);
  assert.equal(q(app, '.photo-preview img').getAttribute('src'), 'blob:two');
});

test('the filebox iframe is kept across renders and replaced only when its url changes (refresh)', () => {
  const app = root();
  ui.renderShell(app, props());
  const frame = q(app, '.filebox-frame iframe');
  ui.renderShell(app, props({ typing: '입력중..', timeline: [...baseTimeline(), { eventId: '$e3', name: '엄마', kind: 'text', body: '새 글', ts: now }] }));
  same(q(app, '.filebox-frame iframe'), frame, '재렌더마다 파일보관함 iframe이 다시 로드된다');
  // 첨부 탭이 아닐 때는 첨부 목록 변화가 보관함을 다시 그리지 않는다.
  ui.renderShell(app, props({ boxProps: box({ attachments: [{ kind: 'file', name: 'a.pdf', size: 1, url: 'mxc://x/2', roomName: '우리 가족', ts: now }] }) }));
  same(q(app, '.filebox-frame iframe'), frame, '첨부 목록 변화로 파일보관함 iframe이 다시 로드됐다');
  ui.renderShell(app, props({ boxProps: box({ filebox: { url: 'https://files.example.test/?r=1', homeUrl: 'https://files.example.test/', title: '파일보관함' } }) }));
  assert.ok(q(app, '.filebox-frame iframe') !== frame, '새로고침(url 변경)은 iframe을 다시 만들어야 한다');
});

test('a focused room button keeps focus when the list re-renders (no room open)', () => {
  const app = root();
  const listOnly = () => ({ list: props().list, room: null, box: null });
  ui.renderShell(app, listOnly());
  const button = q(app, '.room-item[data-room-id="!b:x"]');
  button.focus();
  ui.renderShell(app, listOnly());
  same(q(app, '.room-item[data-room-id="!b:x"]'), button, '목록 항목이 교체됐다');
  same(document.activeElement, button, '재렌더 뒤 포커스가 떨어졌다');
});

test('a changed list frame (sync error, invites) still rebuilds the pane', () => {
  const app = root();
  ui.renderShell(app, props());
  const pane = q(app, '.pane-list');
  ui.renderShell(app, props({ list: { syncState: 'error' } }));
  assert.ok(q(app, '.pane-list') !== pane);
  assert.ok(q(app, '.pane-list .status.warn'), '동기화 경고가 보여야 한다');
});

test('setStatus removes only its own line — the crypto banner in a kept pane survives', () => {
  const app = root();
  ui.renderShell(app, props({ list: { banner: '암호화 모듈 오류' } }));
  ui.setStatus(app, '불러오는 중');
  ui.setStatus(app, null);
  assert.ok(q(app, '.pane-list .banner'), 'setStatus가 암호화 배너를 지웠다');
  ui.renderShell(app, props({ list: { banner: '암호화 모듈 오류' } }));
  assert.ok(q(app, '.pane-list .banner'));
});

test('the kept scroller follows the latest load-earlier props', () => {
  const app = root();
  let calls = 0;
  ui.renderShell(app, props({ roomOverrides: { hasMore: false, onLoadEarlier: () => { calls += 1; } } }));
  const timeline = q(app, '.timeline');
  timeline.dispatchEvent(new window.Event('scroll'));
  assert.equal(calls, 0, '더 없는데 이전 대화를 요청했다');
  ui.renderShell(app, props({ roomOverrides: { hasMore: true, onLoadEarlier: () => { calls += 1; } } }));
  same(q(app, '.timeline'), timeline);
  assert.ok(q(app, 'li.load-earlier button'), '불러오기 버튼이 보여야 한다');
  timeline.dispatchEvent(new window.Event('scroll'));
  assert.equal(calls, 1, '유지된 스크롤러가 옛 hasMore=false를 보고 있다');
  q(app, 'li.load-earlier button').click();
  assert.equal(calls, 2);
  ui.renderShell(app, props({ roomOverrides: { hasMore: true, loadingEarlier: true, onLoadEarlier: () => { calls += 1; } } }));
  timeline.dispatchEvent(new window.Event('scroll'));
  assert.equal(calls, 2, '불러오는 중에는 다시 요청하지 않는다');
});

test('switching rooms still rebuilds the room pane', () => {
  const app = root();
  ui.renderShell(app, props());
  const timeline = q(app, '.timeline');
  const other = props();
  other.room = { ...other.room, room: rooms()[1], timeline: [{ eventId: '$m1', name: '엄마', kind: 'text', body: '잘자', ts: now }] };
  ui.renderShell(app, other);
  assert.ok(q(app, '.timeline') !== timeline);
  assert.equal(q(app, '.room-screen').dataset.roomId, '!b:x');
});
