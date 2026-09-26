// 대화 목록 고정 순서. 목록은 최근 활동순으로 움직이지 않고, 사용자가 정한 순서를 따른다.
//
// 순서는 계정별 account data(ROOM_ORDER_EVENT)에 방 ID 배열로 저장한다 — 같은 계정의 다른
// 기기(휴대폰·PC)에도 그대로 동기화되고, 가족 구성원마다 자기 순서를 가진다.
// 저장된 순서가 없거나 거기 없는 방(새로 참여한 방)은 기본 순서(가족방 → 개인방 → 다른 방,
// 같은 종류 안에서는 이름순)로 저장된 방들 뒤에 붙는다. 어느 쪽도 메시지 시각을 보지 않는다.

/** Account data event type holding `{ rooms: string[] }`. */
export const ROOM_ORDER_EVENT = 'us.familychat.room_order';

/** 저장할 방 ID 상한 — 나간 방 ID가 쌓여도 account data가 끝없이 커지지 않게. */
export const ROOM_ORDER_LIMIT = 500;

const KIND_RANK = { family: 0, private: 1, other: 2 };

/** 기본 순서: 가족방 → 개인방 → 다른 방, 같은 종류는 표시 이름(한국어 정렬) → 방 ID. */
export function defaultRoomCompare(a, b) {
  const ka = KIND_RANK[a?.kind] ?? KIND_RANK.other;
  const kb = KIND_RANK[b?.kind] ?? KIND_RANK.other;
  if (ka !== kb) return ka - kb;
  const byName = String(a?.displayName ?? '').localeCompare(String(b?.displayName ?? ''), 'ko');
  if (byName !== 0) return byName;
  const ia = String(a?.roomId ?? '');
  const ib = String(b?.roomId ?? '');
  return ia < ib ? -1 : ia > ib ? 1 : 0;
}

/**
 * account data 내용 → 방 ID 배열. 형식이 틀리면 빈 배열(= 기본 순서)로 본다.
 * @param {unknown} content
 * @returns {string[]}
 */
export function parseRoomOrder(content) {
  const rooms = content && typeof content === 'object' ? content.rooms : null;
  if (!Array.isArray(rooms)) return [];
  const seen = new Set();
  const out = [];
  for (const id of rooms) {
    if (typeof id !== 'string' || id.length === 0 || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
    if (out.length >= ROOM_ORDER_LIMIT) break;
  }
  return out;
}

/**
 * 저장된 순서대로 방을 늘어놓는다. 저장된 순서에 없는 방은 기본 순서로 뒤에 붙는다.
 * 입력 배열은 바꾸지 않는다.
 * @template {{roomId: string}} T
 * @param {T[]} summaries
 * @param {string[]|null|undefined} savedOrder
 * @returns {T[]}
 */
export function orderRooms(summaries, savedOrder) {
  const rank = new Map();
  (savedOrder ?? []).forEach((id, index) => {
    if (!rank.has(id)) rank.set(id, index);
  });
  const known = [];
  const rest = [];
  for (const room of summaries) (rank.has(room.roomId) ? known : rest).push(room);
  known.sort((a, b) => rank.get(a.roomId) - rank.get(b.roomId));
  rest.sort(defaultRoomCompare);
  return [...known, ...rest];
}

/**
 * 화면에 보이는 순서(visibleIds)에서 roomId를 toIndex 자리로 옮긴 새 저장 순서.
 * 지금 목록에 없지만 전에 저장해 둔 방 ID(잠시 안 보이는 방)는 버리지 않고 뒤에 둔다.
 * 옮길 수 없으면(없는 방, 같은 자리) null.
 * @param {string[]} visibleIds
 * @param {string} roomId
 * @param {number} toIndex 옮긴 뒤 목록에서의 위치(0부터, 범위 밖이면 양끝으로 맞춘다)
 * @param {string[]} [savedOrder]
 * @returns {string[]|null}
 */
export function moveRoom(visibleIds, roomId, toIndex, savedOrder = []) {
  const from = visibleIds.indexOf(roomId);
  if (from < 0 || !Number.isFinite(toIndex)) return null;
  const to = Math.max(0, Math.min(visibleIds.length - 1, Math.trunc(toIndex)));
  if (to === from) return null;
  const next = visibleIds.filter((id) => id !== roomId);
  next.splice(to, 0, roomId);
  const visible = new Set(next);
  const hidden = (savedOrder ?? []).filter((id) => !visible.has(id));
  return [...next, ...hidden].slice(0, ROOM_ORDER_LIMIT);
}
