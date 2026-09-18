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
 * 대화목록 ↑/↓ 판정. 방 목록에서 포커스를 한 항목씩 옮긴다(roving focus).
 * 포커스된 항목이 없거나 범위를 벗났으면 ↓는 첫 항목, ↑는 마지막 항목에서 시작한다.
 * @param {{key?: string, count?: number, currentIndex?: number}} input
 * @returns {number|null} 옮길 항목 index — ↑/↓가 아니거나 목록이 비었으면 null
 */
export function listArrowMove({ key, count, currentIndex = -1 } = {}) {
  if (key !== 'ArrowDown' && key !== 'ArrowUp') return null;
  if (!Number.isInteger(count) || count <= 0) return null;
  const delta = key === 'ArrowDown' ? 1 : -1;
  const from = Number.isInteger(currentIndex) && currentIndex >= 0 && currentIndex < count ? currentIndex : -1;
  if (from === -1) return delta > 0 ? 0 : count - 1;
  return Math.min(count - 1, Math.max(0, from + delta));
}

const INTERACTIVE = new Set(['INPUT', 'TEXTAREA', 'BUTTON', 'A', 'SELECT', 'LABEL', 'SUMMARY']);

/**
 * 방 화면 전역 keydown 판정.
 * 대화형 요소 밖 Enter=작성창으로 커서 이동, Esc=방 목록으로 뒤로가기.
 * @returns {'focus-composer'|'back'|null}
 */
export function viewKeyAction({ key, target } = {}) {
  if (key === 'Escape') return 'back';
  if (key !== 'Enter') return null;
  const tag = target?.tagName ?? '';
  if (INTERACTIVE.has(tag) || target?.isContentEditable === true) return null;
  return 'focus-composer';
}
