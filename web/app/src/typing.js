// Typing notification state (m.typing): who is typing in which room, and the
// label the room header shows next to its name. Pure module — no DOM, no SDK;
// main.js keeps the state map and both UI sides (보내기: composer activity,
// 받기: RoomMember.typing events) meet here.

/** Typical homeserver-side expiry window we request when sending typing. */
export const TYPING_MAX_AGE_MS = 45_000;

/**
 * Empty typing state: roomId -> Map(userId -> {name, ts}).
 * @returns {Map<string, Map<string, {name: string, ts: number}>>}
 */
export function createTypingState() {
  return new Map();
}

const validRoom = (value) => typeof value === 'string' && value.length > 0;
const validUser = (value) => typeof value === 'string' && value.length > 0;

/**
 * Apply one typing event (already flattened from the SDK's RoomMember.typing).
 * Returns true when the *visible* set of typists for the room changed —
 * repeated "still typing" refreshes update the entry but do not count as a
 * change, so the header label is not redrawn for nothing.
 * @param {Map<string, Map<string, {name: string, ts: number}>>} typingByRoom
 * @param {{roomId: string, userId: string, name?: string, typing: boolean, ts?: number}} event
 * @returns {boolean}
 */
export function applyTypingEvent(typingByRoom, { roomId, userId, name, typing, ts = Date.now() }) {
  if (!validRoom(roomId) || !validUser(userId)) return false;
  const members = typingByRoom.get(roomId) ?? new Map();
  const known = members.has(userId);
  if (!typing) {
    if (!known) return false;
    members.delete(userId);
    if (members.size === 0) typingByRoom.delete(roomId);
    return true;
  }
  if (known) {
    // 이름이 바뀌었을 수 있으니 갱신하되, 표시 변화는 아니다.
    const entry = members.get(userId);
    entry.name = typeof name === 'string' && name.length > 0 ? name : entry.name;
    entry.ts = ts;
    return false;
  }
  members.set(userId, { name: typeof name === 'string' && name.length > 0 ? name : userId, ts });
  typingByRoom.set(roomId, members);
  return true;
}

/**
 * Drop typists whose entry is older than maxAgeMs. The homeserver expires the
 * flag on its own and a later sync corrects the list, but a dropped
 * connection must not pin "입력중입니다" on the header forever.
 * Returns the room ids whose visible state changed (empty array = none).
 * @param {Map<string, Map<string, {name: string, ts: number}>>} typingByRoom
 * @param {number} [now] epoch ms
 * @param {number} [maxAgeMs]
 * @returns {string[]}
 */
export function pruneTyping(typingByRoom, now = Date.now(), maxAgeMs = TYPING_MAX_AGE_MS) {
  const prunedRooms = [];
  for (const [roomId, members] of typingByRoom) {
    let removed = false;
    for (const [userId, entry] of members) {
      if (now - entry.ts > maxAgeMs) {
        members.delete(userId);
        removed = true;
      }
    }
    if (removed) {
      if (members.size === 0) typingByRoom.delete(roomId);
      prunedRooms.push(roomId);
    }
  }
  return prunedRooms;
}

/**
 * Names of the people currently typing in a room, newest first, excluding me.
 * @param {Map<string, Map<string, {name: string, ts: number}>>} typingByRoom
 * @param {string} roomId
 * @param {{myUserId?: string|null, now?: number, maxAgeMs?: number}} [opts]
 * @returns {string[]}
 */
export function typingNames(typingByRoom, roomId, { myUserId = null, now = Date.now(), maxAgeMs = TYPING_MAX_AGE_MS } = {}) {
  const members = typingByRoom.get(roomId);
  if (!members) return [];
  const mine = typeof myUserId === 'string' ? myUserId.toLowerCase() : null;
  const names = [];
  for (const [userId, entry] of members) {
    if (mine && String(userId).toLowerCase() === mine) continue;
    if (now - entry.ts > maxAgeMs) continue;
    names.push(entry.name || userId);
  }
  return names;
}

/**
 * Header label for a room's typing state ('' = hide the indicator).
 * labels: {one: (name) => string, many: (names) => string} — 문구 콜백은 strings 모듈에서 주입한다.
 * @param {string[]} names
 * @param {{one: (name: string) => string, many: (names: string[]) => string}} labels
 * @returns {string}
 */
export function typingIndicator(names, labels) {
  if (!Array.isArray(names) || names.length === 0) return '';
  if (names.length === 1) return labels.one(names[0]);
  return labels.many(names);
}
