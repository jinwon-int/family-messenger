// 화면 테마(한데 디자인 1차, docs/design/HANDE-DESIGN-SYSTEM.md §1): 밤(기본·고정) · 낮불(e-ink·밝은 곳) · 시스템 따라가기.
// 밤이 기본이고 시스템 라이트 모드를 따라가지 않는다 — 「시스템 따라가기」를 골랐을 때만 prefers-color-scheme 을 본다.
// 순수 모듈(DOM 은 applyTheme 에서만, 인자로 받는다): localStorage `hande:theme` = night | day | auto, 없으면 night.
// CSS 는 html[data-theme="day"] 와 html[data-theme="auto"] + (prefers-color-scheme: light) 에서 낮불 토큰을 켠다(styles.css).

export const THEME_KEY = 'hande:theme';
export const THEMES = ['night', 'day', 'auto'];
export const DEFAULT_THEME = 'night';
/** <meta name="theme-color"> — 밤 bgTop / 낮불 종이(hande-tokens.json). */
export const THEME_COLORS = { night: '#0F1324', day: '#F7F3EA' };

/** 저장된 선택을 읽는다. 모르는 값·막힌 저장소는 기본(밤). */
export function readTheme(storage) {
  try {
    const value = storage?.getItem?.(THEME_KEY);
    return THEMES.includes(value) ? value : DEFAULT_THEME;
  } catch (_) { return DEFAULT_THEME; }
}

/** 선택을 저장한다. 기본(밤)은 키를 지운다 — 「이 기기 지우기」와 같은 hande:* 정리와 결이 맞게. */
export function writeTheme(storage, value) {
  const next = THEMES.includes(value) ? value : DEFAULT_THEME;
  try {
    if (next === DEFAULT_THEME) storage?.removeItem?.(THEME_KEY);
    else storage?.setItem?.(THEME_KEY, next);
  } catch (_) { /* 저장소가 막혀 있어도 이번 화면에는 적용된다 */ }
  return next;
}

/** 실제로 그릴 테마: auto 는 시스템 라이트면 day, 아니면 night. */
export function resolveTheme(value, systemLight = false) {
  if (value === 'day') return 'day';
  if (value === 'auto') return systemLight ? 'day' : 'night';
  return 'night';
}

/**
 * <html data-theme> 과 theme-color 메타를 맞춘다. auto 는 CSS 미디어 쿼리가 결정하므로 속성값은 'auto' 그대로 두고,
 * 메타 색만 지금 시스템 값으로 고른다(바뀌면 다시 부른다).
 * @param {string} value night|day|auto
 * @param {{documentElement: {dataset: object}, querySelector: Function}} doc document
 * @param {boolean} systemLight matchMedia('(prefers-color-scheme: light)').matches
 */
export function applyTheme(value, doc, systemLight = false) {
  const theme = THEMES.includes(value) ? value : DEFAULT_THEME;
  doc.documentElement.dataset.theme = theme;
  const meta = doc.querySelector?.('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', THEME_COLORS[resolveTheme(theme, systemLight)]);
  return theme;
}

/**
 * 시작 때 한 번: 저장된 선택을 적용하고, 「시스템 따라가기」면 시스템이 바뀔 때 메타 색을 따라 바꾼다.
 * 돌려주는 set(value) 로 설정 시트가 바꾼다. 브라우저 전용(window·document).
 */
export function installTheme({ storage = globalThis.localStorage, doc = globalThis.document, win = globalThis.window } = {}) {
  const media = typeof win?.matchMedia === 'function' ? win.matchMedia('(prefers-color-scheme: light)') : null;
  const systemLight = () => Boolean(media?.matches);
  let current = readTheme(storage);
  applyTheme(current, doc, systemLight());
  media?.addEventListener?.('change', () => { if (current === 'auto') applyTheme(current, doc, systemLight()); });
  return {
    get: () => current,
    set: (value) => { current = writeTheme(storage, value); applyTheme(current, doc, systemLight()); return current; },
  };
}
