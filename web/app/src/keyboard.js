// 키보드 동작 규칙(순수 함수). ui.js의 이벤트 핸들러는 여기 판정만 받아 쓴다.

/**
 * 작성창(textarea) keydown 판정.
 * Enter=전송, Shift+Enter=줄바꿈. 한글 등 IME 조합을 확정하는 Enter는 무시한다
 * (조합 중 전송은 글자가 잘리는 오전송이 된다).
 * @returns {'send'|'newline'|null}
 */
export function composerKeyAction({ key, shiftKey, isComposing } = {}) {
  if (key !== 'Enter') return null;
  if (shiftKey) return 'newline';
  if (isComposing) return null;
  return 'send';
}

// Enter 활성화가 의미 있는 대화형 요소 — 이 위의 Enter는 뺏지 않는다.
/**
 * 대화목록 Page Up/Page Down 판정. 방 목록에서 포커스를 한 항목씩 옮긴다(roving focus).
 * 포커스된 항목이 없거나 범위를 벗났으면 Page Down은 첫 항목, Page Up은 마지막 항목에서 시작한다.
 * @param {{key?: string, count?: number, currentIndex?: number}} input
 * @returns {number|null} 옮길 항목 index — Page Up/Page Down 키가 아니거나 목록이 비었으면 null
 */
export function listPageMove({ key, count, currentIndex = -1 } = {}) {
  if (key !== 'PageDown' && key !== 'PageUp') return null;
  if (!Number.isInteger(count) || count <= 0) return null;
  const delta = key === 'PageDown' ? 1 : -1;
  const from = Number.isInteger(currentIndex) && currentIndex >= 0 && currentIndex < count ? currentIndex : -1;
  if (from === -1) return delta > 0 ? 0 : count - 1;
  return Math.min(count - 1, Math.max(0, from + delta));
}

// styles.css와 같은 미디어 쿼리 — 900px부터 2열, 휴대폰 가로(640~899)도 목록|대화.
const SPLIT_WIDE = '(min-width: 900px)';
const SPLIT_LANDSCAPE = '(orientation: landscape) and (min-width: 640px) and (max-width: 899px)';

/**
 * 목록|대화가 나란히 보이는 2분할인지. 휴대폰 세로(한 pane)에서는 Page Up/Down이
 * 방을 바로 열면 목록이 가려지므로 미리보기를 켜지 않는다.
 * @param {(query: string) => {matches?: boolean}|null|undefined} matchMedia
 */
export function isSplitLayout(matchMedia) {
  if (typeof matchMedia !== 'function') return false;
  return Boolean(matchMedia(SPLIT_WIDE)?.matches) || Boolean(matchMedia(SPLIT_LANDSCAPE)?.matches);
}

/**
 * Page Up/Page Down 전역 판정.
 * 2분할이면 방을 오른쪽에 바로 미리 본다(작성창 포커스는 두지 않는다).
 * 단일 pane 목록에서는 포커스만 옮긴다. 작성 중이거나 방 화면이면 가로채지 않는다.
 * @returns {'preview'|'navigate'|null}
 */
export function listPageNavAction({ key, split, view, composerFocused } = {}) {
  if (key !== 'PageDown' && key !== 'PageUp') return null;
  if (split && (view === 'list' || view === 'room')) return 'preview';
  if (!split && view === 'list' && !composerFocused) return 'navigate';
  return null;
}

const INTERACTIVE = new Set(['INPUT', 'TEXTAREA', 'BUTTON', 'A', 'SELECT', 'LABEL', 'SUMMARY']);

/**
 * 방 화면 전역 keydown 판정.
 * 대화형 요소 밖 Enter=작성창으로 커서 이동, Home=방 목록으로 뒤로가기.
 * @returns {'focus-composer'|'back'|null}
 */
export function viewKeyAction({ key, target } = {}) {
  if (key === 'Home') return 'back';
  if (key !== 'Enter') return null;
  const tag = target?.tagName ?? '';
  if (INTERACTIVE.has(tag) || target?.isContentEditable === true) return null;
  return 'focus-composer';
}
