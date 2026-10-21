// 대화 목록 고정 순서 — 패밀리챗 web/app/src/room-order.js 이식(#480 A).
//
// 목록은 최근 활동순으로 움직이지 않고 사용자가 정한 순서를 따른다. 패밀리챗은 Matrix account data 로
// 기기 간 동기화하지만 한데에는 그런 저장소가 없어 **이 기기의 localStorage**(`hande:room-order:<device>`)에
// 둔다. 저장된 순서에 없는 방(새로 참여한 방)은 기본 순서 — 참여한 순서(`order`), 같으면 표시 이름(한국어 정렬),
// 같으면 방 ID — 로 저장된 방들 뒤에 붙는다. 어느 쪽도 메시지 시각을 보지 않는다.

/** 저장할 방 ID 상한 — 나간 방 ID가 쌓여도 끝없이 커지지 않게. */
export const ROOM_ORDER_LIMIT = 500;

export const storageKeyFor = (device) => `hande:room-order:${device}`;

/** 기본 순서: 참여한 순서 → 표시 이름(ko) → 방 ID. */
export function defaultRoomCompare(a, b) {
  const oa = Number.isFinite(a?.order) ? a.order : Number.MAX_SAFE_INTEGER;
  const ob = Number.isFinite(b?.order) ? b.order : Number.MAX_SAFE_INTEGER;
  if (oa !== ob) return oa - ob;
  const byName = String(a?.name ?? '').localeCompare(String(b?.name ?? ''), 'ko');
  if (byName !== 0) return byName;
  const ia = String(a?.roomId ?? '');
  const ib = String(b?.roomId ?? '');
  return ia < ib ? -1 : ia > ib ? 1 : 0;
}

/**
 * 저장 내용(JSON 문자열 또는 파싱된 값) → 방 ID 배열. 형식이 틀리면 빈 배열(= 기본 순서).
 * @param {unknown} content
 * @returns {string[]}
 */
export function parseRoomOrder(content) {
  let value = content;
  if (typeof value === 'string') {
    try { value = JSON.parse(value); } catch (_) { return []; }
  }
  const rooms = Array.isArray(value) ? value : (value && typeof value === 'object' ? value.rooms : null);
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
 * 저장된 순서대로 방을 늘어놓는다. 저장된 순서에 없는 방은 기본 순서로 뒤에 붙는다. 입력 배열은 바꾸지 않는다.
 * @template {{roomId: string}} T
 * @param {T[]} rooms
 * @param {string[]|null|undefined} savedOrder
 * @returns {T[]}
 */
export function orderRooms(rooms, savedOrder) {
  const rank = new Map();
  (savedOrder ?? []).forEach((id, index) => { if (!rank.has(id)) rank.set(id, index); });
  const known = [];
  const rest = [];
  for (const room of rooms) (rank.has(room.roomId) ? known : rest).push(room);
  known.sort((a, b) => rank.get(a.roomId) - rank.get(b.roomId));
  rest.sort(defaultRoomCompare);
  return [...known, ...rest];
}

/**
 * 화면에 보이는 순서(visibleIds)에서 roomId 를 toIndex 자리로 옮긴 새 저장 순서.
 * 지금 목록에 없지만 전에 저장해 둔 방 ID 는 버리지 않고 뒤에 둔다. 옮길 수 없으면(없는 방, 같은 자리) null.
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

/** localStorage 에서 읽기/쓰기(실패는 조용히 — 순서는 편의 기능이다). */
export function readRoomOrder(storage, device) {
  try { return parseRoomOrder(storage.getItem(storageKeyFor(device))); } catch (_) { return []; }
}
export function writeRoomOrder(storage, device, order) {
  try { storage.setItem(storageKeyFor(device), JSON.stringify(parseRoomOrder(order))); return true; } catch (_) { return false; }
}
