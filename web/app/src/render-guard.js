// 백그라운드 재렌더 보류 판정(순수 함수). main.js가 포인터·선택 상태를 모아 넘긴다.
//
// 같은 방을 다시 그리면 타임라인 DOM이 바뀌어, 크롬은 드래그 중이거나 선택해 둔 글자의
// 선택을 버린다(#194 — 드래그 중 재렌더 시 선택이 사라지고, 이어 끌면 대화 맨 위로 튄다).
// 동기화·입력중·상대시간 같은 백그라운드 갱신은 사용자가 글자를 잡고 있는 동안 미룬다.
// 다만 새 메시지가 끝없이 막히지 않도록 보류에는 상한을 둔다.

/** 마우스 버튼을 누르고 있는 동안의 보류 상한. 스크롤바 드래그 뒤 pointerup이 안 올 수 있다. */
export const POINTER_HOLD_MAX_MS = 10_000;
/** 선택해 둔 글자(복사 대기)를 위한 보류 상한. */
export const SELECTION_HOLD_MAX_MS = 5_000;

/**
 * 지금 백그라운드 재렌더를 미뤄야 하는지.
 * @param {{pointerDown?: boolean, selectionActive?: boolean, heldMs?: number}} input
 *   heldMs: 이번 보류가 시작된 뒤 지난 시간(보류 중이 아니면 0)
 * @returns {{hold: boolean, retryInMs: number}} hold=true면 retryInMs 뒤에 다시 판정한다
 */
export function renderHold({ pointerDown = false, selectionActive = false, heldMs = 0 } = {}) {
  const held = Number.isFinite(heldMs) && heldMs > 0 ? heldMs : 0;
  const cap = pointerDown ? POINTER_HOLD_MAX_MS : selectionActive ? SELECTION_HOLD_MAX_MS : 0;
  if (cap === 0 || held >= cap) return { hold: false, retryInMs: 0 };
  return { hold: true, retryInMs: cap - held };
}

/**
 * 선택이 재렌더로 사라지는 영역(타임라인·대화목록) 안에 걸려 있는지.
 * 작성창(textarea) 안의 선택은 작성창이 교체되지 않으므로 해당하지 않는다.
 * @param {Selection|null|undefined} selection
 */
export function selectionInRenderedArea(selection) {
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return false;
  return [selection.anchorNode, selection.focusNode].some((node) => {
    const element = node?.nodeType === 1 ? node : node?.parentElement;
    return Boolean(element?.closest?.('.timeline, .pane-list, .room-screen > .appbar'));
  });
}
