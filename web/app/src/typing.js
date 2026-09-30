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
 * Header label for a room's typing state ('' = hide the indicator). The copy
 * is a single static phrase (오너 지정 "입력중.."); the string table is the one place for copy.
 * @param {string[]} names
 * @param {string} label
 * @returns {string}
 */
export function typingIndicator(names, label) {
  if (!Array.isArray(names) || names.length === 0) return '';
  return label;
}

// --- 보내기: 작성창 활동 → m.typing ---
// 홈서버는 timeout(TYPING_TIMEOUT_MS) 뒤 스스로 플래그를 만료시키므로, 계속 쓰는 동안은 만료 전에
// 재알림해야 상대 화면의 "입력중.."이 끊기지 않는다. 예전에는 새 키 입력이 있을 때만 재알림하고
// 6초 뜸하면 꺼서, 문장을 고민하는 사이에 표시가 사라졌다(오너 결정 2026-09-30: 분명히 쓰고 있으면 유지).
//
// 규칙:
// - 작성창에 글이 있고 창이 포커스·표시 중이면 새 키 입력이 없어도 TYPING_REFRESH_MS마다 다시 알린다(keep-alive).
// - 즉시 끄기: 전송·작성창 비움·방 전환·창 blur·문서 hidden·상한 도달.
// - 상한 TYPING_MAX_MS: 마지막 실제 키 입력 뒤 3분이 지나면 무조건 끈다(초안을 잊고 둔 채 영원히 "입력중" 방지).
// - 유휴 TYPING_IDLE_MS: 마지막 키 입력 뒤 15초에 한 번 점검한다 — blur/hidden 이벤트를 놓쳤을 때(포커스 없이
//   열린 창, 이벤트가 없는 환경)를 위한 안전망이라, 포커스·표시 중이면 끄지 않는다.
export const TYPING_TIMEOUT_MS = 30_000; // 홈서버에 요청하는 유지 창(서버 쪽 값 — 바꾸지 않는다)
export const TYPING_REFRESH_MS = 20_000; // keep-alive 재알림 주기(만료 전)
export const TYPING_IDLE_MS = 15_000;    // 포커스·표시가 아닐 때 끄기까지의 대기(Element 10초, 가족 대화는 더 길게 멈춘다)
export const TYPING_MAX_MS = 180_000;    // 키 입력 없이 계속 알리는 상한

/**
 * 타이핑 알림 전송기. 방 하나에 대해서만 상태를 가진다(다른 방으로 새지 않는다). 절대 throw하지 않는다.
 * DOM·SDK 없이 시험할 수 있게 시계·타이머·포커스/표시 판정을 주입받는다.
 * @param {{
 *   send: (roomId: string, typing: boolean, timeoutMs: number) => Promise<unknown>|unknown,
 *   onError?: (error: unknown) => void,
 *   isFocused?: () => boolean, isVisible?: () => boolean,
 *   now?: () => number, setTimer?: typeof setTimeout, clearTimer?: typeof clearTimeout,
 *   timeoutMs?: number, refreshMs?: number, idleMs?: number, maxMs?: number,
 * }} opts
 */
export function createTypingSender({
  send,
  onError = () => {},
  isFocused = () => true,
  isVisible = () => true,
  now = Date.now,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  timeoutMs = TYPING_TIMEOUT_MS,
  refreshMs = TYPING_REFRESH_MS,
  idleMs = TYPING_IDLE_MS,
  maxMs = TYPING_MAX_MS,
}) {
  let roomId = null; // 알림을 켜 둔 방(null = 꺼짐)
  let sentAt = 0; // 마지막으로 typing=true를 보낸 시각
  let lastKeyAt = 0; // 마지막 실제 키 입력 시각(상한 기준)
  let keepAliveTimer = null;
  let idleTimer = null;
  let capTimer = null;

  function push(room, typing) {
    try {
      Promise.resolve(send(room, typing, timeoutMs)).catch(onError);
    } catch (error) {
      onError(error);
    }
  }

  function clearTimers() {
    for (const timer of [keepAliveTimer, idleTimer, capTimer]) if (timer) clearTimer(timer);
    keepAliveTimer = idleTimer = capTimer = null;
  }

  /** 지금도 분명히 쓰고 있다고 볼 수 있는가(켜져 있고, 창이 포커스·표시 중). */
  function composing() {
    let focused = true;
    let visible = true;
    try {
      focused = isFocused() !== false;
      visible = isVisible() !== false;
    } catch {
      // 판정이 실패하면 쓰고 있다고 본다 — 상한이 결국 끈다.
    }
    return roomId !== null && focused && visible;
  }

  /** 끈다(켜져 있었으면 typing=false를 보낸다). */
  function stop() {
    clearTimers();
    if (roomId === null) return;
    const room = roomId;
    roomId = null;
    push(room, false);
  }

  function announce(at) {
    sentAt = at;
    push(roomId, true);
    if (keepAliveTimer) clearTimer(keepAliveTimer);
    keepAliveTimer = setTimer(onKeepAlive, refreshMs);
  }

  function onKeepAlive() {
    keepAliveTimer = null;
    const at = now();
    if (!composing() || at - lastKeyAt >= maxMs) {
      stop();
      return;
    }
    announce(at);
  }

  function onIdle() {
    idleTimer = null;
    if (!composing()) stop();
  }

  return {
    /** 작성창 활동(실제 키 입력). hasText=false면 비운 것이므로 즉시 끈다. */
    activity(room, hasText) {
      if (typeof room !== 'string' || room.length === 0) return;
      if (roomId !== null && roomId !== room) stop(); // 방이 바뀌었는데 알림이 남아 있으면 먼저 끈다
      if (!hasText) {
        stop();
        return;
      }
      const at = now();
      lastKeyAt = at;
      if (roomId === null) {
        roomId = room;
        announce(at);
      } else if (at - sentAt >= refreshMs) {
        announce(at);
      }
      if (idleTimer) clearTimer(idleTimer);
      idleTimer = setTimer(onIdle, idleMs);
      if (capTimer) clearTimer(capTimer);
      capTimer = setTimer(stop, maxMs);
    },
    /** 전송·방 전환·목록으로 나감 등: 즉시 끈다. */
    stop,
    /** 창 포커스 변화 — 잃으면 즉시 끈다(되찾아도 다음 키 입력까지 켜지 않는다). */
    focusChanged(focused) {
      if (!focused) stop();
    },
    /** 문서 표시 변화 — 숨겨지면 즉시 끈다. */
    visibilityChanged(visible) {
      if (!visible) stop();
    },
    /** 로그아웃 등: 서버에 보내지 않고 상태만 비운다. */
    reset() {
      clearTimers();
      roomId = null;
    },
    /** 지금 알림을 켜 둔 방(없으면 null). */
    get activeRoomId() {
      return roomId;
    },
  };
}
