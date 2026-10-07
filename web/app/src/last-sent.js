// 대화창 상단 "내 마지막 말" 바 — DOM·SDK 없이 테스트하는 순수 로직.
//
// 기준은 화면 복사본 timeline(main.js state.rooms[].timeline)이다. 서버에 따로 묻지 않는다:
// 불러온 대화 안에서 내 마지막 메시지를 고르고, 그 뒤에 남이 쓴 메시지 수를 "답장"으로 센다.
// 삭제되어 자리만 남은 진행 말풍선(held)·상태 알림(notice)·열 수 없는 메시지(undecryptable)는
// "내 말"로 치지 않는다. 로컬 에코('~…' id)는 아직 서버가 받지 않은 전송 중 상태다.
import { lastMessagePreview } from './rooms.js';

const QUIET_KINDS = new Set(['notice', 'undecryptable']);

function isSpoken(entry) {
  return Boolean(entry) && !entry.held && !entry.isProgress && !QUIET_KINDS.has(entry.kind);
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

function summarize(entry, preview, replies) {
  const eventId = typeof entry.eventId === 'string' ? entry.eventId : null;
  return {
    eventId,
    text: preview.text,
    ts: Number.isFinite(entry.ts) ? entry.ts : null,
    // 서버가 id를 주기 전('~…')에는 전송 중 — 확정되면 같은 자리의 엔트리가 '$…'로 바뀐다(main.js).
    pending: eventId == null || eventId.startsWith('~'),
    replies,
  };
}

/**
 * 내가 보낸 최근 메시지 요약을 최신순으로 최대 `limit`개(펼친 바의 "이전 내 말" 목록, 오너 2026-10-07).
 * 각 항목의 답장 수는 그 말 뒤부터 **다음 내 말 전까지** 남이 쓴 메시지 수다 — 가장 최근 항목은
 * 끝까지 세므로 lastSentSummary와 같다. 미리보기가 비는 내 말(빈 알림 등)은 목록에도 경계에도 넣지 않는다.
 * @param {Array<object>|null|undefined} timeline
 * @param {{labels: {photo: string, video: string, file: string, undecryptable: string}, limit?: number}} options
 * @returns {Array<{eventId: string|null, text: string, ts: number|null, pending: boolean, replies: number}>}
 */
export function recentSentSummaries(timeline, { labels, limit = 3 } = {}) {
  if (!Array.isArray(timeline) || !Number.isInteger(limit) || limit <= 0) return [];
  const out = [];
  let replies = 0;
  for (let i = timeline.length - 1; i >= 0 && out.length < limit; i--) {
    const entry = timeline[i];
    if (!isSpoken(entry)) continue;
    if (!entry.isMe) { replies += 1; continue; }
    const preview = lastMessagePreview(entry, labels);
    if (!preview) continue;
    out.push(summarize(entry, preview, replies));
    replies = 0;
  }
  return out;
}

/**
 * 바에 그릴 요약(가장 최근 내 말). 없으면 null.
 * @param {Array<object>|null|undefined} timeline
 * @param {{labels: {photo: string, video: string, file: string, undecryptable: string}}} options
 * @returns {{eventId: string|null, text: string, ts: number|null, pending: boolean, replies: number}|null}
 */
export function lastSentSummary(timeline, { labels }) {
  const found = lastSentEntry(timeline);
  if (!found) return null;
  const preview = lastMessagePreview(found.entry, labels);
  if (!preview) return null;
  let replies = 0;
  for (let i = found.index + 1; i < timeline.length; i++) {
    const entry = timeline[i];
    if (isSpoken(entry) && !entry.isMe) replies += 1;
  }
  return summarize(found.entry, preview, replies);
}

/**
 * 기기 시간 기준 "오늘" 0시(ms). 바의 목록 한도(오너 2026-10-07: "보통 한도는 금일내")에 쓴다.
 * @param {number} [now]
 */
export function dayStart(now = Date.now()) {
  const date = new Date(Number.isFinite(now) ? now : Date.now());
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/**
 * 서버에서 sender 필터로 받은 내 메시지(타임라인 엔트리 모양)를 요약한다 — 최신순, 최대 `limit`개.
 * 남의 메시지는 받지 않았으므로 답장 수를 알 수 없다 → `replies: null`(UI는 칩을 생략한다).
 * 삭제·진행·알림·열 수 없는 메시지는 타임라인과 같은 기준으로 뺀다.
 * @param {Array<object>|null|undefined} entries 아무 순서
 * @param {{labels: object, limit?: number}} options
 */
export function indexSummaries(entries, { labels, limit = 50 } = {}) {
  if (!Array.isArray(entries) || !Number.isInteger(limit) || limit <= 0) return [];
  const out = [];
  for (const entry of entries) {
    if (!entry?.isMe || !isSpoken(entry)) continue;
    const preview = lastMessagePreview(entry, labels);
    if (!preview) continue;
    out.push({ ...summarize(entry, preview, null), replies: null });
  }
  out.sort((a, b) => (b.ts ?? 0) - (a.ts ?? 0));
  return out.slice(0, limit);
}

/**
 * 바에 그릴 최종 목록: 화면 타임라인에서 뽑은 요약(답장 수 있음)과 서버 인덱스 요약(없음)을 합친다.
 * 같은 eventId는 타임라인 쪽이 이긴다(답장 수·전송 중 상태가 정확하다). 최신순으로 정렬하고,
 * 첫 항목(바 본문)은 날짜와 무관하게 가장 최근 내 말, 나머지(펼친 목록)는 `sinceTs` 이후만 최대 `limit`개.
 * @param {Array<object>} fromTimeline recentSentSummaries 결과(최신순)
 * @param {Array<object>} fromIndex indexSummaries 결과(최신순)
 * @param {{sinceTs?: number, limit?: number}} options
 * @returns {{lastSent: object|null, earlierSent: Array<object>}}
 */
export function mergeSentSummaries(fromTimeline, fromIndex, { sinceTs = 0, limit = 50 } = {}) {
  const byId = new Map();
  const pendings = [];
  for (const item of Array.isArray(fromTimeline) ? fromTimeline : []) {
    if (!item) continue;
    if (typeof item.eventId === 'string' && !item.pending) byId.set(item.eventId, item);
    else pendings.push(item); // 로컬 에코('~…')는 서버 인덱스에 없다 — 그대로 둔다.
  }
  for (const item of Array.isArray(fromIndex) ? fromIndex : []) {
    if (!item || typeof item.eventId !== 'string' || byId.has(item.eventId)) continue;
    byId.set(item.eventId, item);
  }
  const merged = [...pendings, ...byId.values()].sort((a, b) => (b.ts ?? 0) - (a.ts ?? 0));
  const lastSent = merged[0] ?? null;
  const earlierSent = merged.slice(1).filter((item) => (item.ts ?? 0) >= sinceTs).slice(0, Math.max(0, limit));
  return { lastSent, earlierSent };
}

/** 접기 상태를 방별로 기억하는 저장소 키. */
export const collapsedKey = (roomId) => `familychat:lastSent:collapsed:${roomId ?? ''}`;
