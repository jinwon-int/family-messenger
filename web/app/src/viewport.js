// 화면 키보드가 열릴 때 셸 높이를 보이는 영역(visualViewport)에 맞춘다 — 순수 판정 + 설치 함수.
//
// iOS Safari(탭·홈 화면 앱 모두)는 키보드가 올라와도 레이아웃 뷰포트(100dvh)를 줄이지 않는다. 대신
// 보이는 영역(visualViewport)만 줄고, 포커스된 작성창이 보이도록 문서를 스크롤한다. 셸이 100dvh로
// 고정돼 있으면 작성창은 키보드 뒤 자리에 남고 Safari의 스크롤 보정이 키보드와 작성창 사이에
// 큰 여백을 만든다(오너 2026-10-07). visualViewport 높이를 CSS 변수(--shell-height)로 넘겨 셸을
// 그만큼만 쓰게 하고, 키보드가 열린 동안은 html[data-keyboard="open"]으로 안전 영역 여백을 뺀다
// (키보드가 홈 인디케이터를 덮는다). 문서가 밀려 있으면 맨 위로 되돌린다.
//
// 블루투스(외부) 키보드를 쓰면 화면 키보드는 뜨지 않지만 iOS가 작성창 포커스 중 입력 보조 바(↑↓·완료,
// 웹에서는 숨길 수 없다)를 화면 아래에 그리고, 보이는 영역은 그 바 높이(수십 px)만큼만 준다. 키보드 임계
// (120px)에 못 미쳐 셸이 안 줄면 바가 작성창을 가린다(오너 2026-10-07, 홈 화면 앱 + 블루투스 키보드).
// 그래서 바 높이 정도의 작은 감소(BAR_MIN_PX 이상)도 '바' 상태로 보고 그만큼 셸을 줄인다.

/** 키보드가 열렸다고 볼 최소 높이 차(px). 주소창·툴바 변화(수십 px)는 키보드가 아니다. */
export const KEYBOARD_MIN_PX = 120;
/** 입력 보조 바(외부 키보드 연결 시 ↑↓·완료 바)만 보인다고 볼 최소 높이 차(px). 그보다 작은 흔들림은 무시한다. */
export const BAR_MIN_PX = 30;
/** 작성창 포커스 뒤 다시 맞추는 시점(ms) — iOS 키보드 애니메이션(~250ms)과 그 뒤 Safari 스크롤 보정을 덮는다. */
export const SETTLE_DELAYS_MS = Object.freeze([0, 150, 350, 600]);

/**
 * 창 높이와 보이는 영역 높이로 키보드 상태를 판정한다.
 * @param {{innerHeight: number, viewportHeight: number, threshold?: number, barThreshold?: number}} input
 * @returns {{open: boolean, mode: 'keyboard'|'bar'|null, height: number|null}}
 *   open은 화면 키보드 열림, mode는 셸을 줄여야 하는 이유('keyboard' | 외부 키보드의 입력 보조 바 'bar' | 없음),
 *   height는 셸에 줄 높이(px) — 판정 불가면 null
 */
export function keyboardState({ innerHeight, viewportHeight, threshold = KEYBOARD_MIN_PX, barThreshold = BAR_MIN_PX } = {}) {
  if (!Number.isFinite(innerHeight) || !Number.isFinite(viewportHeight) || viewportHeight <= 0) return { open: false, mode: null, height: null };
  const diff = innerHeight - viewportHeight;
  const open = diff >= threshold;
  const mode = open ? 'keyboard' : diff >= barThreshold ? 'bar' : null;
  return { open, mode, height: Math.round(viewportHeight) };
}

/**
 * visualViewport를 따라 문서 루트에 --shell-height와 data-keyboard("open" = 화면 키보드, "bar" = 외부 키보드의
 * 입력 보조 바)를 유지한다. visualViewport가 없는 환경(옛 브라우저·테스트)에서는 아무것도 하지 않는다. 해제 함수를 돌려준다.
 * @param {{win?: Window, doc?: Document, threshold?: number, barThreshold?: number, settleDelays?: readonly number[]}} [options]
 * @returns {() => void}
 */
export function installViewportFit({ win = globalThis.window, doc = globalThis.document, threshold = KEYBOARD_MIN_PX, barThreshold = BAR_MIN_PX, settleDelays = SETTLE_DELAYS_MS } = {}) {
  const viewport = win?.visualViewport;
  const root = doc?.documentElement;
  if (!viewport || !root || typeof viewport.addEventListener !== 'function') return () => {};
  let lastMode = null;
  const apply = () => {
    const { mode, height } = keyboardState({ innerHeight: win.innerHeight, viewportHeight: viewport.height, threshold, barThreshold });
    if (mode && height != null) {
      root.style.setProperty('--shell-height', `${height}px`);
      root.dataset.keyboard = mode === 'keyboard' ? 'open' : 'bar';
      // Safari가 작성창을 보이려고 문서를 밀어 올린 만큼 되돌린다 — 셸이 이미 보이는 영역 높이다.
      if ((viewport.offsetTop ?? 0) > 0 || (win.scrollY ?? 0) > 0) win.scrollTo?.(0, 0);
    } else if (lastMode || root.dataset.keyboard) {
      root.style.removeProperty('--shell-height');
      delete root.dataset.keyboard;
    }
    lastMode = mode;
  };
  // 키보드 애니메이션은 수백 ms — Safari의 문서 밀기가 마지막 resize 뒤에 올 수 있어 포커스 뒤 몇 번 더 맞춘다.
  const timers = new Set();
  const settle = () => {
    for (const ms of settleDelays) {
      const id = setTimeout(() => { timers.delete(id); apply(); }, ms);
      timers.add(id);
    }
  };
  viewport.addEventListener('resize', apply);
  viewport.addEventListener('scroll', apply);
  win.addEventListener?.('scroll', apply);
  doc.addEventListener?.('focusin', settle);
  apply();
  return () => {
    viewport.removeEventListener('resize', apply);
    viewport.removeEventListener('scroll', apply);
    win.removeEventListener?.('scroll', apply);
    doc.removeEventListener?.('focusin', settle);
    for (const id of timers) clearTimeout(id);
    timers.clear();
    root.style.removeProperty('--shell-height');
    delete root.dataset.keyboard;
  };
}
