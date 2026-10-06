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

/**
 * 바에 그릴 요약. 없으면 null.
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
  const eventId = typeof found.entry.eventId === 'string' ? found.entry.eventId : null;
  return {
    eventId,
    text: preview.text,
    ts: Number.isFinite(found.entry.ts) ? found.entry.ts : null,
    // 서버가 id를 주기 전('~…')에는 전송 중 — 확정되면 같은 자리의 엔트리가 '$…'로 바뀐다(main.js).
    pending: eventId == null || eventId.startsWith('~'),
    replies,
  };
}

/** 접기 상태를 방별로 기억하는 저장소 키. */
export const collapsedKey = (roomId) => `familychat:lastSent:collapsed:${roomId ?? ''}`;
