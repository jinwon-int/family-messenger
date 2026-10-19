// This browser's device identity (iOS DeviceIdentity.existingOrNew, #352): chosen
// once on first run, never regenerated for the same storage. The policy chain never
// reuses a device id, so a wiped store must start under a new id (#290).
//
// Storage passphrase: the durable worker seals every record with keys derived from a
// passphrase (custody scrypt). A family member must not have to type 32+ characters,
// so the page mints a random one and keeps it in localStorage — the same trust
// boundary as the IndexedDB it protects (one browser profile), comparable to the iOS
// Keychain item. A user-chosen lock passphrase is a follow-up (#431).
export const ACTOR = /^[a-z][a-z0-9]{1,15}$/;
export const DEVICE = /^[A-Za-z0-9_-]{1,64}$/;
export const ROOM = /^[a-z0-9][a-z0-9-]{0,47}$/;
const KEY = 'hande:identity';
const PASS_KEY = 'hande:passphrase';

const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
export const actorOf = device => device.split('-')[0];

export function createIdentityStore({storage = globalThis.localStorage, random = n => crypto.getRandomValues(new Uint8Array(n))} = {}) {
  function read() {
    try {
      const v = JSON.parse(storage.getItem(KEY) || 'null');
      if (v && typeof v.device === 'string' && DEVICE.test(v.device) && typeof v.actor === 'string' && ACTOR.test(v.actor) && actorOf(v.device) === v.actor) return v;
    } catch (_) { /* ignore */ }
    return null;
  }
  /** Device id for a chosen actor: `<actor>-web-<6 hex>` (iOS: `<actor>-iphone-<6 hex>`). */
  function mint(actor) {
    if (!ACTOR.test(actor)) throw new Error('actor rejected');
    return `${actor}-web-${hex(random(3))}`;
  }
  function choose(actor) {
    const existing = read();
    if (existing) return existing;
    const v = {actor, device: mint(actor), createdAt: Date.now()};
    storage.setItem(KEY, JSON.stringify(v));
    return v;
  }
  /** After a wipe the next identity must be a new device id (#290) — same actor, new suffix. */
  function rotate() {
    const existing = read();
    if (!existing) return null;
    const v = {actor: existing.actor, device: mint(existing.actor), createdAt: Date.now(), previous: existing.device};
    storage.setItem(KEY, JSON.stringify(v));
    return v;
  }
  function passphrase() {
    let p = storage.getItem(PASS_KEY);
    if (typeof p === 'string' && p.length >= 32 && p.length <= 128) return p;
    // 48 random bytes → 64 base64url characters: inside the custody 32–128 bound.
    const bytes = random(48);
    p = btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    storage.setItem(PASS_KEY, p);
    return p;
  }
  function forgetPassphrase() { storage.removeItem(PASS_KEY); }
  function clear() { storage.removeItem(KEY); storage.removeItem(PASS_KEY); }
  return {read, choose, rotate, mint, passphrase, forgetPassphrase, clear};
}

/** Identity store database (worker multi mode, #431 stage 4): the signer only; every room store is derived from it. */
export const IDENTITY_DATABASE = 'family-mls-synthetic-hande--identity';
export const LOBBY_DATABASE = 'family-mls-synthetic-hande--lobby';
export const IDENTITY_ROOM = '-identity', LOBBY_ROOM = '-lobby';
/** Durable store database name for a room (worker pattern `family-mls-synthetic-[a-z0-9-]{1,64}`). */
export function databaseFor(room) {
  if (!ROOM.test(room)) throw new Error('room rejected');
  return `family-mls-synthetic-hande-${room}`;
}
