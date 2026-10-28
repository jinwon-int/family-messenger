// 탭·온라인·bfcache 복귀 즉시 동기화(#544 A). node --test archive/native-mls/web/hande/tests/sync-recovery.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installSyncRecovery, shouldResume, RESUME_EVENTS, DEFAULT_DEBOUNCE_MS } from '../sync-recovery.js';

/** EventTarget 흉내: addEventListener/removeEventListener/dispatch 만. */
function fakeTarget(extra = {}) {
  const listeners = new Map();
  return Object.assign({
    addEventListener: (name, fn) => { listeners.set(name, [...(listeners.get(name) ?? []), fn]); },
    removeEventListener: (name, fn) => { listeners.set(name, (listeners.get(name) ?? []).filter((f) => f !== fn)); },
    dispatch: (name) => { for (const fn of listeners.get(name) ?? []) fn({ type: name }); },
    count: (name) => (listeners.get(name) ?? []).length,
  }, extra);
}

function setup({ debounceMs } = {}) {
  let t = 10_000;
  const calls = [];
  const document = fakeTarget({ visibilityState: 'visible' });
  const window = fakeTarget();
  const uninstall = installSyncRecovery({ document, window, resume: () => calls.push(t), debounceMs, now: () => t });
  return { document, window, calls, uninstall, tick: (ms) => { t += ms; } };
}

test('shouldResume: 숨겨진 탭은 건너뛰고, 디바운스 안의 두 번째 이벤트도 건너뛴다', () => {
  assert.equal(shouldResume({ lastAt: 0 }, { hidden: true, now: 5000 }), false);
  assert.equal(shouldResume({ lastAt: 0 }, { hidden: false, now: 5000 }), true, '첫 실행');
  assert.equal(shouldResume({ lastAt: 5000 }, { hidden: false, now: 5000 + DEFAULT_DEBOUNCE_MS - 1 }), false, '디바운스 안');
  assert.equal(shouldResume({ lastAt: 5000 }, { hidden: false, now: 5000 + DEFAULT_DEBOUNCE_MS }), true, '디바운스 지남');
  assert.equal(shouldResume({ lastAt: 5000 }, { hidden: false, now: 5100, debounceMs: 50 }), true, '주입한 디바운스');
});

test('세 이벤트(visibilitychange·online·pageshow)에 각각 resume 이 붙고, 보이는 탭에서 한 번씩 부른다', () => {
  const { document, window, calls, tick } = setup();
  assert.deepEqual([...RESUME_EVENTS], ['visibilitychange', 'online', 'pageshow']);
  assert.equal(document.count('visibilitychange'), 1);
  assert.equal(window.count('online'), 1);
  assert.equal(window.count('pageshow'), 1);
  document.dispatch('visibilitychange'); tick(2000);
  window.dispatch('online'); tick(2000);
  window.dispatch('pageshow');
  assert.equal(calls.length, 3);
});

test('탭 전환처럼 visibilitychange + pageshow 가 같은 순간 겹치면 한 번만 동기화한다(디바운스)', () => {
  const { document, window, calls, tick } = setup();
  document.dispatch('visibilitychange');
  window.dispatch('pageshow');
  window.dispatch('online');
  assert.equal(calls.length, 1, '같은 순간의 세 이벤트 → 1회');
  tick(DEFAULT_DEBOUNCE_MS);
  document.dispatch('visibilitychange');
  assert.equal(calls.length, 2, '디바운스가 지나면 다시 부른다');
});

test('숨겨지는 쪽(visibilityState=hidden)의 visibilitychange 는 동기화하지 않는다', () => {
  const { document, calls } = setup();
  document.visibilityState = 'hidden';
  document.dispatch('visibilitychange');
  assert.equal(calls.length, 0);
  document.visibilityState = 'visible';
  document.dispatch('visibilitychange');
  assert.equal(calls.length, 1);
});

test('resume 이 던져도 리스너는 남고, 해제하면 세 리스너가 모두 떨어진다', () => {
  let t = 0;
  let n = 0;
  const document = fakeTarget({ visibilityState: 'visible' });
  const window = fakeTarget();
  const uninstall = installSyncRecovery({ document, window, resume: () => { n += 1; throw new Error('boom'); }, now: () => (t += 5000) });
  assert.doesNotThrow(() => window.dispatch('online'));
  assert.doesNotThrow(() => window.dispatch('pageshow'));
  assert.equal(n, 2);
  uninstall();
  assert.equal(document.count('visibilitychange'), 0);
  assert.equal(window.count('online'), 0);
  assert.equal(window.count('pageshow'), 0);
  window.dispatch('online');
  assert.equal(n, 2, '해제 뒤에는 부르지 않는다');
});
