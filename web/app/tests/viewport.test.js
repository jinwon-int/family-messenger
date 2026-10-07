// 화면 키보드가 열릴 때 셸 높이를 보이는 영역에 맞추는 viewport.js — 순수 판정 + 가짜 window/document로 설치 검사.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { keyboardState, installViewportFit, KEYBOARD_MIN_PX } from '../src/viewport.js';

test('keyboardState: 창 높이와 보이는 영역 차가 임계 이상이면 열림, 아니면 닫힘; 잘못된 입력은 판정 불가', () => {
  assert.deepEqual(keyboardState({ innerHeight: 844, viewportHeight: 844 }), { open: false, height: 844 });
  assert.deepEqual(keyboardState({ innerHeight: 844, viewportHeight: 800 }), { open: false, height: 800 }, '주소창·툴바 변화(44px)는 키보드가 아니다');
  assert.deepEqual(keyboardState({ innerHeight: 844, viewportHeight: 508.4 }), { open: true, height: 508 }, '336px 줄면 키보드');
  assert.equal(keyboardState({ innerHeight: 844, viewportHeight: 844 - KEYBOARD_MIN_PX }).open, true, '임계와 같으면 열림');
  assert.deepEqual(keyboardState({ innerHeight: 844, viewportHeight: 0 }), { open: false, height: null });
  assert.deepEqual(keyboardState({ innerHeight: NaN, viewportHeight: 500 }), { open: false, height: null });
  assert.deepEqual(keyboardState(), { open: false, height: null });
});

function fakeEnv({ innerHeight = 844, viewportHeight = 844, offsetTop = 0 } = {}) {
  const viewport = Object.assign(new EventEmitter(), { height: viewportHeight, offsetTop });
  viewport.addEventListener = viewport.on;
  viewport.removeEventListener = viewport.off;
  const scrolls = [];
  const win = { innerHeight, scrollY: 0, visualViewport: viewport, scrollTo: (x, y) => scrolls.push([x, y]) };
  const vars = new Map();
  const root = { dataset: {}, style: { setProperty: (k, v) => vars.set(k, v), removeProperty: (k) => vars.delete(k) } };
  return { win, doc: { documentElement: root }, viewport, root, vars, scrolls };
}

test('installViewportFit: 키보드가 열리면 --shell-height와 data-keyboard를 두고 밀린 문서를 맨 위로, 닫히면 걷는다', () => {
  const env = fakeEnv();
  const dispose = installViewportFit({ win: env.win, doc: env.doc });
  assert.equal(env.vars.has('--shell-height'), false, '처음(닫힘)에는 변수를 두지 않는다');
  assert.equal(env.root.dataset.keyboard, undefined);
  // 키보드 열림: 보이는 영역이 336px 줄고 Safari가 문서를 밀어 올렸다.
  env.viewport.height = 508;
  env.viewport.offsetTop = 336;
  env.viewport.emit('resize');
  assert.equal(env.vars.get('--shell-height'), '508px');
  assert.equal(env.root.dataset.keyboard, 'open');
  assert.deepEqual(env.scrolls, [[0, 0]], '밀린 만큼 되돌린다');
  // 열린 채 스크롤 이벤트 — 밀리지 않았으면 다시 스크롤하지 않는다.
  env.viewport.offsetTop = 0;
  env.viewport.emit('scroll');
  assert.deepEqual(env.scrolls, [[0, 0]]);
  // 키보드 닫힘.
  env.viewport.height = 844;
  env.viewport.emit('resize');
  assert.equal(env.vars.has('--shell-height'), false);
  assert.equal(env.root.dataset.keyboard, undefined);
  // 주소창 변화(작은 차)는 열림이 아니다.
  env.viewport.height = 800;
  env.viewport.emit('resize');
  assert.equal(env.root.dataset.keyboard, undefined);
  // 해제하면 더 반응하지 않는다.
  dispose();
  env.viewport.height = 508;
  env.viewport.emit('resize');
  assert.equal(env.vars.has('--shell-height'), false);
});

test('installViewportFit: visualViewport가 없으면 아무것도 하지 않는 해제 함수', () => {
  const root = { dataset: {}, style: { setProperty() { throw new Error('must not touch'); }, removeProperty() {} } };
  const dispose = installViewportFit({ win: { innerHeight: 800 }, doc: { documentElement: root } });
  assert.equal(typeof dispose, 'function');
  dispose();
  assert.deepEqual(root.dataset, {});
});
