// 로컬 전용 방 「이 기기에서 지우기」(2026-10-28 오너 요청 — 방 `11`): 참여 요청만 했거나 「방 만들기」로 만들었을 뿐
// 릴레이에는 아직 없는 방(릴레이에는 첫 초대 때 생긴다)은 이 기기에만 있어 다른 기기와 무관하다. 그런 방만 지울 수 있다 —
// 릴레이가 멤버라고 하는 방은 여기서 지워도 다음 refresh 에 다시 열리므로 대상이 아니다(명단에서 빠지는 건 「제거」·재초대의 일).
// 순수 모듈: 판정 + 이 방의 localStorage 키 정리(tests/local-room.test.mjs). 워커 스토어·IndexedDB 는 app.js 가 지운다.

/**
 * 릴레이 방 목록(GET /v2/rooms 의 member 방 집합)을 알고 있고, 거기에 없는 방인가.
 * @param {string} roomId
 * @param {Set<string>|null} relayRooms  아직 받지 못했으면 null → 모름(false)
 */
export function isLocalOnlyRoom(roomId, relayRooms) {
  if (!roomId || !(relayRooms instanceof Set)) return false;
  return !relayRooms.has(roomId);
}

/** 이 방에 속한 hande:* 키인가(기기·방·DB 로 한정 — 다른 방의 키는 건드리지 않는다). */
export function isRoomKey(key, { device, room, database }) {
  if (typeof key !== 'string' || !key.startsWith('hande:')) return false;
  return key === `hande:room:${room}:${device}:${database}`
    || key === `hande:draft:${device}:${room}`
    || key === `hande:readSeq:${device}:${room}`
    || key === `hande:agent-consent:${device}:${room}`
    || key === `hande:lastSent:collapsed:${room}`
    || key === `hande:attachment:${database}:${room}:${device}`
    || key === `hande:attachment-v2:${database}:${room}:${device}`;
}

/**
 * 이 방의 키를 지우고 알려진 방 목록(`hande:rooms:<device>`)에서 뺀다. 지운 키 목록을 돌려준다.
 * @param {Storage} storage
 * @param {{device: string, room: string, database: string}} ids
 */
export function forgetRoomKeys(storage, ids) {
  const removed = [];
  for (const key of Object.keys(storage)) {
    if (isRoomKey(key, ids)) { try { storage.removeItem(key); removed.push(key); } catch (_) { /* 다음 키 */ } }
  }
  const knownKey = `hande:rooms:${ids.device}`;
  try {
    const known = JSON.parse(storage.getItem(knownKey) || '[]');
    if (Array.isArray(known) && known.includes(ids.room)) storage.setItem(knownKey, JSON.stringify(known.filter((r) => r !== ids.room)));
  } catch (_) { /* 목록이 깨져 있으면 다음 시작에서 빈 목록으로 취급된다 */ }
  return removed;
}
