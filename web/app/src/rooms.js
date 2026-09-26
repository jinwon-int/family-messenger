// Room classification and display names.
//
// Stage 1 knows two product shapes: the family room (가족방) and 1:1
// private rooms (개인방). Direct-message flagged rooms and two-member
// rooms are private; anything with three or more members that is not
// direct is treated as a family room; anything else stays "other" so we
// never mislabel a room we do not understand.

export const ROOM_KINDS = Object.freeze({
  family: 'family',
  private: 'private',
  other: 'other',
});

/**
 * @param {{isDirect?: boolean, memberCount?: number}} room
 * @returns {'family'|'private'|'other'}
 */
export function classifyRoom(room) {
  if (!room) return ROOM_KINDS.other;
  if (room.isDirect) return ROOM_KINDS.private;
  const count = Number(room.memberCount ?? 0);
  if (count >= 3) return ROOM_KINDS.family;
  if (count === 2) return ROOM_KINDS.private;
  return ROOM_KINDS.other;
}

/**
 * Best-effort display name. Returns '' when nothing is known; the caller
 * falls back to the localized "unnamed room" string.
 * @param {{name?: string, otherMemberNames?: string[]}} room
 * @returns {string}
 */
export function roomDisplayName(room) {
  if (!room) return '';
  if (typeof room.name === 'string' && room.name.trim().length > 0) {
    return room.name.trim();
  }
  const others = (room.otherMemberNames ?? []).filter((n) => typeof n === 'string' && n.trim().length > 0);
  return others.map((n) => n.trim()).join('·');
}

/**
 * One-line preview of a timeline entry for the room list. Attachments show
 * their kind label instead of the raw filename-only body.
 * @param {{kind?: string, body?: string, name?: string}|null} entry
 * @param {{photo: string, video: string, file: string, undecryptable: string}} labels
 * @returns {{text: string, sender: string}|null}
 */
export function lastMessagePreview(entry, labels) {
  if (!entry) return null;
  const sender = typeof entry.name === 'string' ? entry.name : '';
  const kind = entry.kind;
  let text;
  if (kind === 'undecryptable') text = labels.undecryptable;
  else if (kind === 'photo') text = `[${labels.photo}] ${entry.body ?? ''}`.trim();
  else if (kind === 'video') text = `[${labels.video}] ${entry.body ?? ''}`.trim();
  else if (kind === 'file') text = `[${labels.file}] ${entry.body ?? ''}`.trim();
  else text = String(entry.body ?? '').replace(/\s+/g, ' ').trim();
  if (!text) return null;
  return { text, sender };
}

/**
 * Coarse relative time for list rows: 방금 / N분 전 / N시간 전 / 어제 / M.D.
 * Minute granularity below an hour, so a 2-second refresh only changes the
 * label when a real minute boundary passes.
 * @param {number|null|undefined} ts epoch ms
 * @param {number} now epoch ms
 * @param {{justNow: string, minutesAgo: (n:number)=>string, hoursAgo: (n:number)=>string, yesterday: string}} labels
 */
export function relativeTime(ts, now, labels) {
  if (!Number.isFinite(ts) || ts <= 0) return '';
  const diff = Math.max(0, now - ts);
  const minute = 60_000;
  if (diff < minute) return labels.justNow;
  if (diff < 60 * minute) return labels.minutesAgo(Math.floor(diff / minute));
  if (diff < 24 * 60 * minute) return labels.hoursAgo(Math.floor(diff / (60 * minute)));
  const d = new Date(ts);
  const n = new Date(now);
  const startOfToday = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime();
  if (ts >= startOfToday - 24 * 60 * minute) return labels.yesterday;
  return `${d.getMonth() + 1}.${d.getDate()}.`;
}

/**
 * Cheap change signature for the list so a periodic tick re-renders only
 * when something visible changed (name, member count, last message, label).
 */
export function listSignature(summaries, now, labels) {
  return JSON.stringify(summaries.map((room) => [
    room.roomId,
    room.displayName,
    room.memberCount,
    room.lastMessage?.eventId ?? '',
    room.lastMessage?.text ?? '',
    relativeTime(room.lastMessage?.ts, now, labels),
  ]));
}
