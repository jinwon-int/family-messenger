// #300 — 대화창 상단 "내 마지막 말" 바. 렌더·유지·교체·클릭 이동·접기·없을 때 미표시를 happy-dom으로 검사한다.
// DOM 노드는 assert.equal로 비교하지 않는다(reconcile.test.mjs 참고).
import test from 'node:test';
import assert from 'node:assert/strict';
import { Window } from 'happy-dom';

const window = new Window({ url: 'https://chat.example.test/' });
for (const key of ['HTMLElement', 'Node', 'Event', 'CSS', 'FormData', 'localStorage']) globalThis[key] = window[key] ?? globalThis[key];
globalThis.window = window;
globalThis.document = window.document;
if (!globalThis.CSS) globalThis.CSS = window.CSS;

const ui = await import('../../src/ui.js');
const { lastSentSummary } = await import('../../src/last-sent.js');

const same = (a, b, message) => assert.ok(a != null && a === b, message);
const root = () => {
  document.body.innerHTML = '<div id="app"></div>';
  globalThis.localStorage.clear();
  return document.getElementById('app');
};
const now = Date.now();
const labels = { photo: '사진', video: '영상', file: '파일', undecryptable: '열 수 없는 메시지' };
const rooms = () => [{ roomId: '!a:x', displayName: '우리 가족', kind: 'family', memberCount: 4, agents: [], lastMessage: null }];
const timelineA = () => [
  { eventId: '$e1', name: '아빠', isMe: false, kind: 'text', body: '저녁 먹자', ts: now - 60_000 },
  { eventId: '$e2', name: '나', isMe: true, kind: 'text', body: '7시에 가요', ts: now - 50_000 },
  { eventId: '$e3', name: '엄마', isMe: false, kind: 'text', body: '좋아', ts: now - 40_000 },
];
const previews = () => ({ get: () => ({ status: 'ready', src: 'blob:one' }), fail() {}, retry() {} });
const box = () => ({ open: false, tab: 'attachments', attachments: [], filebox: null, onToggle() {}, onTab() {}, onRefresh() {}, onOpen() {} });
const props = ({ timeline = timelineA(), lastSent = lastSentSummary(timeline, { labels }) } = {}) => ({
  list: { summaries: rooms(), syncState: 'live', onSelect() {}, onOpenVerification() {}, onOpenRecovery() {}, onOpenMenu() {} },
  room: { room: rooms()[0], timeline, lastSent, onSend() {}, onAttach() {}, onBack() {}, hasMore: false, photoPreviews: previews(), typing: '' },
  box: box(),
});
const q = (app, s) => app.querySelector(s);

test('바는 헤더 아래·타임라인 위에 내 마지막 말·답장 수·시간을 보여 준다', () => {
  const app = root();
  ui.renderShell(app, props());
  const bar = q(app, '.room-screen > .last-sent');
  assert.ok(bar, '바가 없다');
  same(bar.nextElementSibling, q(app, '.timeline-wrap'), '바는 타임라인 바로 위여야 한다');
  assert.equal(bar.dataset.eventId, '$e2');
  assert.match(q(app, '.last-sent .preview').textContent, /7시에 가요/);
  assert.match(q(app, '.last-sent .kicker').textContent, /내 마지막 말/);
  assert.match(q(app, '.last-sent .chip').textContent, /답장 1/);
  assert.equal(bar.getAttribute('role'), 'region');
  // 기본은 접힘(오너 2026-10-07): 처음 들어온 방은 라벨·칩 한 줄만.
  assert.equal(bar.dataset.collapsed, 'true');
  assert.equal(q(app, '.last-sent .toggle').getAttribute('aria-expanded'), 'false');
});

test('같은 데이터로 다시 그리면 바 노드가 유지되고, 내 말이 바뀌면 교체된다', () => {
  const app = root();
  ui.renderShell(app, props());
  const bar = q(app, '.last-sent');
  const timeline = q(app, '.timeline');
  ui.renderShell(app, props());
  same(q(app, '.last-sent'), bar, '같은 데이터인데 바가 교체됐다');
  const next = [...timelineA(), { eventId: '~txn9', name: '나', isMe: true, kind: 'text', body: '방금 보냄', ts: now }];
  ui.renderShell(app, props({ timeline: next }));
  assert.ok(q(app, '.last-sent') !== bar, '내 말이 바뀌었는데 바가 그대로다');
  same(q(app, '.timeline'), timeline, '바 교체가 타임라인을 건드렸다');
  assert.match(q(app, '.last-sent .preview').textContent, /방금 보냄/);
  assert.match(q(app, '.last-sent .chip.pending').textContent, /전송 중/);
  assert.equal(q(app, '.last-sent').dataset.eventId, '~txn9');
});

test('로컬 에코가 서버 id로 확정되면 바의 eventId도 따라가고 전송 중 칩이 사라진다', () => {
  const app = root();
  const pending = [...timelineA(), { eventId: '~txn9', name: '나', isMe: true, kind: 'text', body: '방금 보냄', ts: now }];
  ui.renderShell(app, props({ timeline: pending }));
  const confirmed = [...timelineA(), { eventId: '$e9', name: '나', isMe: true, kind: 'text', body: '방금 보냄', ts: now }];
  ui.renderShell(app, props({ timeline: confirmed }));
  assert.equal(q(app, '.last-sent').dataset.eventId, '$e9');
  assert.equal(q(app, '.last-sent .chip.pending'), null);
  assert.match(q(app, '.last-sent .chip').textContent, /아직 답 없음/);
});

test('누르면 그 말풍선으로 스크롤하고 잠깐 밝힌다; 불러온 범위 밖이면 안내만', () => {
  const app = root();
  ui.renderShell(app, props());
  const list = q(app, '.timeline');
  const bubble = q(app, 'li.bubble[data-event-id="$e2"]');
  // happy-dom은 레이아웃이 없다 — offsetTop을 흉내 낸다.
  Object.defineProperty(bubble, 'offsetTop', { value: 300, configurable: true });
  Object.defineProperty(list, 'offsetTop', { value: 100, configurable: true });
  list.scrollTop = 999;
  q(app, '.last-sent .jump').click();
  assert.equal(list.scrollTop, 192, '말풍선 위치(300-100-8)로 스크롤해야 한다');
  assert.ok(bubble.classList.contains('flash'), '이동한 말풍선을 밝혀야 한다');
  assert.equal(q(app, '.last-sent .hint').hidden, true);
  // 범위 밖: 바는 있지만 그 말풍선이 DOM에 없는 경우.
  const missing = { eventId: '$old', text: '옛날 말', ts: now - 9_000_000, pending: false, replies: 3 };
  ui.renderShell(app, props({ lastSent: missing }));
  list.scrollTop = 777;
  q(app, '.last-sent .jump').click();
  assert.equal(list.scrollTop, 777, '없는 말풍선으로는 스크롤하지 않는다');
  assert.equal(q(app, '.last-sent .hint').hidden, false);
  assert.match(q(app, '.last-sent .hint').textContent, /불러온 대화 밖/);
});

test('기본은 접힘; 펼침은 방별로 기억되고 재렌더·재마운트 뒤에도 유지된다', () => {
  const app = root();
  ui.renderShell(app, props());
  assert.equal(q(app, '.last-sent').dataset.collapsed, 'true', '기본이 접힘이 아니다');
  const toggle = q(app, '.last-sent .toggle');
  toggle.click();
  assert.equal(q(app, '.last-sent').dataset.collapsed, 'false');
  assert.equal(toggle.getAttribute('aria-expanded'), 'true');
  assert.equal(globalThis.localStorage.getItem('familychat:lastSent:collapsed:!a:x'), '0');
  ui.renderShell(app, props());
  assert.equal(q(app, '.last-sent').dataset.collapsed, 'false', '같은 방 재렌더가 펼침을 접었다');
  // 방 화면을 새로 만들어도(목록으로 갔다 돌아옴) 펼친 채다.
  document.body.innerHTML = '<div id="app"></div>';
  const app2 = document.getElementById('app');
  ui.renderShell(app2, props());
  assert.equal(q(app2, '.last-sent').dataset.collapsed, 'false');
  q(app2, '.last-sent .toggle').click();
  assert.equal(q(app2, '.last-sent').dataset.collapsed, 'true');
  assert.equal(globalThis.localStorage.getItem('familychat:lastSent:collapsed:!a:x'), null);
});

test('예전에 접힘(\'1\')으로 저장된 방은 그대로 접힘, 저장소가 막혀도 접힘', () => {
  const app = root();
  globalThis.localStorage.setItem('familychat:lastSent:collapsed:!a:x', '1');
  ui.renderShell(app, props());
  assert.equal(q(app, '.last-sent').dataset.collapsed, 'true');
  const app2 = root();
  const original = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, get() { throw new Error('blocked'); } });
  try {
    ui.renderShell(app2, props());
    assert.equal(q(app2, '.last-sent').dataset.collapsed, 'true');
    q(app2, '.last-sent .toggle').click();
    assert.equal(q(app2, '.last-sent').dataset.collapsed, 'false', '저장소가 막혀도 이번 화면에서는 펼쳐져야 한다');
  } finally {
    Object.defineProperty(globalThis, 'localStorage', original);
  }
});

test('내 말이 없으면 바를 그리지 않고, 생기면 타임라인 위에 끼우고, 없어지면 뗀다', () => {
  const app = root();
  const others = [timelineA()[0], timelineA()[2]];
  ui.renderShell(app, props({ timeline: others }));
  assert.equal(q(app, '.last-sent'), null);
  const timeline = q(app, '.timeline');
  ui.renderShell(app, props());
  same(q(app, '.last-sent').nextElementSibling, q(app, '.timeline-wrap'));
  same(q(app, '.timeline'), timeline);
  ui.renderShell(app, props({ timeline: others }));
  assert.equal(q(app, '.last-sent'), null);
  same(q(app, '.timeline'), timeline);
});
