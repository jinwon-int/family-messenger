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
