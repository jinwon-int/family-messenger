// 화면 키보드가 열릴 때 셸 높이를 보이는 영역에 맞추는 viewport.js — 순수 판정 + 가짜 window/document로 설치 검사.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { keyboardState, installViewportFit, KEYBOARD_MIN_PX, BAR_MIN_PX } from '../src/viewport.js';

test('keyboardState: 창 높이와 보이는 영역 차가 임계 이상이면 열림, 바 높이쯤이면 bar, 더 작으면 없음; 잘못된 입력은 판정 불가', () => {
  assert.deepEqual(keyboardState({ innerHeight: 844, viewportHeight: 844 }), { open: false, mode: null, height: 844 });
  assert.deepEqual(keyboardState({ innerHeight: 844, viewportHeight: 830 }), { open: false, mode: null, height: 830 }, '14px 흔들림은 무시');
  assert.deepEqual(keyboardState({ innerHeight: 844, viewportHeight: 800 }), { open: false, mode: 'bar', height: 800 }, '44px 감소 = 외부 키보드의 입력 보조 바(화면 키보드는 아님)');
  assert.deepEqual(keyboardState({ innerHeight: 844, viewportHeight: 508.4 }), { open: true, mode: 'keyboard', height: 508 }, '336px 줄면 키보드');
  assert.equal(keyboardState({ innerHeight: 844, viewportHeight: 844 - KEYBOARD_MIN_PX }).open, true, '임계와 같으면 열림');
  assert.equal(keyboardState({ innerHeight: 844, viewportHeight: 844 - BAR_MIN_PX }).mode, 'bar', '바 임계와 같으면 bar');
  assert.equal(keyboardState({ innerHeight: 844, viewportHeight: 844 - KEYBOARD_MIN_PX + 1 }).mode, 'bar', '키보드 임계 직전까지는 bar');
  assert.deepEqual(keyboardState({ innerHeight: 844, viewportHeight: 0 }), { open: false, mode: null, height: null });
  assert.deepEqual(keyboardState({ innerHeight: NaN, viewportHeight: 500 }), { open: false, mode: null, height: null });
  assert.deepEqual(keyboardState(), { open: false, mode: null, height: null });
});

const listenable = (obj) => {
  const em = new EventEmitter();
  return Object.assign(obj, { addEventListener: em.on.bind(em), removeEventListener: em.off.bind(em), emit: em.emit.bind(em) });
};
function fakeEnv({ innerHeight = 844, viewportHeight = 844, offsetTop = 0 } = {}) {
  const viewport = listenable({ height: viewportHeight, offsetTop });
  const scrolls = [];
  const win = listenable({ innerHeight, scrollY: 0, visualViewport: viewport, scrollTo: (x, y) => { scrolls.push([x, y]); win.scrollY = 0; } });
  const vars = new Map();
  const root = { dataset: {}, style: { setProperty: (k, v) => vars.set(k, v), removeProperty: (k) => vars.delete(k) } };
  const doc = listenable({ documentElement: root });
  return { win, doc, viewport, root, vars, scrolls };
}

test('installViewportFit: 작성창 포커스 뒤 지연 재보정 — 마지막 resize 뒤에 Safari가 문서를 밀어도 되돌린다; 해제하면 타이머도 멈춘다', async () => {
  const env = fakeEnv();
  const dispose = installViewportFit({ win: env.win, doc: env.doc, settleDelays: [5, 20] });
  env.viewport.height = 508;
  env.viewport.emit('resize'); // 열림, 아직 밀리지 않음
  assert.deepEqual(env.scrolls, []);
  env.doc.emit('focusin');
  env.win.scrollY = 336; // resize 뒤에 Safari가 문서를 밀었다
  await new Promise((r) => setTimeout(r, 12));
  assert.deepEqual(env.scrolls, [[0, 0]], '첫 지연 보정이 되돌린다');
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(env.scrolls, [[0, 0]], '이미 0이면 다시 스크롤하지 않는다');
  // window scroll 이벤트로도 되돌린다.
  env.win.scrollY = 100;
  env.win.emit('scroll');
  assert.deepEqual(env.scrolls, [[0, 0], [0, 0]]);
  // 해제 뒤 예약된 타이머는 실행되지 않는다.
  env.doc.emit('focusin');
  dispose();
  env.win.scrollY = 50;
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(env.scrolls.length, 2);
});

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
  // 아주 작은 차(14px)는 아무것도 하지 않는다.
  env.viewport.height = 830;
  env.viewport.emit('resize');
  assert.equal(env.root.dataset.keyboard, undefined);
  assert.equal(env.vars.has('--shell-height'), false);
  // 해제하면 더 반응하지 않는다.
  dispose();
  env.viewport.height = 508;
  env.viewport.emit('resize');
  assert.equal(env.vars.has('--shell-height'), false);
});

test('installViewportFit: 외부(블루투스) 키보드 — 입력 보조 바만큼(수십 px) 줄면 data-keyboard="bar"로 셸을 그 높이에 맞추고, 사라지면 걷는다', () => {
  const env = fakeEnv();
  const dispose = installViewportFit({ win: env.win, doc: env.doc });
  // 작성창 포커스: 화면 키보드는 없고 iOS 입력 보조 바(↑↓·완료)만 아래에 그려져 보이는 영역이 58px 줄었다.
  env.viewport.height = 786;
  env.viewport.offsetTop = 58;
  env.viewport.emit('resize');
  assert.equal(env.vars.get('--shell-height'), '786px', '바 높이만큼 셸을 줄여 작성창이 바 위에 오게 한다');
  assert.equal(env.root.dataset.keyboard, 'bar', '화면 키보드 열림("open")과 구분한다');
  assert.deepEqual(env.scrolls, [[0, 0]], '밀린 문서는 되돌린다');
  // 바 상태에서 화면 키보드가 열리면(외부 키보드 분리) open으로 바뀐다.
  env.viewport.height = 508;
  env.viewport.offsetTop = 0;
  env.viewport.emit('resize');
  assert.equal(env.root.dataset.keyboard, 'open');
  assert.equal(env.vars.get('--shell-height'), '508px');
  // 다시 바만 남으면 bar.
  env.viewport.height = 786;
  env.viewport.emit('resize');
  assert.equal(env.root.dataset.keyboard, 'bar');
  // 포커스를 잃어 바가 사라지면 걷는다.
  env.viewport.height = 844;
  env.viewport.emit('resize');
  assert.equal(env.vars.has('--shell-height'), false);
  assert.equal(env.root.dataset.keyboard, undefined);
  dispose();
});

test('installViewportFit: visualViewport가 없으면 아무것도 하지 않는 해제 함수', () => {
  const root = { dataset: {}, style: { setProperty() { throw new Error('must not touch'); }, removeProperty() {} } };
  const dispose = installViewportFit({ win: { innerHeight: 800 }, doc: { documentElement: root } });
  assert.equal(typeof dispose, 'function');
  dispose();
  assert.deepEqual(root.dataset, {});
});
