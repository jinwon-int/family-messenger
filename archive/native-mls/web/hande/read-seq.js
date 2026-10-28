// 방별 「어디까지 봤나」(readSeq, #541) — iOS LocalPrefs.markRead + FamilyMLSCore Unread.isUnread 이식.
// 안 읽음 = 마지막 글(text·attachment)이 남의 글이고 이 기기가 본 seq 보다 뒤. 같은 사람의 다른 기기에서 보낸 글은
// 남의 글이 아니다(entry.isMe 는 actor 기준, #459). 값은 이 기기 localStorage `hande:readSeq:<device>:<room>` 에
// 두고 줄어들지 않는다 — 새로고침 뒤 봉인 보관 이력이 다시 들어와도 이미 본 방에 N 배지가 켜지지 않는다.
// 「이 기기 지우기」는 `hande:*` 키를 지우므로 함께 사라진다. 저장 실패(용량·사생활 모드)는 조용히 — 메모리 값은 유지.
// #571 B: 같은 사람(actor)의 다른 기기에서 본 위치는 릴레이가 `GET /events` read_seq 로 실어 오고(app.js mergeRelayRead →
// writeReadSeq), 이 기기에서 본 위치는 `POST /read` 로 올린다(room.js markRead) — 어느 기기에서 읽든 N 배지가 함께 꺼진다.

export const readSeqKeyFor = (device, room) => `hande:readSeq:${device}:${room}`;

const countable = (e) => e && (e.kind === 'text' || e.kind === 'attachment') && Number.isSafeInteger(e.seq);

export function readReadSeq(storage, device, room) {
  try {
    const n = Number(storage.getItem(readSeqKeyFor(device, room)));
    return Number.isSafeInteger(n) && n > 0 ? n : 0;
  } catch (_) { return 0; }
}

/** `seq` 까지 봤다 — 지금 값보다 클 때만 저장하고, 결과 값(줄어들지 않음)을 돌려준다. */
export function writeReadSeq(storage, device, room, seq, current = readReadSeq(storage, device, room)) {
  if (!Number.isSafeInteger(seq) || seq <= current) return current;
  try { storage.setItem(readSeqKeyFor(device, room), String(seq)); } catch (_) { /* 메모리 값만 */ }
  return seq;
}

/** 화면 타임라인에서 셀 수 있는(서버 seq 가 있는 text·attachment) 마지막 seq. 없으면 0. */
export function latestSeq(entries) {
  let max = 0;
  for (const e of entries ?? []) if (countable(e) && e.seq > max) max = e.seq;
  return max;
}

/** iOS Unread.isUnread 와 같은 판정 — 마지막 글이 내 글이면 안 읽음 아님(보냈다면 본 것). */
export function isUnread(entries, readSeq) {
  let last = null;
  for (const e of entries ?? []) if (countable(e) && (!last || e.seq >= last.seq)) last = e;
  return Boolean(last) && !last.isMe && last.seq > (readSeq ?? 0);
}
