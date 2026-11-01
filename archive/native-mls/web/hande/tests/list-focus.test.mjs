// 목록 갱신이 포커스된 방 행을 새 노드로 바꿔도 PageUp/Down 위치(키 포커스·하이라이트)를 잃지 않는 규칙.
// 2026-11-01 오너(안드로이드 크롬): 행을 고른 뒤 그 행의 시간 라벨(「1분 전」→「2분 전」)·미리보기가 바뀌면
// 하이라이트가 사라지고 Enter 가 먹지 않아 「빨리 Enter」해야 했다. DOM 없이 도는 CI 용 — 가짜 노드로 판정만 본다.
// (실제 renderShell·shortcuts 재현은 headless Chrome 으로 PR 에 기록.)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { focusedRoomRowId, restoreRoomRowFocus } from '../ui.js';

test('updateListPane 은 두 갱신 경로(pane 통째 교체·행 단위 reconcile) 모두에서 포커스를 되살린다', () => {
  const source = readFileSync(new URL('../ui.js', import.meta.url), 'utf8');
  const start = source.indexOf('function updateListPane(');
  assert.ok(start >= 0, 'updateListPane 이 있어야 한다');
  const body = source.slice(start, source.indexOf('\n}\n', start));
  assert.match(body, /const focusedRoom = focusedRoomRowId\(old, doc\);/, '교체 전에 포커스된 행을 기억한다');
  const replaceBranch = body.slice(body.indexOf('old.replaceWith(fresh);'), body.indexOf('return;', body.indexOf('old.replaceWith(fresh);')));
  assert.match(replaceBranch, /restoreRoomRowFocus\(fresh, focusedRoom, doc\);/, 'pane 통째 교체 뒤 새 pane 에서 되살린다');
  const tail = body.slice(body.indexOf('reconcileChildren(oldRooms'));
  assert.match(tail, /restoreRoomRowFocus\(old, focusedRoom, doc\);/, '행 단위 reconcile 뒤 되살린다');
});

/** 최소 가짜 DOM: 방 행 button.room-item 들을 담은 pane 과 document. */
function fakeDom(roomIds) {
  const doc = { body: { tag: 'BODY', isConnected: true }, activeElement: null };
  doc.activeElement = doc.body;
  const pane = { rows: [] };
  const makeRow = (roomId) => {
    const row = {
      dataset: { roomId }, isConnected: true, focusCalls: [],
      closest: (selector) => (selector === 'button.room-item' ? row : null),
      focus(options) { row.focusCalls.push(options); doc.activeElement = row; },
    };
    return row;
  };
  pane.rows = roomIds.map(makeRow);
  pane.contains = (node) => pane.rows.includes(node);
  pane.querySelectorAll = (selector) => (selector === 'button.room-item' ? pane.rows : []);
  /** 갱신: 같은 방의 행을 새 노드로 바꾼다. 포커스된 노드가 빠지면 브라우저처럼 body 로 떨어진다. */
  pane.replaceRow = (roomId) => {
    const index = pane.rows.findIndex((row) => row.dataset.roomId === roomId);
    const old = pane.rows[index];
    old.isConnected = false;
    pane.rows[index] = makeRow(roomId);
    if (doc.activeElement === old) doc.activeElement = doc.body;
    return pane.rows[index];
  };
  return { doc, pane };
}

test('포커스된 방 행의 roomId 를 기억한다 — 목록 밖·방 행이 아니면 null', () => {
  const { doc, pane } = fakeDom(['r0', 'r1', 'r2']);
  assert.equal(focusedRoomRowId(pane, doc), null, '포커스가 body 면 기억할 행이 없다');
  pane.rows[1].focus();
  assert.equal(focusedRoomRowId(pane, doc), 'r1');
  doc.activeElement = { closest: () => null }; // 목록 밖(작성창 등)
  assert.equal(focusedRoomRowId(pane, doc), null);
  assert.equal(focusedRoomRowId(null, doc), null);
  assert.equal(focusedRoomRowId(pane, null), null);
});

test('포커스된 행이 새 노드로 바뀌면 같은 방의 새 행으로 포커스를 돌려준다(스크롤 없이)', () => {
  const { doc, pane } = fakeDom(['r0', 'r1', 'r2']);
  pane.rows[1].focus();
  const remembered = focusedRoomRowId(pane, doc);
  const fresh = pane.replaceRow('r1'); // 「1분 전」→「2분 전」
  assert.equal(doc.activeElement, doc.body, '전제: 교체로 포커스가 body 로 떨어졌다');
  assert.equal(restoreRoomRowFocus(pane, remembered, doc), true);
  assert.equal(doc.activeElement, fresh);
  assert.deepEqual(fresh.focusCalls, [{ preventScroll: true }]);
});

test('다른 행만 바뀌었으면(포커스가 그대로) 아무것도 하지 않는다', () => {
  const { doc, pane } = fakeDom(['r0', 'r1', 'r2']);
  pane.rows[1].focus();
  const remembered = focusedRoomRowId(pane, doc);
  pane.replaceRow('r2');
  assert.equal(restoreRoomRowFocus(pane, remembered, doc), false);
  assert.equal(doc.activeElement, pane.rows[1]);
  assert.equal(pane.rows[1].focusCalls.length, 1, '처음 포커스 한 번뿐 — 다시 focus() 하지 않는다');
});

test('포커스가 다른 곳(시트·작성창)으로 옮겨 갔으면 빼앗지 않는다', () => {
  const { doc, pane } = fakeDom(['r0', 'r1']);
  pane.rows[0].focus();
  const remembered = focusedRoomRowId(pane, doc);
  const sheetButton = { isConnected: true };
  doc.activeElement = sheetButton;
  const fresh = pane.replaceRow('r0');
  assert.equal(restoreRoomRowFocus(pane, remembered, doc), false);
  assert.equal(doc.activeElement, sheetButton);
  assert.equal(fresh.focusCalls.length, 0);
});

test('문서에서 빠진 노드가 activeElement 로 남아 있어도(일부 브라우저) 떨어진 것으로 본다', () => {
  const { doc, pane } = fakeDom(['r0', 'r1']);
  pane.rows[0].focus();
  const remembered = focusedRoomRowId(pane, doc);
  const old = pane.rows[0];
  pane.rows[0] = { ...old, dataset: { roomId: 'r0' }, isConnected: true, focusCalls: [], focus(options) { this.focusCalls.push(options); doc.activeElement = this; } };
  old.isConnected = false; // activeElement 는 여전히 old
  assert.equal(restoreRoomRowFocus(pane, remembered, doc), true);
  assert.equal(doc.activeElement, pane.rows[0]);
});

test('그 방이 목록에서 사라졌거나 기억한 행이 없으면 아무것도 하지 않는다', () => {
  const { doc, pane } = fakeDom(['r0', 'r1']);
  assert.equal(restoreRoomRowFocus(pane, null, doc), false);
  assert.equal(restoreRoomRowFocus(pane, 'gone', doc), false);
  assert.equal(restoreRoomRowFocus(null, 'r0', doc), false);
  assert.equal(doc.activeElement, doc.body);
});
