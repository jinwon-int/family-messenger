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
