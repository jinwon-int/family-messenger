// 대화창 상단 "내 마지막 말" 바 — 패밀리챗 web/app/src/last-sent.js 이식(#480 C). DOM 없이 테스트하는 순수 로직.
//
// 기준은 화면의 방 타임라인(app.js R.entries: key·isMe·kind·body·ts)이다. 패밀리챗은 서버 sender 인덱스를
// 더해 합치지만 한데 릴레이에는 그런 조회가 없고 봉인 보관 이력이 전부 로컬에 있으므로 타임라인만 본다.
// 시스템 행·복호화 실패 행은 "내 말"로 치지 않는다.

const SPOKEN_KINDS = new Set(['text', 'attachment']);

function isSpoken(entry) {
  return Boolean(entry) && SPOKEN_KINDS.has(entry.kind);
}

function previewOf(entry, labels) {
  if (entry.kind === 'attachment') return entry.image ? labels.photo : labels.file;
  const text = String(entry.body ?? '').replace(/\s+/g, ' ').trim();
  return text;
}

function summarize(entry, text, replies) {
  return {
    key: typeof entry.key === 'string' ? entry.key : null,
    text,
    ts: Number.isFinite(entry.ts) ? entry.ts : null,
    replies,
  };
}

/**
 * 내가 보낸 마지막 메시지와 그 위치. 없으면 null.
 * @param {Array<object>|null|undefined} timeline
 * @returns {{entry: object, index: number}|null}
 */
export function lastSentEntry(timeline) {
  if (!Array.isArray(timeline)) return null;
  for (let i = timeline.length - 1; i >= 0; i--) {
    const entry = timeline[i];
    if (entry?.isMe && isSpoken(entry)) return { entry, index: i };
  }
  return null;
}

/**
 * 내가 보낸 최근 메시지 요약을 최신순으로 최대 `limit`개. 각 항목의 답장 수는 그 말 뒤부터 **다음 내 말 전까지**
 * 남이 쓴 메시지 수 — 가장 최근 항목은 끝까지 센다. 미리보기가 비는 내 말은 목록에도 경계에도 넣지 않는다.
 * @param {Array<object>|null|undefined} timeline
 * `minimum`(기본 1)개까지는 날짜와 무관하게 넣고, 그 뒤로는 `sinceTs` 이후 것만 — 첫 항목(바 본문)은 언제나 들어간다.
 * @param {{labels: {photo: string, file: string}, limit?: number, sinceTs?: number, minimum?: number}} options
 * @returns {Array<{key: string|null, text: string, ts: number|null, replies: number}>}
 */
export function recentSentSummaries(timeline, { labels, limit = 50, sinceTs = 0, minimum = 1 } = {}) {
  if (!Array.isArray(timeline) || !Number.isInteger(limit) || limit <= 0) return [];
  const atLeast = Math.min(limit, Math.max(1, Number.isInteger(minimum) ? minimum : 1));
  const out = [];
  let replies = 0;
  for (let i = timeline.length - 1; i >= 0 && out.length < limit; i--) {
    const entry = timeline[i];
    if (!isSpoken(entry)) continue;
    if (!entry.isMe) { replies += 1; continue; }
    const text = previewOf(entry, labels);
    if (!text) continue;
    // 앞의 atLeast 개(첫 항목 = 바 본문 포함)는 날짜와 무관, 그 뒤로는 sinceTs 이후만.
    if (out.length >= atLeast && (entry.ts ?? 0) < sinceTs) break;
    out.push(summarize(entry, text, replies));
    replies = 0;
  }
  return out;
}

/** 펼친 목록에 기본으로 채우는 이전 내 말 수(오너 2026-11-01 「과거에 쓴 말 10개 이상」 — iOS LastSent.earlierMinimum 과 같다). */
export const EARLIER_MINIMUM = 10;

/**
 * 바에 그릴 것: 가장 최근 내 말(lastSent)과 그 이전 내 말(earlierSent). 없으면 lastSent null.
 * earlierSent = 오늘 내 말 전부(최대 limit) — 오늘 말이 `minimum` 개보다 적으면 지난 날 말로 `minimum` 개까지 채운다
 * (오늘만 보이던 때는 아침에 한 말이 없으면 빈 목록이었다). `minimum: 0` = 예전 규칙(오늘 것만).
 * @param {Array<object>|null|undefined} timeline
 * @param {{labels: {photo: string, file: string}, now?: number, limit?: number, minimum?: number}} options
 */
export function lastSentView(timeline, { labels, now = Date.now(), limit = 50, minimum = EARLIER_MINIMUM } = {}) {
  const earlierFloor = Math.max(0, Number.isInteger(minimum) ? minimum : EARLIER_MINIMUM);
  const items = recentSentSummaries(timeline, { labels, limit: limit + 1, sinceTs: dayStart(now), minimum: 1 + earlierFloor });
  return { lastSent: items[0] ?? null, earlierSent: items.slice(1, limit + 1) };
}

/**
 * 펼친 목록 시각 앞에 붙일 날짜: 오늘 = '' · 어제 = labels.yesterday · 그 전 = `M.D.`(목록 relativeTime 과 같은 모양).
 * 지난 날 말이 오늘 말 아래에 섞이므로 시각만으로는 구별되지 않는다.
 * @param {number|null|undefined} ts
 * @param {{now?: number, yesterday?: string}} [options]
 */
export function sentDayPrefix(ts, { now = Date.now(), yesterday = '어제' } = {}) {
  if (!Number.isFinite(ts) || ts <= 0) return '';
  const today = dayStart(now);
  if (ts >= today) return '';
  if (ts >= dayStart(today - 1)) return yesterday;
  const d = new Date(ts);
  return `${d.getMonth() + 1}.${d.getDate()}.`;
}

/**
 * 기기 시간 기준 "오늘" 0시(ms). 바의 목록 한도("보통 한도는 금일내")에 쓴다.
 * @param {number} [now]
 */
export function dayStart(now = Date.now()) {
  const date = new Date(Number.isFinite(now) ? now : Date.now());
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/** 접기 상태를 방별로 기억하는 저장소 키(기본 접힘; 펼친 방만 '0'). */
export const collapsedKey = (roomId) => `hande:lastSent:collapsed:${roomId ?? ''}`;
