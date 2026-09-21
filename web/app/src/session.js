// Session persistence boundary.
//
// Long-lived credentials: the Matrix access token is the family's room
// key custodian on this device, so it is kept in sessionStorage only —
// closing the PWA drops it and a re-login is required. Homeserver URL,
// user ID and device ID are harmless identifiers and persist in
// localStorage so the login form can prefill.
//
// Storage seams are objects with getItem/setItem/removeItem, so tests
// inject Maps and production injects localStorage/sessionStorage.

export const PERSIST_KEYS = Object.freeze({
  homeserverUrl: 'familychat.homeserverUrl',
  userId: 'familychat.userId',
  deviceId: 'familychat.deviceId',
  // Device whose rust crypto store was initialised in THIS browser. Re-login
  // reuses a device id only when this matches: reusing the id after the
  // local store is gone (site data cleared, device deleted and re-created)
  // publishes NEW keys under an OLD id, and every other device then fails
  // verification with m.key_mismatch (aERCaRWsm4 / u5rWMgBd4l, 2026-09-18).
  cryptoDeviceId: 'familychat.cryptoDeviceId',
});

export const VOLATILE_KEYS = Object.freeze({
  accessToken: 'familychat.accessToken',
});

/** @returns {{persistent: object, volatile: object}} known fields only. */
export function splitSession(session = {}) {
  const persistent = {};
  for (const key of Object.keys(PERSIST_KEYS)) {
    if (typeof session[key] === 'string' && session[key].length > 0) persistent[key] = session[key];
  }
  const volatile = {};
  if (typeof session.accessToken === 'string' && session.accessToken.length > 0) {
    volatile.accessToken = session.accessToken;
  }
  return { persistent, volatile };
}

/**
 * Persist a session. Defensive: an access token passed inside `session`
 * never reaches the persistent store even if the caller misroutes it.
 * @param {object} session
 * @param {Storage-like} persistent e.g. localStorage
 * @param {Storage-like} volatile e.g. sessionStorage
 */
export function saveSession(session, { persistent, volatile }) {
  const { persistent: p, volatile: v } = splitSession(session);
  for (const [key, value] of Object.entries(p)) persistent.setItem(PERSIST_KEYS[key], value);
  for (const [key, value] of Object.entries(v)) volatile.setItem(VOLATILE_KEYS[key], value);
}

/** @returns {object} session fields found across the two stores. */
export function readSession({ persistent, volatile } = {}) {
  const session = {};
  for (const [key, storageKey] of Object.entries(PERSIST_KEYS)) {
    const value = persistent?.getItem?.(storageKey);
    if (typeof value === 'string' && value.length > 0) session[key] = value;
  }
  const token = volatile?.getItem?.(VOLATILE_KEYS.accessToken);
  if (typeof token === 'string' && token.length > 0) session.accessToken = token;
  return session;
}

/** Remove every trace of the session from both stores. */
export function clearSession({ persistent, volatile } = {}) {
  for (const storageKey of Object.values(PERSIST_KEYS)) persistent?.removeItem?.(storageKey);
  volatile?.removeItem?.(VOLATILE_KEYS.accessToken);
}

/** True when a usable (logged-in) session is present. */
export function hasLiveSession(session) {
  return Boolean(session?.accessToken && session?.homeserverUrl && session?.userId);
}

// 알림 선호. 세션이 아니라 **이 브라우저의 선택**이라 PERSIST_KEYS에 넣지 않고
// clearSession도 지우지 않는다.
//
// 왜 필요한가: 알림을 끄면 구독과 pusher는 지워지지만 브라우저 권한은 granted로
// 남는다(JS로 권한을 취소할 수 없다). 로그인할 때마다 "권한이 granted면 다시
// 등록"하면 사용자가 끈 것이 새로고침 한 번에 되살아난다 — 끄기 버튼이 한
// 세션짜리가 된다.
export const PUSH_PREFERENCE_KEY = 'familychat.pushEnabled';

/** @returns {'on'|'off'|null} null이면 사용자가 아직 고른 적이 없다. */
export function readPushPreference({ persistent } = {}) {
  const value = persistent?.getItem?.(PUSH_PREFERENCE_KEY);
  return value === 'on' || value === 'off' ? value : null;
}

/** @param {'on'|'off'} value */
export function savePushPreference(value, { persistent } = {}) {
  if (value !== 'on' && value !== 'off') return;
  persistent?.setItem?.(PUSH_PREFERENCE_KEY, value);
}
