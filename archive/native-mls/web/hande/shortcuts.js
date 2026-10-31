// 전역 키보드 단축키 — 패밀리챗 web/app/src/main.js 의 installRoomListKeyboardNav /
// installKeyboardShortcuts 이식(#478). 판정은 keyboard.js(순수 함수), 캐럿 모드는 timeline-caret.js.
//
// document 수준 위임을 쓰는 이유: 한데의 목록 pane 은 동기화마다 통째로 교체되고(ui.js updateListPane)
// 방 pane 도 방을 바꾸면 교체된다 — 요소에 직접 붙인 리스너는 그때마다 사라진다.
//
// 공통 가드(패밀리챗과 같음): 이미 defaultPrevented 인 이벤트, 시트(dialog[open])가 떠 있을 때,
// IME 조합 중(isComposing / keyCode 229)은 가로채지 않는다 — 단 편집할 수 없는 대화 내용(스크롤 모드)
// 에서의 Esc·Enter 는 조합 중이어도 처리한다(캐럿 모드에서 한글을 쳐서 풀린 뒤 브라우저에 조합이
// 남는 PC 크롬 실기기 문제, 패밀리챗 #284 후속).
import {
  isSplitLayout, listPageMove, listPageNavAction, listRevealDelta, timelineKeyAction, viewKeyAction,
  TIMELINE_ARROW_STEP_PX,
} from './keyboard.js';
import { enterCaretMode, exitCaretMode, isCaretMode } from './timeline-caret.js';
import { choiceKeyAction, choiceKeyInput } from './agent-choices.js';

const EDITABLE_TAGS = new Set(['INPUT', 'TEXTAREA', 'SELECT']);

/**
 * @param {HTMLElement} root  앱 루트(#app)
 * @param {{
 *   openRoom: (roomId: string) => void,      // 방을 연다(작성창에 커서 — ui.renderShell mount)
 *   openRooms: () => void,                   // 방 화면 → 목록(초안은 app 이 방별로 보존)
 *   currentRoomId: () => string|null,        // 열린 방이 없으면 null
 *   orderEditing?: () => boolean,            // 순서 편집 중이면 Page Up/Down 으로 방을 열지 않는다
 *   openChoiceCard?: () => ({card: () => {count: number, selected: number[], enabled: boolean}, toggle: (n: number) => void, submit: () => void}|null),
 *                                            // 열린 방의 open 선택지 카드 조작(#629, ui.openChoiceCard) — 없으면 null
 *   document?: Document, matchMedia?: (q: string) => {matches?: boolean}|null,
 * }} actions
 * @returns {() => void} 해제 함수
 */
export function installShortcuts(root, actions) {
  const doc = actions.document ?? root.ownerDocument ?? document;
  const matchMedia = actions.matchMedia ?? ((query) => doc.defaultView?.matchMedia?.(query));
  const state = { listFocusRoomId: null };

  const splitLayout = () => isSplitLayout(matchMedia);
  const listRoomButtons = () => Array.from(root.querySelectorAll('.pane-list button.room-item'));
  const sheetOpen = () => Boolean(root.querySelector('dialog[open]'));

  /** Page Up/Down 으로 옮겨간 방 행이 목록 스크롤 영역 밖일 때만 목록을 그 행까지 스크롤한다. */
  function revealRoomInList(roomId) {
    const button = listRoomButtons().find((candidate) => candidate.dataset.roomId === roomId);
    const pane = button?.closest('.pane-list');
    if (!button || !pane || typeof button.getBoundingClientRect !== 'function' || typeof pane.getBoundingClientRect !== 'function') return;
    const item = button.getBoundingClientRect();
    const view = pane.getBoundingClientRect();
    const delta = listRevealDelta({ itemTop: item.top, itemBottom: item.bottom, viewTop: view.top, viewBottom: view.bottom });
    if (delta !== 0) pane.scrollTop += delta;
  }

  function currentListIndex(buttons) {
    const focused = buttons.indexOf(doc.activeElement);
    if (focused >= 0) return focused;
    const id = state.listFocusRoomId || actions.currentRoomId();
    return id ? buttons.findIndex((button) => button.dataset.roomId === id) : -1;
  }

  // 대화목록 Page Up/Page Down 탐색(roving focus / 2분할 미리보기 / 단일 pane 방 전환).
  function onListNav(event) {
    if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return;
    const shell = root.querySelector('main.shell');
    if (!shell || sheetOpen()) return;
    // 순서 편집 중에는 Page Up/Down 으로 방을 열지 않는다(행을 눌러도 안 열리는 것과 같게, #480 A).
    if (actions.orderEditing?.()) return;
    const target = event.target;
    // 대화 내용 캐럿 모드: Page Up/Down 은 캐럿 이동·Shift 선택이다 — 방을 넘기지 않는다.
    if (isCaretMode(target)) return;
    const composerFocused = Boolean(target && (target.isContentEditable === true || EDITABLE_TAGS.has(target.tagName)));
    const action = listPageNavAction({ key: event.key, split: splitLayout(), view: shell.dataset.view, composerFocused });
    if (!action) return;
    const buttons = listRoomButtons();
    const next = listPageMove({ key: event.key, count: buttons.length, currentIndex: currentListIndex(buttons) });
    if (next === null) return;
    event.preventDefault(); // 화면 스크롤 대신 목록 이동으로 쓴다
    const nextRoomId = buttons[next].dataset.roomId;
    if (action === 'switch') {
      // 단일 pane 방 화면: 목록 순서대로 이전/다음 방을 바로 연다. 첫·마지막 방에서는 제자리.
      if (nextRoomId !== actions.currentRoomId()) actions.openRoom(nextRoomId);
      return;
    }
    state.listFocusRoomId = nextRoomId;
    if (action === 'preview') {
      // 2분할: 오른쪽에 바로 열고 작성창에 커서. 옮겨간 행이 가려져 있을 때만 목록을 따라 내린다.
      actions.openRoom(nextRoomId);
      revealRoomInList(nextRoomId);
      return;
    }
    // 단일 pane 목록: 포커스만 옮긴다(열지 않는다).
    buttons[next].focus({ preventScroll: true });
    revealRoomInList(nextRoomId);
  }

  // 방 화면 단축키: 작성창 Esc·End → 대화 내용, 대화 내용 ↑/↓ 스크롤·Esc 캐럿 모드, 대화형 요소 밖 Enter → 작성창, Home → 목록.
  function onRoomKeys(event) {
    if (event.defaultPrevented) return;
    const composing = event.isComposing || event.keyCode === 229;
    const plainTimeline = event.target?.classList?.contains('timeline') && !event.target.isContentEditable;
    if (composing && !(plainTimeline && (event.key === 'Escape' || event.key === 'Enter'))) return;
    if (!actions.currentRoomId()) return;
    if (sheetOpen()) return;
    const list = root.querySelector('.room-screen .timeline');
    const input = root.querySelector('.room-screen form.composer textarea[name=body]');
    const onTimeline = Boolean(list) && event.target === list;
    const caretMode = onTimeline && isCaretMode(list);
    const readAction = timelineKeyAction({
      key: event.key,
      inComposer: Boolean(input) && event.target === input,
      onTimeline,
      caretMode,
      shiftKey: event.shiftKey,
      ctrlKey: event.ctrlKey,
      altKey: event.altKey,
      metaKey: event.metaKey,
    });
    if (readAction && list) {
      event.preventDefault();
      if (readAction === 'focus-timeline') list.focus({ preventScroll: true });
      else if (readAction === 'enter-caret') enterCaretMode(list);
      else if (readAction === 'exit-caret') {
        exitCaretMode(list);
        if (doc.activeElement !== list) list.focus({ preventScroll: true });
      } else if (readAction === 'focus-composer') {
        exitCaretMode(list);
        input?.focus();
      } else list.scrollBy({ top: readAction === 'scroll-up' ? -TIMELINE_ARROW_STEP_PX : TIMELINE_ARROW_STEP_PX });
      return;
    }
    // 캐럿 모드의 나머지 키(방향키·Home/End·Shift 조합)는 브라우저 기본 — Home(목록) 등으로 넘기지 않는다.
    if (caretMode) return;
    const action = viewKeyAction({ key: event.key, target: event.target });
    if (!action) return;
    if (action === 'back') {
      event.preventDefault();
      actions.openRooms();
      return;
    }
    if (input && doc.activeElement !== input && !input.disabled) {
      event.preventDefault();
      input.focus();
    }
  }

  // 선택지 카드 단축키(#629, AGENT-CHOICES-V1.md §3.1): ⌥1~9 체크 토글 · ⌥Enter 보내기. 판정은 agent-choices.js choiceKeyAction.
  // document **캡처** 단계에 붙인다 — 작성창 textarea 의 Enter 전송(ui.js buildComposer, 대상 단계)보다 먼저 돌아야
  // ⌥Enter 가 작성창 글을 보내지 않는다. 가로챈 키만 preventDefault + stopPropagation(작성창·onRoomKeys 로 가지 않음),
  // null 이면 아무것도 하지 않아 기존 동작(⌥+숫자 특수문자 입력·Enter 규칙) 그대로.
  function onChoiceKeys(event) {
    if (event.defaultPrevented || !event.altKey) return;
    if (!actions.currentRoomId() || sheetOpen()) return;
    const controls = actions.openChoiceCard?.() ?? null;
    const action = choiceKeyAction(choiceKeyInput(event), controls ? controls.card() : null);
    if (!action) return;
    event.preventDefault();
    event.stopPropagation();
    if (action.action === 'toggle') controls.toggle(action.number);
    else controls.submit();
  }

  doc.addEventListener('keydown', onChoiceKeys, true);
  doc.addEventListener('keydown', onListNav);
  doc.addEventListener('keydown', onRoomKeys);
  return () => {
    doc.removeEventListener('keydown', onChoiceKeys, true);
    doc.removeEventListener('keydown', onListNav);
    doc.removeEventListener('keydown', onRoomKeys);
  };
}
