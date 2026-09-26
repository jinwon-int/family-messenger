// 대화 목록 고정 순서 — 편집 모드의 ▲▼·끌어 옮기기가 올바른 위치로 onMoveRoom을 부르는지,
// 편집 중에는 행을 눌러도 방이 열리지 않는지 검사한다.
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

const root = () => {
  document.body.innerHTML = '<div id="app"></div>';
  return document.getElementById('app');
};
const summaries = () => [
  { roomId: '!a:x', displayName: '우리 가족', kind: 'family', memberCount: 4, agents: [], lastMessage: null },
  { roomId: '!b:x', displayName: '엄마', kind: 'private', memberCount: 2, agents: [], lastMessage: null },
  { roomId: '!c:x', displayName: '아빠', kind: 'private', memberCount: 2, agents: [], lastMessage: null },
];
const render = (app, list = {}) => {
  const calls = { moves: [], selects: [], toggles: 0 };
  ui.renderShell(app, {
    list: {
      summaries: summaries(), syncState: 'live', onOpenVerification() {}, onOpenRecovery() {}, onOpenMenu() {},
      onSelect: (room) => calls.selects.push(room.roomId),
      onToggleOrderEdit: () => { calls.toggles += 1; },
      onMoveRoom: (...args) => calls.moves.push(args),
      ...list,
    },
    room: null,
  });
  return calls;
};
const row = (app, roomId) => [...app.querySelectorAll('ul.rooms > li')].find((li) => li.dataset.roomId === roomId);

test('편집 전: 순서 편집 버튼만 있고 ▲▼는 없으며, 행을 누르면 방이 열린다', () => {
  const app = root();
  const calls = render(app);
  const toggle = app.querySelector('.order-toggle');
  assert.ok(toggle, '순서 편집 버튼이 있다');
  assert.equal(toggle.textContent, '↕순서');
  assert.equal(toggle.getAttribute('aria-label'), '대화 순서 편집');
  assert.equal(app.querySelectorAll('.order-btn').length, 0);
  toggle.click();
  assert.equal(calls.toggles, 1);
  row(app, '!b:x').querySelector('.room-item').click();
  assert.deepEqual(calls.selects, ['!b:x']);
});

test('방이 하나뿐이거나 핸들러가 없으면 순서 편집 버튼을 두지 않는다', () => {
  const app = root();
  render(app, { summaries: summaries().slice(0, 1) });
  assert.equal(app.querySelector('.order-toggle'), null);
  render(app, { onMoveRoom: null });
  assert.equal(app.querySelector('.order-toggle'), null);
});

test('편집 중: ▲▼가 한 칸씩 옮기고, 맨 위 ▲·맨 아래 ▼는 비활성, 행을 눌러도 방이 열리지 않는다', () => {
  const app = root();
  const calls = render(app, { orderEditing: true });
  assert.equal(app.querySelector('.order-toggle').textContent, '완료');
  assert.ok(app.querySelector('.order-hint'), '안내 문구가 보인다');
  assert.ok(row(app, '!a:x').querySelector('.order-up').disabled);
  assert.ok(!row(app, '!a:x').querySelector('.order-down').disabled);
  assert.ok(row(app, '!c:x').querySelector('.order-down').disabled);
  assert.equal(row(app, '!b:x').querySelector('.order-up').getAttribute('aria-label'), '엄마 위로 이동');

  row(app, '!b:x').querySelector('.order-up').click();
  row(app, '!b:x').querySelector('.order-down').click();
  assert.deepEqual(calls.moves, [['!b:x', 0, 'up'], ['!b:x', 2, 'down']]);

  row(app, '!b:x').querySelector('.room-item').click();
  assert.deepEqual(calls.selects, [], '편집 중에는 방을 열지 않는다');
  assert.equal(row(app, '!b:x').querySelector('.room-item').tagName, 'DIV', '편집 중 행은 버튼이 아니다(Firefox 끌기)');
  assert.equal(app.querySelector('.order-toggle').getAttribute('aria-label'), '대화 순서 편집 완료');
});

test('편집 중: 다른 행 위에 끌어 놓으면 그 행의 자리로 옮긴다', () => {
  const app = root();
  const calls = render(app, { orderEditing: true });
  const target = row(app, '!a:x');
  assert.equal(target.getAttribute('draggable'), 'true');
  const drop = new window.Event('drop', { bubbles: true, cancelable: true });
  drop.dataTransfer = { getData: () => '!c:x' };
  target.dispatchEvent(drop);
  const self = new window.Event('drop', { bubbles: true, cancelable: true });
  self.dataTransfer = { getData: () => '!a:x' };
  target.dispatchEvent(self);
  assert.deepEqual(calls.moves, [['!c:x', 0]], '자기 자신 위에 놓으면 아무것도 하지 않는다');
});

test('옮긴 뒤 같은 방의 같은 방향 버튼으로 포커스를 돌려주고, 끝에 닿으면 반대 버튼으로', () => {
  const app = root();
  render(app, { orderEditing: true });
  ui.focusRoomOrderControl(app, '!b:x', 'up');
  assert.ok(document.activeElement === row(app, '!b:x').querySelector('.order-up'));
  ui.focusRoomOrderControl(app, '!a:x', 'up');
  assert.ok(document.activeElement === row(app, '!a:x').querySelector('.order-down'), '맨 위라 ▲가 비활성이면 ▼');
  ui.focusRoomOrderControl(app, '!없음', 'up');
});

test('편집 중 자리가 바뀐 행은 다시 그려져 ▲▼가 새 위치를 쓴다', () => {
  const app = root();
  render(app, { orderEditing: true });
  const [a, b, c] = summaries();
  const calls = render(app, { orderEditing: true, summaries: [b, a, c] });
  row(app, '!b:x').querySelector('.order-down').click();
  assert.deepEqual(calls.moves, [['!b:x', 1, 'down']]);
  assert.ok(row(app, '!b:x').querySelector('.order-up').disabled, '이제 맨 위다');
});
