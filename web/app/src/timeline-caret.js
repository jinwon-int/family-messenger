// 대화 내용 캐럿 모드(#284).
//
// 작성창 End/Esc로 대화 내용(.timeline)에 포커스가 온 뒤 Esc를 한 번 더 누르면, 대화 내용에
// 캐럿(커서)을 두어 Shift+방향키·Shift+Home/End·Ctrl+Shift+←/→로 글자를 블록 선택하고
// Ctrl+C로 복사할 수 있게 한다. 웹페이지는 브라우저 캐럿 브라우징(크롬 F7)을 켤 수 없으므로
// 읽기 전용 contenteditable로 브라우저 기본 캐럿·선택 동작을 빌린다.
//
// 읽기 전용 보장: 편집으로 이어지는 입력(beforeinput — 타이핑·삭제·줄바꿈·서식·실행취소, 그리고
// paste·cut·drop)은 모두 막는다. 취소할 수 없는 IME 조합은 시작되는 즉시 캐럿 모드를 끈다.
// inputmode=none은 휴대폰 가상 키보드가 뜨지 않게 한다.

const modes = new WeakMap();

const BLOCKED_EVENTS = ['beforeinput', 'paste', 'cut', 'drop', 'dragover'];

/** @param {Element|null|undefined} list */
export function isCaretMode(list) {
  return Boolean(list && modes.has(list));
}

/**
 * 캐럿 모드를 켠다. 이미 대화 내용에 선택이 있으면 그 자리를, 없으면 보이는 마지막 말풍선의
 * 본문 시작에 캐럿을 둔다(End로 맨 아래를 보고 있으면 최신 메시지).
 * @param {HTMLElement} list .timeline
 * @returns {boolean} 새로 켰으면 true
 */
export function enterCaretMode(list) {
  if (!list || modes.has(list)) return false;
  const doc = list.ownerDocument;
  list.setAttribute('contenteditable', 'true');
  list.setAttribute('inputmode', 'none');
  list.setAttribute('spellcheck', 'false');
  list.setAttribute('autocorrect', 'off');
  list.setAttribute('autocapitalize', 'off');
  list.dataset.caret = 'on';
  // 리스너는 직접 떼어 낸다(addEventListener signal 옵션은 구형 모바일 브라우저에 없다 — #167 하한).
  const listeners = [
    ...BLOCKED_EVENTS.map((type) => [type, (event) => event.preventDefault()]),
    // IME 조합 입력은 취소가 안 된다 — 글자가 대화 DOM에 들어가기 전에 편집 가능 상태를 푼다.
    // 편집 가능 상태만 풀면 크롬이 조합을 끝내지 않고 붙잡아, 다음 Esc·Enter가 조합 중(isComposing)
    // 으로 먹혀 아무 키도 안 듣는다(PC 크롬 실기기, 한/영=한글). 포커스를 한 번 빼면 브라우저가 조합을
    // 강제로 끝내고 IME를 초기화한다 — 그 뒤 대화 내용(스크롤 모드)으로 포커스를 되돌린다.
    // 크롬은 compositionstart 핸들러가 끝난 뒤에 조합을 만든다 — 핸들러 안에서 바로 빼면 끝낼 조합이
    // 아직 없어 그대로 남는다(CI Chromium 재현). 그래서 다음 태스크로 미룬다.
    ['compositionstart', () => {
      exitCaretMode(list);
      setTimeout(() => {
        if (!list.isConnected || list.ownerDocument.activeElement !== list) return;
        list.blur();
        list.focus({ preventScroll: true });
      }, 0);
    }],
    ['focusout', (event) => {
      const next = event.relatedTarget;
      if (next && list.contains(next)) return;
      // 다른 창으로 전환(복사해서 붙여넣으러 감)은 유지 — 돌아오면 이어서 선택한다.
      if (!next && typeof doc.hasFocus === 'function' && !doc.hasFocus()) return;
      exitCaretMode(list);
    }],
  ];
  for (const [type, listener] of listeners) list.addEventListener(type, listener);
  modes.set(list, listeners);
  if (doc.activeElement !== list) list.focus({ preventScroll: true });
  placeCaret(list);
  return true;
}

/**
 * 캐럿 모드를 끈다(편집 가능 속성 제거). 선택해 둔 글자는 그대로 두어 이어서 복사할 수 있다.
 * @returns {boolean} 켜져 있었으면 true
 */
export function exitCaretMode(list) {
  const listeners = list ? modes.get(list) : null;
  if (!listeners) return false;
  modes.delete(list);
  for (const [type, listener] of listeners) list.removeEventListener(type, listener);
  for (const name of ['contenteditable', 'inputmode', 'spellcheck', 'autocorrect', 'autocapitalize']) list.removeAttribute(name);
  delete list.dataset.caret;
  return true;
}

function placeCaret(list) {
  const selection = list.ownerDocument.getSelection?.();
  if (!selection) return;
  if (selection.rangeCount > 0 && list.contains(selection.anchorNode) && list.contains(selection.focusNode)) return;
  const bubble = lastVisibleBubble(list);
  const target = bubble ? (bubble.querySelector('.body') ?? bubble) : list;
  const text = firstText(target);
  if (text) selection.collapse(text, 0);
  else selection.collapse(target, bubble ? 0 : target.childNodes.length);
}

function lastVisibleBubble(list) {
  const bubbles = [...list.querySelectorAll('li.bubble')];
  const box = list.getBoundingClientRect();
  if (box.height > 0) {
    for (let i = bubbles.length - 1; i >= 0; i--) {
      const rect = bubbles[i].getBoundingClientRect();
      if (rect.top < box.bottom && rect.bottom > box.top) return bubbles[i];
    }
  }
  return bubbles[bubbles.length - 1] ?? null;
}

function firstText(node) {
  const walker = node.ownerDocument.createTreeWalker(node, 4 /* NodeFilter.SHOW_TEXT */);
  for (let current = walker.nextNode(); current; current = walker.nextNode()) {
    if (current.nodeValue.trim() !== '') return current;
  }
  return null;
}
