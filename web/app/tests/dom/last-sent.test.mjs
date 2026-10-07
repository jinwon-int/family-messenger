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
const { lastSentSummary, recentSentSummaries } = await import('../../src/last-sent.js');

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
const props = ({ timeline = timelineA(), lastSent = lastSentSummary(timeline, { labels }), earlierSent = [] } = {}) => ({
  list: { summaries: rooms(), syncState: 'live', onSelect() {}, onOpenVerification() {}, onOpenRecovery() {}, onOpenMenu() {} },
  room: { room: rooms()[0], timeline, lastSent, earlierSent, onSend() {}, onAttach() {}, onBack() {}, hasMore: false, photoPreviews: previews(), typing: '' },
  box: box(),
});
// 내 말이 셋인 대화 — 펼친 바에 이전 내 말 2개가 더 보여야 한다(오너 2026-10-07).
const timelineB = () => [
  { eventId: '$m1', name: '나', isMe: true, kind: 'text', body: '오늘 몇 시에 모여요?', ts: now - 90_000 },
  { eventId: '$o1', name: '아빠', isMe: false, kind: 'text', body: '7시', ts: now - 80_000 },
  { eventId: '$m2', name: '나', isMe: true, kind: 'text', body: '네 알겠어요', ts: now - 70_000 },
  { eventId: '$m3', name: '나', isMe: true, kind: 'text', body: '케이크 사갈게요', ts: now - 60_000 },
  { eventId: '$o2', name: '엄마', isMe: false, kind: 'text', body: '고마워', ts: now - 50_000 },
  { eventId: '$o3', name: '아빠', isMe: false, kind: 'text', body: '초도 부탁', ts: now - 40_000 },
];
const propsB = () => {
  const timeline = timelineB();
  const recent = recentSentSummaries(timeline, { labels, limit: 3 });
  return props({ timeline, lastSent: recent[0], earlierSent: recent.slice(1) });
};
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

test('접힘에서 바를 누르면 이동 대신 펼치고(기억됨), 펼친 바를 다시 눌러도 접히지 않는다; 접기는 화살표로만', () => {
  const app = root();
  ui.renderShell(app, props());
  const list = q(app, '.timeline');
  const bubble = q(app, 'li.bubble[data-event-id="$e2"]');
  Object.defineProperty(bubble, 'offsetTop', { value: 300, configurable: true });
  Object.defineProperty(list, 'offsetTop', { value: 100, configurable: true });
  list.scrollTop = 999;
  const bar = q(app, '.last-sent');
  const jump = q(app, '.last-sent .jump');
  const toggle = q(app, '.last-sent .toggle');
  assert.equal(bar.dataset.collapsed, 'true');
  assert.equal(jump.title, '내 마지막 말 펼치기');
  jump.click();
  assert.equal(bar.dataset.collapsed, 'false', '접힘에서 바를 누르면 펼쳐야 한다');
  assert.equal(list.scrollTop, 999, '펼치기 탭은 스크롤하지 않는다');
  assert.ok(!bubble.classList.contains('flash'), '펼치기 탭은 말풍선을 밝히지 않는다');
  assert.equal(toggle.getAttribute('aria-expanded'), 'true');
  assert.equal(toggle.textContent, '▴');
  assert.equal(jump.title, '이 메시지로 이동');
  // 재렌더 후에도 펼침 유지(서명·localStorage).
  ui.renderShell(app, props());
  same(q(app, '.last-sent'), bar, '펼친 뒤 같은 데이터 재렌더에서 바가 교체됐다');
  assert.equal(q(app, '.last-sent').dataset.collapsed, 'false');
  // 펼친 상태에서 바를 누르면 이동만 하고 접히지 않는다.
  jump.click();
  assert.equal(bar.dataset.collapsed, 'false', '펼친 바를 눌러도 접히면 안 된다');
  assert.equal(list.scrollTop, 192);
  // 접기는 화살표로.
  toggle.click();
  assert.equal(bar.dataset.collapsed, 'true');
  assert.equal(toggle.getAttribute('aria-expanded'), 'false');
  assert.equal(jump.title, '내 마지막 말 펼치기');
});

test('펼친 바를 누르면 그 말풍선으로 스크롤하고 잠깐 밝힌다; 불러온 범위 밖이면 안내만', () => {
  const app = root();
  ui.renderShell(app, props());
  q(app, '.last-sent .toggle').click();
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

test('펼치면 이전 내 말이 최대 2개 더 보이고(합계 3), 누르면 그 말풍선으로 스크롤한다; 접힘에서는 CSS로 숨긴다', async () => {
  const app = root();
  globalThis.localStorage.setItem('familychat:lastSent:collapsed:!a:x', '0'); // 펼침 상태로 시작
  ui.renderShell(app, propsB());
  const bar = q(app, '.last-sent');
  assert.equal(bar.dataset.collapsed, 'false');
  assert.match(q(app, '.last-sent .preview').textContent, /케이크 사갈게요/, '바 본문은 가장 최근 내 말');
  const rows = [...app.querySelectorAll('.last-sent .earlier li .earlier-jump')];
  assert.equal(rows.length, 2, '이전 내 말은 2개(최신 1개 + 2개 = 3개)');
  assert.deepEqual(rows.map((b) => b.querySelector('.text').textContent), ['네 알겠어요', '오늘 몇 시에 모여요?'], '최신순');
  assert.deepEqual(rows.map((b) => b.dataset.eventId), ['$m2', '$m1']);
  assert.match(rows[0].querySelector('.chip').textContent, /아직 답 없음/, '둘째 말 뒤 다음 내 말 전까지 답장 0');
  assert.match(rows[1].querySelector('.chip').textContent, /답장 1/, '첫 말 뒤 다음 내 말 전까지 답장 1');
  assert.equal(q(app, '.last-sent .earlier').getAttribute('aria-label'), '이전 내 말 — 누르면 그 메시지로 이동');
  assert.equal(app.querySelectorAll('.last-sent button button').length, 0, '버튼 안에 버튼을 두지 않는다');
  // 누르면 그 말풍선으로 스크롤하고 밝힌다(큰 버튼과 같은 jumpToBubble 경로).
  const list = q(app, '.timeline');
  const bubble = q(app, 'li.bubble[data-event-id="$m1"]');
  Object.defineProperty(bubble, 'offsetTop', { value: 500, configurable: true });
  Object.defineProperty(list, 'offsetTop', { value: 100, configurable: true });
  list.scrollTop = 999;
  rows[1].click();
  assert.equal(list.scrollTop, 392, '말풍선 위치(500-100-8)로 스크롤해야 한다');
  assert.ok(bubble.classList.contains('flash'));
  assert.equal(q(app, '.last-sent .hint').hidden, true);
  // 내 말이 하나뿐이면 목록 자체가 없다.
  ui.renderShell(root(), props());
  assert.equal(document.querySelector('.last-sent .earlier'), null);
  // 접힘에서는 목록을 CSS로 숨긴다(DOM에는 남아 펼치면 바로 보인다).
  const { readFile } = await import('node:fs/promises');
  const css = await readFile(new URL('../../styles.css', import.meta.url), 'utf-8');
  assert.match(css, /\.last-sent\[data-collapsed="true"\] \.earlier \{ display: none; \}/);
  assert.match(css, /\.last-sent \.earlier-jump \.text \{[^}]*text-overflow: ellipsis/);
});

test('이전 내 말 목록이 바뀌면 바를 다시 그리고, 같으면 유지한다', () => {
  const app = root();
  ui.renderShell(app, propsB());
  const bar1 = q(app, '.last-sent');
  ui.renderShell(app, propsB());
  same(q(app, '.last-sent'), bar1, '같은 데이터면 바 노드 유지');
  // 둘째 말이 삭제돼 목록이 바뀌면 교체된다.
  const timeline = timelineB().filter((e) => e.eventId !== '$m2');
  const recent = recentSentSummaries(timeline, { labels, limit: 3 });
  ui.renderShell(app, props({ timeline, lastSent: recent[0], earlierSent: recent.slice(1) }));
  assert.notEqual(q(app, '.last-sent'), bar1, '목록이 바뀌면 바를 다시 그린다');
  assert.deepEqual([...app.querySelectorAll('.last-sent .earlier-jump')].map((b) => b.dataset.eventId), ['$m1']);
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

test('라벨 줄은 "내 마지막 말 → 내 말 한 줄 → 답장/시간" 순서다(접힘에서 보이는 한 줄)', () => {
  const app = root();
  ui.renderShell(app, props());
  const kids = [...q(app, '.last-sent .kicker').children].map((n) => n.className);
  assert.deepEqual(kids.slice(0, 3), ['label', 'inline-preview', 'chip']);
  assert.equal(q(app, '.last-sent .kicker .inline-preview').textContent, '7시에 가요');
  assert.equal(q(app, '.last-sent .kicker .label').textContent, '내 마지막 말');
});

test('styles.css: 접힘에서만 한 줄 미리보기를 말줄임으로 보이고, 펼침에서는 숨긴다', async () => {
  const { readFileSync } = await import('node:fs');
  const css = readFileSync(new URL('../../styles.css', import.meta.url), 'utf-8');
  assert.match(css, /\.last-sent \.kicker \.inline-preview \{ display: none; \}/);
  const rule = /\.last-sent\[data-collapsed="true"\] \.kicker \.inline-preview \{([^}]*)\}/.exec(css)?.[1] ?? '';
  assert.match(rule, /display: block/);
  assert.match(rule, /white-space: nowrap/);
  assert.match(rule, /text-overflow: ellipsis/);
  assert.match(rule, /min-width: 0/);
  assert.match(css, /\.last-sent\[data-collapsed="true"\] \.kicker \{[^}]*flex-wrap: nowrap/);
  // 휴대폰 폭 접힘에서는 시간 칩을 빼 "라벨·내 말·답장"만 둔다.
  const narrow = /@media \(max-width: 899px\) \{([\s\S]*?)\n\}/.exec(css)?.[1] ?? '';
  assert.match(narrow, /\.last-sent\[data-collapsed="true"\] \.kicker \.chip\.time \{ display: none; \}/);
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
