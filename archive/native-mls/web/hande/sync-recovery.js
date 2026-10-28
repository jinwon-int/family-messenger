// 탭 복귀·온라인 복귀 즉시 동기화(#544 A) — 패밀리챗 web/app main.js installSyncRecovery 이식.
// 백그라운드 탭에서는 브라우저가 타이머(방 폴링 4초·기기 틱 8초)를 늦추므로, 돌아온 직후 몇 초~수십 초 낡은 화면이
// 보인다. `visibilitychange`(보이게 될 때만)·`online`·`pageshow`(bfcache 복귀)에서 resume 을 한 번 부른다.
// 세 이벤트는 같은 순간에 겹쳐 오기 쉬워(탭 전환 = visibilitychange + pageshow) 짧은 디바운스로 한 번만 실행한다.
// 순수 모듈: document/window 를 주입받아 node:test 로 검증한다(tests/sync-recovery.test.mjs).

export const RESUME_EVENTS = Object.freeze(['visibilitychange', 'online', 'pageshow']);
export const DEFAULT_DEBOUNCE_MS = 1000;

/**
 * 이번 이벤트에서 resume 을 부를지 — 숨겨진 탭은 건너뛰고, 직전 실행에서 debounceMs 안이면 건너뛴다.
 * @param {{lastAt: number}} state  마지막 실행 시각(ms, 0 = 아직 없음)
 * @param {{hidden: boolean, now: number, debounceMs: number}} ctx
 */
export function shouldResume(state, { hidden, now, debounceMs = DEFAULT_DEBOUNCE_MS }) {
  if (hidden) return false;
  if (state.lastAt && now - state.lastAt < debounceMs) return false;
  return true;
}

/**
 * @param {object} deps
 * @param {EventTarget & {visibilityState?: string}} deps.document
 * @param {EventTarget} deps.window
 * @param {() => void} deps.resume  동기화 경로(app.js: refresh + 방별 sync) — 던져도 리스너는 남는다
 * @param {number} [deps.debounceMs]
 * @param {() => number} [deps.now]
 * @returns {() => void} 해제 함수
 */
export function installSyncRecovery({ document, window, resume, debounceMs = DEFAULT_DEBOUNCE_MS, now = Date.now }) {
  const state = { lastAt: 0 };
  const handler = () => {
    const at = now();
    if (!shouldResume(state, { hidden: document.visibilityState === 'hidden', now: at, debounceMs })) return;
    state.lastAt = at;
    try { resume(); } catch (_) { /* 동기화 실패는 app.js 가 상태줄·로그로 알린다 */ }
  };
  document.addEventListener('visibilitychange', handler);
  for (const name of RESUME_EVENTS) if (name !== 'visibilitychange') window.addEventListener(name, handler);
  return () => {
    document.removeEventListener('visibilitychange', handler);
    for (const name of RESUME_EVENTS) if (name !== 'visibilitychange') window.removeEventListener(name, handler);
  };
}
