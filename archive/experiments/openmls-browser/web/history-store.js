// #370 relay-app message history (design B): a separate IndexedDB next to the MLS
// store, so the store's schema (session-store.js: version 2, exactly `meta` +
// `entries`) and the live profiles it protects are never migrated. Every record is
// sealed with the same custody subkey through session-store's `sealAux`/`openAux`;
// the additional data binds the domain, identity, room, seq and part, so a record
// moved to another seq/room/device — or presented as a meta/entry record — does not
// open. Visible at rest: the room-scoped database name, the seq keys, record sizes
// and count (as for the MLS store, PERSISTENCE.md).
//
// Layout (database `<mls database>-history`, version 1):
//   rows  key seq → {sealed, blob}   sealed = header JSON {seq, sender, client, kind,
//                                     text, size, received_at}; blob = sealed blob
//                                     length (0 for text)
//   blobs key seq → {sealed}          attachment bytes, sealed separately so the
//                                     timeline lists without opening files
// Retention: at most MAX_ROWS rows and MAX_BYTES of sealed bytes, oldest seq first.
// Ordering (relay-app.js): a decrypt is shown, then `history_put` completes, then the
// worker ledger item is acked — dying in between drops that one row from the history
// (the same outcome as before #370: MLS cannot decrypt a message twice).
export const HISTORY_DB_VERSION = 1;
export const MAX_ROWS = 2000, MAX_BYTES = 200 * 1024 * 1024, LIST_LIMIT = 500;
export const MAX_TEXT = 64 * 1024, MAX_BLOB = 5 * 1024 * 1024 + 4096;
const ROW_KEYS = ['seq', 'sender', 'client', 'kind', 'text', 'size', 'received_at'];
const utf8 = s => new TextEncoder().encode(s);
const fail = () => { throw new Error('rejected'); };
const ident = v => typeof v === 'string' && /^[a-zA-Z0-9_.:-]{1,64}$/.test(v);

export const historyName = database => `${database}-history`;
/** Additional data for one part ('row' | 'blob') of one seq — must start with session-store's aux domain. */
export const historyAd = (identity, room, seq, part) =>
  utf8(`family-mls-aux-history-v1/${part}\0${identity}\0${room}\0${seq}`);

/** Validate a page-supplied row; returns the header and the attachment bytes (or null). */
export function validRow(row) {
  if (!row || Object.getPrototypeOf(row) !== Object.prototype) fail();
  const keys = Object.keys(row).sort().join(',');
  if (keys !== ['bytes', 'client', 'kind', 'sender', 'seq', 'text'].join(',')) fail();
  const {seq, sender, client, kind, text, bytes} = row;
  if (!Number.isSafeInteger(seq) || seq < 1 || !ident(sender) || !(client === '' || ident(client))) fail();
  if (kind === 'text') {
    if (typeof text !== 'string' || utf8(text).length > MAX_TEXT || !Array.isArray(bytes) || bytes.length !== 0) fail();
    return {header: {seq, sender, client, kind, text, size: 0}, blob: null};
  }
  if (kind === 'attachment') {
    if (text !== '' || !Array.isArray(bytes) || bytes.length > MAX_BLOB ||
        !bytes.every(b => Number.isInteger(b) && b >= 0 && b <= 255)) fail();
    return {header: {seq, sender, client, kind, text: '', size: bytes.length}, blob: Uint8Array.from(bytes)};
  }
  fail();
}

export function encodeHeader(header, receivedAt) {
  return utf8(JSON.stringify({...header, received_at: receivedAt}));
}
export function decodeHeader(plain, seq) {
  const header = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(plain));
  if (!header || Object.keys(header).sort().join(',') !== ROW_KEYS.slice().sort().join(',') || header.seq !== seq) fail();
  return header;
}

/**
 * Seqs to delete, oldest first, so that at most `maxRows` rows and `maxBytes`
 * sealed bytes remain. `rows` = [{seq, bytes}] in any order (bytes = row + blob).
 */
export function pruneVictims(rows, {maxRows = MAX_ROWS, maxBytes = MAX_BYTES} = {}) {
  const sorted = rows.slice().sort((a, b) => a.seq - b.seq);
  let total = sorted.reduce((n, r) => n + r.bytes, 0), count = sorted.length;
  const out = [];
  for (const r of sorted) {
    if (count <= maxRows && total <= maxBytes) break;
    out.push(r.seq); count--; total -= r.bytes;
  }
  return out;
}

// ---- IndexedDB (worker side) ----
const request = req => new Promise((resolve, reject) => { req.onsuccess = () => resolve(req.result); req.onerror = () => reject(req.error); });
const done = tx => new Promise((resolve, reject) => {
  tx.oncomplete = () => resolve(); tx.onabort = tx.onerror = () => reject(new Error('history transaction rejected'));
});

/**
 * Open (or create) the history database for one MLS store. `seal(ad, bytes)` /
 * `open(ad, sealed)` are session-store's sealAux/openAux bound to this worker.
 */
export function openHistory(database, {identity, room, seal, open}) {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(historyName(database), HISTORY_DB_VERSION);
    req.onupgradeneeded = event => {
      if (event.oldVersion !== 0) { req.transaction.abort(); return; }
      req.result.createObjectStore('rows');
      req.result.createObjectStore('blobs');
    };
    req.onerror = () => reject(new Error('history unavailable'));
    req.onblocked = () => reject(new Error('history blocked'));
    req.onsuccess = () => {
      const db = req.result;
      if (db.objectStoreNames.length !== 2 || !db.objectStoreNames.contains('rows') || !db.objectStoreNames.contains('blobs')) {
        db.close(); reject(new Error('history schema')); return;
      }
      db.onversionchange = () => db.close();
      resolve(historyApi(db, {identity, room, seal, open}));
    };
  });
}

function historyApi(db, {identity, room, seal, open}) {
  const ad = (seq, part) => historyAd(identity, room, seq, part);
  return {
    /** Store (or overwrite — idempotent per seq) one row, then trim to the retention bounds. */
    async put(row, receivedAt = Date.now()) {
      const {header, blob} = validRow(row);
      const sealedRow = seal(ad(header.seq, 'row'), encodeHeader(header, receivedAt));
      const sealedBlob = blob ? seal(ad(header.seq, 'blob'), blob) : null;
      const tx = db.transaction(['rows', 'blobs'], 'readwrite', {durability: 'strict'});
      const rows = tx.objectStore('rows'), blobs = tx.objectStore('blobs');
      rows.put({sealed: sealedRow, blob: sealedBlob ? sealedBlob.length : 0}, header.seq);
      if (sealedBlob) blobs.put({sealed: sealedBlob}, header.seq); else blobs.delete(header.seq);
      const keysReq = rows.getAllKeys(), valuesReq = rows.getAll();
      valuesReq.onsuccess = () => {
        const sizes = keysReq.result.map((seq, i) => ({seq, bytes: valuesReq.result[i].sealed.length + valuesReq.result[i].blob}));
        for (const seq of pruneVictims(sizes)) { rows.delete(seq); blobs.delete(seq); }
      };
      await done(tx);
      return {seq: header.seq};
    },
    /** The newest `limit` headers, oldest first (no attachment bytes). */
    async list(limit = LIST_LIMIT) {
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_ROWS) fail();
      // Both requests are issued before any await: a transaction is only active while
      // requests are pending, so nothing may be queued on it after a microtask hop.
      const store = db.transaction('rows', 'readonly').objectStore('rows');
      const [keys, values] = await Promise.all([request(store.getAllKeys()), request(store.getAll())]);
      const from = Math.max(0, keys.length - limit);
      return keys.slice(from).map((seq, i) => decodeHeader(open(ad(seq, 'row'), values[from + i].sealed), seq));
    },
    /** Attachment bytes of one seq. */
    async get(seq) {
      if (!Number.isSafeInteger(seq) || seq < 1) fail();
      const tx = db.transaction('blobs', 'readonly');
      const value = await request(tx.objectStore('blobs').get(seq));
      if (!value) fail();
      return open(ad(seq, 'blob'), value.sealed);
    },
    close() { db.close(); },
  };
}
