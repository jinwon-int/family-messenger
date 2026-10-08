// Short Authentication String (emoji) verification flow.
//
// The SDK (matrix-js-sdk rust crypto) supplies the emoji list for a SAS
// verification; this module owns only the product state machine and the
// Korean labels. We do not hardcode the spec's 64-emoji table here — the
// SDK event is the source of truth, and unknown glyphs fall back to the
// SDK-provided English description.

export const VerificationState = Object.freeze({
  idle: 'idle',
  requested: 'requested',
  ready: 'ready',
  waiting: 'waiting',
  matched: 'matched',
  mismatched: 'mismatched',
  cancelled: 'cancelled',
});

const TERMINAL = new Set([VerificationState.matched, VerificationState.mismatched, VerificationState.cancelled]);

/**
 * Pure transition for the device-verification sheet.
 * @param {{state: string, emojis?: object[]}} current
 * @param {{type: 'request'|'ready'|'accept'|'confirm'|'mismatch'|'cancel', emojis?: object[]}} action
 * @returns {{state: string, emojis?: object[], error?: string}}
 */
export function transition(current, action) {
  const state = current?.state ?? VerificationState.idle;
  if (TERMINAL.has(state)) return current;
  switch (action.type) {
    case 'request':
      if (state !== VerificationState.idle) return { ...current, error: 'request' };
      return { state: VerificationState.requested };
    case 'ready': {
      if (state !== VerificationState.requested) return { ...current, error: 'ready' };
      const emojis = Array.isArray(action.emojis) ? action.emojis : [];
      if (emojis.length === 0) return { ...current, error: 'ready' };
      return { state: VerificationState.ready, emojis };
    }
    case 'accept':
      // The local user compared the emoji list and confirmed; now the
      // remote device must accept too.
      if (state !== VerificationState.ready) return { ...current, error: 'accept' };
      return { state: VerificationState.waiting, emojis: current.emojis };
    case 'confirm':
      if (state !== VerificationState.waiting) return { ...current, error: 'confirm' };
      return { state: VerificationState.matched };
    case 'mismatch':
      if (state !== VerificationState.ready && state !== VerificationState.waiting) {
        return { ...current, error: 'mismatch' };
      }
      return { state: VerificationState.mismatched };
    case 'cancel':
      return { state: VerificationState.cancelled };
    default:
      return { ...current, error: 'unknown-action' };
  }
}

/** Korean labels for the spec's SAS emoji, keyed by the glyph itself. */
export const EMOJI_KO = Object.freeze({
  '🐶': '강아지',
  '🐱': '고양이',
  '🐴': '말',
  '🦄': '유니콘',
  '🐖': '돼지',
  '🐙': '문어',
  '🕷️': '거미',
  '🦋': '나비',
  '🌷': '꽃',
  '🌲': '나무',
  '🌵': '선인장',
  '🍄': '버섯',
  '🌏': '지구',
  '🌙': '달',
  '☁️': '구름',
  '🔥': '불',
  '🍌': '바나나',
  '🍎': '사과',
  '🍓': '딸기',
  '🌽': '옥수수',
  '🥕': '당근',
  '🍅': '토마토',
  '🏠': '집',
  '🏢': '건물',
  '🚓': '경찰차',
  '✈️': '비행기',
  '⏰': '시계',
  '⌚': '손목시계',
});

/**
 * Localized label for one SDK emoji. matrix-js-sdk maps SAS emojis as
 * `[emoji, name]` tuples; object shapes are accepted too. Falls back to
 * the SDK's description, then the raw glyph — a label is always a
 * non-empty string so the compare list never shows a blank row.
 * @param {[string, string?] | {emoji: string, name?: string}} emoji
 * @returns {string}
 */
export function emojiLabel(emoji) {
  let glyph;
  let fallback;
  if (Array.isArray(emoji)) {
    [glyph, fallback] = emoji;
  } else if (emoji && typeof emoji.emoji === 'string') {
    glyph = emoji.emoji;
    fallback = emoji.name;
  }
  if (typeof glyph !== 'string') return '';
  return EMOJI_KO[glyph] ?? (typeof fallback === 'string' && fallback.length > 0 ? fallback : glyph);
}

/**
 * 들어온 기기 검증 요청을 어떻게 다룰지 (#331).
 *
 * 2026-10-08: 아이폰 홈 화면 앱에서 메뉴·기기 목록 시트를 열어 둔 채 다른 기기가 검증을
 * 요청하면 `dialog[open]` 가드가 요청을 조용히 버렸고, 사람은 "안 뜬다"만 봤다.
 *   - 시트가 없으면 바로 연다(open).
 *   - 메뉴 시트면 닫고 연다(closeMenu) — 메뉴는 잃을 상태가 없다.
 *   - 그 밖의 시트(기기 목록·복구·진행 중인 검증 등)는 보관했다가 닫힐 때 연다(hold).
 */
export const IncomingAction = Object.freeze({ open: 'open', closeMenu: 'closeMenu', hold: 'hold' });

/** @param {{classList?: {contains(name: string): boolean}} | null | undefined} openDialog */
export function classifyIncoming(openDialog) {
  if (!openDialog) return IncomingAction.open;
  if (openDialog.classList?.contains?.('menu')) return IncomingAction.closeMenu;
  return IncomingAction.hold;
}

// matrix/client.js VERIFICATION_PHASE 와 같은 값. 이 모듈은 SDK 를 끌어오지 않으므로 숫자만 둔다.
const PHASE_CANCELLED = 5;
const PHASE_DONE = 6;

/**
 * 요청이 아직 수락할 수 있는 상태인지. SDK 의 VerificationRequest 는 끝나면 `pending === false`
 * 이고 phase 가 Cancelled/Done 이 된다. 둘 다 없으면(스텁) 살아 있다고 본다.
 */
export function isRequestPending(request) {
  if (!request) return false;
  if (request.pending === false) return false;
  if (request.phase === PHASE_CANCELLED || request.phase === PHASE_DONE) return false;
  return true;
}

/**
 * 보관함: 시트가 닫힐 때 `take()` 로 꺼내 연다. 그 사이 만료·취소된 요청은 버린다.
 * 나중 요청이 먼저 것을 덮는다 — 같은 기기의 재요청이 보통이고, 오래된 요청은 어차피 만료된다.
 */
export function createIncomingHolder() {
  let held = null;
  return {
    hold(request) {
      held = request;
    },
    has() {
      return held != null;
    },
    take() {
      const request = held;
      held = null;
      return isRequestPending(request) ? request : null;
    },
    clear() {
      held = null;
    },
  };
}
