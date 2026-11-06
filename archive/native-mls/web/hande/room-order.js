// 대화 목록 고정 순서 — 패밀리챗 web/app/src/room-order.js 이식(#480 A).
//
// 목록은 최근 활동순으로 움직이지 않고 사용자가 정한 순서를 따른다. 패밀리챗은 Matrix account data 로
// 기기 간 동기화한다. 한데는 **이 기기의 localStorage**(`hande:room-order:<device>`)에 두고, room-order v1(#715) 릴레이가
// 있으면 사람(actor) 단위로 릴레이와 맞춘다(아래 createRoomOrderSync — 옛 릴레이(404)면 로컬만). 저장된 순서에 없는 방(새로 참여한 방)은 기본 순서 — 참여한 순서(`order`), 같으면 표시 이름(한국어 정렬),
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

// ---- room-order v1 릴레이 동기화(#715) ----
// 순서를 사람(actor) 단위로 릴레이에 둔다 — 아이폰·웹·안드로이드가 같은 순서를 쓴다. 계약:
//   GET /v2/me/room-order?device= → {rooms, revision, updated_at} (저장된 적 없으면 revision 0)
//   PUT /v2/me/room-order {device, rooms, base_revision} → 200 {rooms, revision+1, updated_at} · 409 revision_conflict {현재 값}
// 클라이언트 규칙: (1) 목록을 불러올 때(최소 60초 간격) GET — revision>0 이면 서버 순서 채택, revision 0 이고 로컬 순서가
// 있으면 base 0 으로 시드(409 → 채택) (2) 사용자가 옮기면 로컬 즉시 + PUT base=<마지막 revision>(409 → 채택·다시 그림)
// (3) 표시 규칙은 orderRooms 그대로 (4) 404 → 이 세션 동안 로컬만, 네트워크 오류 → 다음 주기에 다시.
// 아래 함수는 순수하고, createRoomOrderSync 는 전송(transport)·저장·시계를 주입받는다(tests/room-order.test.mjs).

/** 릴레이가 받는 방 ID 개수 상한(#715 `rooms` 최대 64개). */
export const ROOM_ORDER_SYNC_LIMIT = 64;
/** GET 최소 간격 — 목록 새로고침(8초)·탭 복귀마다 묻지 않는다. */
export const ROOM_ORDER_PULL_INTERVAL_MS = 60_000;
/** 릴레이 validIdentifier(devicepolicy.IsIdentifier): [A-Za-z0-9_-]{1,64}. 이를 벗어난 ID 는 400 bad_identifier 이므로 올리지 않는다. */
const RELAY_IDENTIFIER = /^[A-Za-z0-9_-]{1,64}$/;

/**
 * 릴레이 응답 본문(200 또는 409) → {rooms, revision, updatedAt}. revision 이 0 이상의 정수가 아니면 null(= 쓸 수 없는 응답).
 * @param {unknown} body
 * @returns {{rooms: string[], revision: number, updatedAt: number}|null}
 */
export function parseServerOrder(body) {
  if (!body || typeof body !== 'object' || !Number.isSafeInteger(body.revision) || body.revision < 0) return null;
  if (!Array.isArray(body.rooms)) return null;
  return {rooms: parseRoomOrder(body.rooms), revision: body.revision, updatedAt: Number.isFinite(body.updated_at) ? body.updated_at : 0};
}

/** 서버 순서를 채택할지: 저장된 적 있는 순서(revision>0)면 채택(덮어씀). */
export function shouldAdopt(server) {
  return !!server && server.revision > 0;
}

/** 이 기기가 시드할지: 서버에 저장된 적 없고(revision 0) 로컬에 사용자 순서가 있을 때(처음 올리는 기기가 시드). */
export function shouldSeed(server, localOrder) {
  return !!server && server.revision === 0 && uploadOrder(localOrder).length > 0;
}

/** 서버 순서 채택 → 새 로컬 저장 순서(덮어씀). 쓸 수 없는 응답이면 null(= 로컬 그대로). */
export function adoptServerOrder(server) {
  return server && Number.isSafeInteger(server.revision) ? parseRoomOrder(server.rooms) : null;
}

/**
 * 로컬 저장 순서 → 릴레이에 올릴 배열: 릴레이 식별자 형식만, 중복 없이, 앞에서부터 64개.
 * (moveRoom 은 지금 보이는 방을 앞에, 안 보이는 저장된 방을 뒤에 두므로 잘리는 건 뒤쪽의 옛 방 ID 다.)
 * @param {unknown} localOrder
 * @returns {string[]}
 */
export function uploadOrder(localOrder) {
  return parseRoomOrder(Array.isArray(localOrder) ? localOrder : []).filter((id) => RELAY_IDENTIFIER.test(id)).slice(0, ROOM_ORDER_SYNC_LIMIT);
}

const sameOrder = (a, b) => a.length === b.length && a.every((id, i) => id === b[i]);

/**
 * room-order v1 동기화 상태 기계. 네트워크는 transport 로만 하고, 화면을 막지 않는다(모든 호출은 백그라운드 Promise).
 * 한 번에 한 요청만 — GET 과 PUT 은 순서대로 이어 실행한다.
 *
 * @param {object} deps
 * @param {{get: () => Promise<{status: number, body: any}>, put: (rooms: string[], baseRevision: number) => Promise<{status: number, body: any}>}} deps.transport
 *   네트워크 실패는 throw(relay.api 와 같다). 그 밖의 HTTP 상태는 {status, body}.
 * @param {() => string[]} deps.getLocal  지금 로컬 저장 순서
 * @param {(order: string[]) => void} deps.setLocal  서버 순서 채택 — 로컬 저장(localStorage) + 상태 반영
 * @param {() => void} [deps.onChange]  채택으로 순서가 바뀌었을 때(다시 그리기)
 * @param {(line: string) => void} [deps.log]
 * @param {() => number} [deps.now]
 * @param {number} [deps.intervalMs]
 */
export function createRoomOrderSync({transport, getLocal, setLocal, onChange = () => {}, log = () => {}, now = Date.now, intervalMs = ROOM_ORDER_PULL_INTERVAL_MS}) {
  // revision: 마지막으로 본 서버 revision(null = 아직 못 봄).
  // localSeq/syncedSeq: 사용자 변경 횟수와 서버에 올라간(또는 서버 순서로 덮인) 변경 — 다르면 아직 못 올린 로컬 변경이 있다.
  // (PUT 이 오가는 사이 또 옮겨도 그 변경을 잃지 않는다.)
  const state = {revision: null, localSeq: 0, syncedSeq: 0, disabled: false, lastPullAt: 0};
  const dirty = () => state.localSeq !== state.syncedSeq;
  let chain = Promise.resolve();
  const run = (fn) => { const p = chain.then(fn, fn); chain = p.catch(() => {}); return p; };

  function adopt(server) {
    const next = adoptServerOrder(server);
    if (!next) return 'error';
    state.revision = server.revision;
    state.syncedSeq = state.localSeq;
    const changed = !sameOrder(next, parseRoomOrder(getLocal()));
    setLocal(next);
    if (changed) { log(`대화방 순서: 서버 순서 채택(revision ${server.revision})`); onChange(); }
    return 'adopted';
  }
  function disable(where) {
    if (!state.disabled) log(`대화방 순서: 릴레이에 room-order 없음(${where} 404) — 이 세션은 이 기기 순서만`);
    state.disabled = true;
    return 'disabled';
  }
  async function push() {
    const seq = state.localSeq;
    const rooms = uploadOrder(getLocal());
    const base = state.revision ?? 0;
    let r;
    try { r = await transport.put(rooms, base); } catch (error) {
      log(`대화방 순서 저장 실패(다음 주기에 다시): ${error?.message ?? error}`);
      return 'error';
    }
    if (r.status === 404) return disable('PUT');
    if (r.status === 409) {
      const server = parseServerOrder(r.body);
      if (!server) return 'error';
      log(`대화방 순서 충돌(base ${base} ≠ 서버 ${server.revision}) — 서버 순서 채택`);
      return adopt(server);
    }
    if (r.status === 200) {
      const server = parseServerOrder(r.body);
      state.revision = server ? server.revision : base + 1;
      state.syncedSeq = Math.max(state.syncedSeq, seq);
      return base === 0 ? 'seeded' : 'saved';
    }
    // 5xx 는 다음 주기에 다시, 4xx(bad_identifier·device_not_allowed 등)는 같은 내용을 되풀이해 올리지 않는다.
    if (r.status < 500) state.syncedSeq = Math.max(state.syncedSeq, seq);
    log(`대화방 순서 저장 거절: ${r.status} ${r.body?.error ?? ''}`.trim());
    return 'error';
  }
  async function pullNow() {
    let r;
    try { r = await transport.get(); } catch (error) {
      log(`대화방 순서 조회 실패(다음 주기에 다시): ${error?.message ?? error}`);
      return 'error';
    }
    if (r.status === 404) return disable('GET');
    const server = r.status === 200 ? parseServerOrder(r.body) : null;
    if (!server) { log(`대화방 순서 조회 거절: ${r.status} ${r.body?.error ?? ''}`.trim()); return 'error'; }
    if (shouldAdopt(server)) {
      // 지난번 본 revision 그대로이고 아직 못 올린 로컬 변경이 있으면 그것을 올린다(서버가 그새 안 바뀌었으니 충돌 아님).
      // revision 이 달라졌으면 다른 기기가 먼저 바꾼 것 — 409 와 같이 서버 순서를 채택한다.
      if (dirty() && state.revision === server.revision) return push();
      return adopt(server);
    }
    state.revision = 0;
    if (shouldSeed(server, getLocal())) { log('대화방 순서: 서버에 없음 — 이 기기 순서로 시드'); return push(); }
    state.syncedSeq = state.localSeq;
    return 'empty';
  }

  return {
    /**
     * 목록을 불러올 때(시작·로그인·탭 복귀·새로고침). 최소 intervalMs 간격 — 그 안이면 'skipped'.
     * @param {{force?: boolean}} [opts]
     * @returns {Promise<'skipped'|'disabled'|'adopted'|'seeded'|'saved'|'empty'|'error'>}
     */
    pull({force = false} = {}) {
      if (state.disabled) return Promise.resolve('disabled');
      const at = now();
      if (!force && state.lastPullAt && at - state.lastPullAt < intervalMs) return Promise.resolve('skipped');
      state.lastPullAt = at;
      return run(pullNow);
    },
    /** 사용자가 순서를 바꿨다(로컬은 이미 저장됨) → PUT base=<마지막 revision>. 앞선 요청이 이미 올렸거나 서버 순서로 덮였으면 건너뛴다. */
    changed() {
      state.localSeq += 1;
      if (state.disabled) return Promise.resolve('disabled');
      return run(() => (dirty() ? push() : 'skipped'));
    },
    get state() { return {...state, dirty: dirty()}; },
  };
}
