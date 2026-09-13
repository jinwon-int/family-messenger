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
