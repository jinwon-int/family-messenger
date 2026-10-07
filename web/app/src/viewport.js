// 화면 키보드가 열릴 때 셸 높이를 보이는 영역(visualViewport)에 맞춘다 — 순수 판정 + 설치 함수.
//
// iOS Safari(탭·홈 화면 앱 모두)는 키보드가 올라와도 레이아웃 뷰포트(100dvh)를 줄이지 않는다. 대신
// 보이는 영역(visualViewport)만 줄고, 포커스된 작성창이 보이도록 문서를 스크롤한다. 셸이 100dvh로
// 고정돼 있으면 작성창은 키보드 뒤 자리에 남고 Safari의 스크롤 보정이 키보드와 작성창 사이에
// 큰 여백을 만든다(오너 2026-10-07). visualViewport 높이를 CSS 변수(--shell-height)로 넘겨 셸을
// 그만큼만 쓰게 하고, 키보드가 열린 동안은 html[data-keyboard="open"]으로 안전 영역 여백을 뺀다
// (키보드가 홈 인디케이터를 덮는다). 문서가 밀려 있으면 맨 위로 되돌린다.

/** 키보드가 열렸다고 볼 최소 높이 차(px). 주소창·툴바 변화(수십 px)는 키보드가 아니다. */
export const KEYBOARD_MIN_PX = 120;

/**
 * 창 높이와 보이는 영역 높이로 키보드 상태를 판정한다.
 * @param {{innerHeight: number, viewportHeight: number, threshold?: number}} input
 * @returns {{open: boolean, height: number|null}} height는 셸에 줄 높이(px) — 판정 불가면 null
 */
export function keyboardState({ innerHeight, viewportHeight, threshold = KEYBOARD_MIN_PX } = {}) {
  if (!Number.isFinite(innerHeight) || !Number.isFinite(viewportHeight) || viewportHeight <= 0) return { open: false, height: null };
  const open = innerHeight - viewportHeight >= threshold;
  return { open, height: Math.round(viewportHeight) };
}

/**
 * visualViewport를 따라 문서 루트에 --shell-height와 data-keyboard를 유지한다. visualViewport가 없는
 * 환경(옛 브라우저·테스트)에서는 아무것도 하지 않는다. 해제 함수를 돌려준다.
 * @param {{win?: Window, doc?: Document, threshold?: number}} [options]
 * @returns {() => void}
 */
export function installViewportFit({ win = globalThis.window, doc = globalThis.document, threshold = KEYBOARD_MIN_PX } = {}) {
  const viewport = win?.visualViewport;
  const root = doc?.documentElement;
  if (!viewport || !root || typeof viewport.addEventListener !== 'function') return () => {};
  let lastOpen = false;
  const apply = () => {
    const { open, height } = keyboardState({ innerHeight: win.innerHeight, viewportHeight: viewport.height, threshold });
    if (open && height != null) {
      root.style.setProperty('--shell-height', `${height}px`);
      root.dataset.keyboard = 'open';
      // Safari가 작성창을 보이려고 문서를 밀어 올린 만큼 되돌린다 — 셸이 이미 보이는 영역 높이다.
      if ((viewport.offsetTop ?? 0) > 0 || (win.scrollY ?? 0) > 0) win.scrollTo?.(0, 0);
    } else if (lastOpen || root.dataset.keyboard) {
      root.style.removeProperty('--shell-height');
      delete root.dataset.keyboard;
    }
    lastOpen = open;
  };
  viewport.addEventListener('resize', apply);
  viewport.addEventListener('scroll', apply);
  apply();
  return () => {
    viewport.removeEventListener('resize', apply);
    viewport.removeEventListener('scroll', apply);
    root.style.removeProperty('--shell-height');
    delete root.dataset.keyboard;
  };
}
