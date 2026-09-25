// Storage v2 for Session-backed workers (#177 §3.5, M2b). Shared by
// durable-worker.js and trusted-state-worker.js so the authenticated layout,
// set digest, tab reload and commit/abort pairing exist exactly once.
// Development-only synthetic keys: entries are authenticated (HMAC), not encrypted (M2b-3).
//
// Database version 2: store `meta` holds exactly one record `state` (meta version 3
// since M2b-2: its authenticated encoding is labelled with the worker kind, so a
// durable meta never verifies as a trusted one and M2b-1 (meta version 2)
// databases are denied as an older format rather than as corrupt); store
// `entries` holds one record per Session store entry, key [room, entry key],
// value {v, t} with t = entry_tag(record key, room, entry key, v). `meta` binds
// the entry count, a set digest (SHA-256 over (key, tag) sorted by key), the
// ledger (outbox) and acknowledged-id tombstones, and is itself HMAC-tagged.
export const MAX_BINARY = 2 * 1024 * 1024, MAX_LEDGER = 256, ACKED = 256, TAG = 32;
export const FAULTS = ['', 'abort-before-write', 'abort-after-write', 'lost-response'];
export const fail = () => { throw new Error('rejected'); };
export const exact = (value, keys) => value && Object.getPrototypeOf(value) === Object.prototype &&
  Object.keys(value).sort().join(',') === keys.slice().sort().join(',');
export const equal = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
export const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
export const fromHex = s => new Uint8Array((s.match(/../g) ?? []).map(x => parseInt(x, 16)));
export const validId = id => typeof id === 'string' && /^[a-zA-Z0-9_-]{1,64}$/.test(id);
const bytesOf = value => value instanceof Uint8Array ? value : value instanceof ArrayBuffer ? new Uint8Array(value) : fail();
export function input(value, max = 65536) {
  if (!Array.isArray(value) || value.length > max || !value.every(v => Number.isInteger(v) && v >= 0 && v <= 255)) fail();
  return new Uint8Array(value);
}

// Session framing (src/session.rs): u32 LE count, then per entry
// u32 LE key_len ‖ key ‖ u32 LE value_len ‖ value (value_len 0xFFFFFFFF = delete).
export function frame(entries) {
  const size = entries.reduce((n, [k, v]) => n + 8 + k.length + v.length, 4);
  const out = new Uint8Array(size), view = new DataView(out.buffer);
  let at = 0;
  const word = n => { view.setUint32(at, n, true); at += 4; };
  word(entries.length);
  for (const [k, v] of entries) { word(k.length); out.set(k, at); at += k.length; word(v.length); out.set(v, at); at += v.length; }
  return out;
}
export function unframe(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let at = 0;
  const word = () => { if (at + 4 > bytes.length) fail(); const n = view.getUint32(at, true); at += 4; return n; };
  const take = n => { if (at + n > bytes.length) fail(); const out = bytes.slice(at, at + n); at += n; return out; };
  const changes = [];
  for (let count = word(); count > 0; count--) {
    const k = take(word()), len = word();
    changes.push([k, len === 0xFFFFFFFF ? null : take(len)]);
  }
  if (at !== bytes.length) fail();
  return changes;
}

const META_VERSION = 3;

/**
 * One device's durable Session state.
 * @param api   wasm exports: Session, entry_tag, entry_verify, meta_tag, meta_verify, staged_checksum
 * @param opts  {kind ('durable'|'trusted'), identity, room, namePattern, allowed (methods),
 *               extra: {keys, initial(), bytes(meta) -> JSON-able, valid(meta, session)}}
 *               `extra` adds worker-specific authenticated meta fields (e.g. trust pins).
 */
export function createStore(api, {kind, identity, room, namePattern, allowed, extra}) {
  if (!/^[a-z]{1,16}$/.test(kind)) fail();
  const {Session, entry_tag, entry_verify, meta_tag, meta_verify, staged_checksum} = api;
  const META_KEYS = ['version', 'identity', 'room', 'public_key', 'group_id', 'format', 'revision', 'cursor', 'epoch',
    'set', 'count', 'ledger', 'acked', 'tag', ...extra.keys];
  let db;
  // Record (HMAC) key derived from the custody root (custody.js) and the exact
  // custody record it came from; both are fixed by unlock() before any transaction.
  let key = null, custody = null;
  // Resident state, valid only while `known` equals the durable meta revision.
  // tags: hex(entry key) -> {k, t}. reloads: full rebuilds of the resident session.
  let session = null, known = -1, tags = new Map(), reloads = 0;

  // SHA-256 over entries sorted by key (hex order = byte order), each
  // u32 LE key_len ‖ key ‖ tag. Not linear (unlike an XOR of tags), so a mix of
  // old and new validly tagged entries cannot be made to match without the key.
  function setDigest(map) {
    const items = Array.from(map.keys()).sort().map(id => map.get(id));
    const out = new Uint8Array(items.reduce((n, x) => n + 4 + x.k.length + TAG, 0)), view = new DataView(out.buffer);
    let at = 0;
    for (const {k, t} of items) { view.setUint32(at, k.length, true); at += 4; out.set(k, at); at += k.length; out.set(t, at); at += TAG; }
    return staged_checksum(out);
  }
  // Fixed field order and byte hex encoding; no host-dependent object serialization.
  function metaBytes(meta) {
    return new TextEncoder().encode(JSON.stringify(['family-mls-meta-v3/' + kind, meta.version, meta.identity, meta.room,
      hex(meta.public_key), hex(meta.group_id), meta.format, meta.revision, meta.cursor, meta.epoch, hex(meta.set),
      meta.count, meta.ledger.map(x => [x.id, x.method, x.sequence, x.epoch, hex(x.input), hex(x.output)]), meta.acked,
      extra.bytes(meta)]));
  }
  function validMeta(meta, verifyTag = true) {
    if (!exact(meta, META_KEYS) || meta.version !== META_VERSION || meta.identity !== identity || meta.room !== room ||
        !(meta.public_key instanceof Uint8Array) || meta.public_key.length !== 32 ||
        !(meta.group_id instanceof Uint8Array) || meta.group_id.length > 128 || meta.format !== Session.format_version() ||
        !Number.isSafeInteger(meta.revision) || meta.revision < 1 || !Number.isSafeInteger(meta.cursor) || meta.cursor < 0 ||
        typeof meta.epoch !== 'string' || meta.epoch.length > 20 || !(meta.set instanceof Uint8Array) || meta.set.length !== TAG ||
        !Number.isSafeInteger(meta.count) || meta.count < 1 || !(meta.tag instanceof Uint8Array) || meta.tag.length !== TAG ||
        !Array.isArray(meta.ledger) || meta.ledger.length > MAX_LEDGER ||
        !Array.isArray(meta.acked) || meta.acked.length > ACKED || !meta.acked.every(validId) ||
        new Set(meta.acked).size !== meta.acked.length) fail();
    let size = 0;
    const ids = new Set();
    for (const item of meta.ledger) {
      if (!exact(item, ['id', 'method', 'input', 'output', 'sequence', 'epoch']) ||
          !validId(item.id) || ids.has(item.id) || meta.acked.includes(item.id) || !allowed.has(item.method) ||
          typeof item.epoch !== 'string' || item.epoch.length > 20 ||
          !(item.input instanceof Uint8Array) || item.input.length > 65536 ||
          !(item.output instanceof Uint8Array) || item.output.length > 65536 ||
          !Number.isSafeInteger(item.sequence) || item.sequence < 0 || item.sequence > meta.cursor ||
          (item.method === 'decrypt') !== (item.sequence > 0)) fail();
      ids.add(item.id); size += item.input.length + item.output.length;
    }
    if (size > MAX_BINARY) fail();
    if (verifyTag && !meta_verify(key, metaBytes(meta), meta.tag)) fail();
  }
  function seal(meta) { meta.tag = new Uint8Array(TAG); validMeta(meta, false); meta.tag = meta_tag(key, metaBytes(meta)); }
  function dropSession() { if (session) { try { session.free(); } catch (_) {} } session = null; known = -1; tags = new Map(); }

  function open(name) {
    if (typeof name !== 'string' || !namePattern.test(name)) fail();
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(name, 2);
      request.onupgradeneeded = event => {
        // A pre-M2 (version 1) database is retained untouched and denied, never
        // regenerated: synthetic profiles are disposable (see PERSISTENCE.md).
        if (event.oldVersion !== 0) { request.transaction.abort(); return; }
        request.result.createObjectStore('meta').add({version: 0, identity, room}, 'state');
        request.result.createObjectStore('entries');
      };
      request.onerror = () => reject(new Error('state unavailable'));
      request.onblocked = () => reject(new Error('state blocked'));
      request.onsuccess = () => {
        const opened = request.result;
        if (opened.objectStoreNames.length !== 2 || !opened.objectStoreNames.contains('meta') || !opened.objectStoreNames.contains('entries')) {
          opened.close(); reject(new Error('unknown schema')); return;
        }
        opened.onversionchange = () => opened.close();
        db = opened;
        resolve();
      };
    });
  }
  function close() { if (db) { db.close(); db = undefined; } dropSession(); if (key) key.fill(0); key = null; }

  // `meta/custody` = {version: 1, vault, capsule}: the age password capsule. It is
  // written once, together with the initial state, and must never change.
  const validCustody = value => exact(value, ['version', 'vault', 'capsule']) && value.version === 1 &&
    typeof value.vault === 'string' && /^[0-9a-f]{32}$/.test(value.vault) &&
    value.capsule instanceof Uint8Array && value.capsule.length > 0 && value.capsule.length <= 8192;
  const isMarker = value => exact(value, ['version', 'identity', 'room']) && value.version === 0 &&
    value.identity === identity && value.room === room;

  /** Read-only: {fresh: true} for the pending-initialization marker, or the custody record. */
  function readCustody() {
    if (!db) fail();
    return new Promise((resolve, reject) => {
      const tx = db.transaction('meta', 'readonly');
      const store = tx.objectStore('meta');
      const keys = store.getAllKeys(undefined, 3), state = store.get('state'), record = store.get('custody');
      tx.onabort = tx.onerror = () => reject(new Error('state unavailable'));
      tx.oncomplete = () => {
        const names = keys.result.slice().sort().join(',');
        if (names === 'state' && isMarker(state.result)) resolve({fresh: true, custody: null});
        else if (names === 'custody,state' && validCustody(record.result)) resolve({fresh: false, custody: record.result});
        else reject(new Error('unknown state'));
      };
    });
  }
  /** Fix the record key (32 bytes) and the custody record it was derived from. */
  function unlock(authKey, record) {
    if (key || !(authKey instanceof Uint8Array) || authKey.length !== 32 ||
        !validCustody({version: 1, vault: record.vault, capsule: record.capsule})) fail();
    key = authKey; custody = {version: 1, vault: record.vault, capsule: record.capsule};
  }

  /**
   * One read/write transaction. `handler(ctx)` runs synchronously once `meta`
   * is read, validated and the resident session is current; it either sets a
   * response, calls ctx.create()/ctx.persist()/ctx.operation(), or throws (abort).
   * Read/write transactions across tabs serialize the complete read-modify-write.
   */
  function transaction(handler) {
    if (!db || !key) fail();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(['meta', 'entries'], 'readwrite', {durability: 'strict'});
      const metaStore = tx.objectStore('meta'), entryStore = tx.objectStore('entries');
      let response, fault, inflight = false, next = null;
      const abort = () => { try { tx.abort(); } catch (_) {} };
      tx.onerror = () => {}; // onabort is the single failure result.
      tx.onabort = () => {
        // The session holds uncommitted changes: return it to the durable state.
        if (inflight) { try { session.abort(); } catch (_) { dropSession(); } }
        reject(new Error('transaction rejected'));
      };
      tx.oncomplete = () => {
        if (inflight) session.commit();
        if (next) { tags = next.tags; known = next.revision; }
        // Test-only lost-response fault. Durable state may now contain the operation.
        if (fault !== 'lost-response') resolve(response);
      };

      // Persist session changes + meta in this transaction; `meta` is updated in place.
      function persist(meta, changes) {
        const nextTags = new Map(tags);
        let written = 0;
        for (const [k, v] of changes) {
          const id = hex(k);
          if (v === null) { if (!nextTags.delete(id)) fail(); entryStore.delete([room, k]); continue; }
          const t = entry_tag(key, room, k, v);
          nextTags.set(id, {k, t});
          entryStore.put({v, t}, [room, k]); written += k.length + v.length;
        }
        meta.set = setDigest(nextTags); meta.count = nextTags.size; meta.revision++;
        seal(meta);
        metaStore.put(meta, 'state');
        next = {tags: nextTags, revision: meta.revision};
        // The meta record (ledger included) is rewritten on every operation.
        return {entries: written, meta: metaBytes(meta).length};
      }
      // Rebuild the resident session from durable entries (other tab wrote, or first use).
      function load(meta, then) {
        const keysRequest = entryStore.getAllKeys(), valuesRequest = entryStore.getAll();
        valuesRequest.onsuccess = () => {
          try {
            const keys = keysRequest.result, values = valuesRequest.result;
            if (keys.length !== meta.count || values.length !== keys.length) fail();
            const loaded = new Map(), entries = [];
            keys.forEach((pair, i) => {
              const value = values[i];
              if (!Array.isArray(pair) || pair.length !== 2 || pair[0] !== room || !exact(value, ['v', 't'])) fail();
              const k = bytesOf(pair[1]), v = bytesOf(value.v), t = bytesOf(value.t);
              if (!entry_verify(key, room, k, v, t)) fail();
              loaded.set(hex(k), {k, t}); entries.push([k, v]);
            });
            if (loaded.size !== meta.count || !equal(setDigest(loaded), meta.set)) fail();
            dropSession();
            const opened = Session.open(identity, meta.public_key, meta.group_id, meta.format, frame(entries));
            if (opened.migrated() || opened.current_epoch() !== meta.epoch || !equal(opened.public_key(), meta.public_key) ||
                !equal(opened.group_id(), meta.group_id)) { opened.free(); fail(); }
            try { extra.valid(meta, opened); } catch (error) { opened.free(); throw error; }
            session = opened; known = meta.revision; tags = loaded; reloads++;
            then();
          } catch (_) { abort(); }
        };
      }

      const ctx = {
        get session() { return session; },
        get vault() { return custody.vault; },
        get reloads() { return reloads; },
        persist,
        // A new identity from the pending-initialization marker.
        create(fields = {}) {
          dropSession();
          session = Session.create(identity); inflight = true;
          const fresh = {version: META_VERSION, identity, room, public_key: session.public_key(), group_id: new Uint8Array(0),
            format: Session.format_version(), revision: 0, cursor: 0, epoch: 'none', set: new Uint8Array(TAG),
            count: 0, ledger: [], acked: [], tag: new Uint8Array(TAG), ...extra.initial(), ...fields};
          persist(fresh, unframe(session.pending_changes()));
          metaStore.add(custody, 'custody');  // add: fails if a custody record appeared meanwhile
          return fresh;
        },
        // Delivered/processed items leave the ledger (§3.5 pruning). Unknown ids
        // reject. The last ACKED ids stay as tombstones, so a retry after a lost ack
        // reply is rejected instead of re-encrypting. Callers must never reuse an id.
        ack(meta, argument) {
          if (!exact(argument, ['ids']) || !Array.isArray(argument.ids) || !argument.ids.length ||
              argument.ids.length > MAX_LEDGER || new Set(argument.ids).size !== argument.ids.length ||
              !argument.ids.every(id => meta.ledger.some(x => x.id === id))) fail();
          meta.ledger = meta.ledger.filter(x => !argument.ids.includes(x.id));
          meta.acked = meta.acked.concat(argument.ids).slice(-ACKED);
          persist(meta, []);
          return {revision: meta.revision, operations: meta.ledger.map(x => x.id)};
        },
        // Immutable operation id: exact replay from the ledger, or one new
        // session operation `apply(bytes)` -> Step, persisted with its ledger item.
        operation(meta, argument, apply) {
          if (!exact(argument, ['id', 'method', 'bytes', 'sequence', 'fault']) ||
              !validId(argument.id) || meta.acked.includes(argument.id) || !allowed.has(argument.method) ||
              !Number.isSafeInteger(argument.sequence) || argument.sequence < 0 || !FAULTS.includes(argument.fault)) fail();
          fault = argument.fault;
          const bytes = input(argument.bytes);
          const prior = meta.ledger.find(x => x.id === argument.id);
          if (prior) {
            if (prior.method !== argument.method || prior.sequence !== argument.sequence || !equal(prior.input, bytes) ||
                (prior.method === 'encrypt' && prior.epoch !== meta.epoch)) fail();
            return {output: Array.from(prior.output), revision: meta.revision, cursor: meta.cursor, replay: true, changed: 0};
          }
          if (meta.ledger.length >= MAX_LEDGER || meta.revision >= Number.MAX_SAFE_INTEGER) fail();
          if (argument.method === 'decrypt' ? argument.sequence !== meta.cursor + 1 : argument.sequence !== 0) fail();
          // Synchronous WASM call inside the active IDB transaction callback. A
          // rejection has already been rolled back inside the session.
          const result = apply(bytes);
          inflight = true;
          const output = result.output(), changes = unframe(result.changes());
          meta.epoch = result.epoch();
          result.free();
          const group = session.group_id();
          if (meta.group_id.length && !equal(group, meta.group_id)) fail();
          meta.group_id = group;
          meta.ledger.push({id: argument.id, method: argument.method, input: bytes, output, sequence: argument.sequence, epoch: meta.epoch});
          if (argument.method === 'decrypt') meta.cursor = argument.sequence;
          if (fault === 'abort-before-write') { abort(); return undefined; }
          const written = persist(meta, changes);
          if (fault === 'abort-after-write') { abort(); return undefined; }
          return {output: Array.from(output), revision: meta.revision, cursor: meta.cursor, replay: false,
            changed: changes.length, bytes_written: written.entries, meta_bytes: written.meta};
        },
        // Pin/metadata-only update with its own fault injection (no session change).
        update(meta, change, updateFault) {
          if (!FAULTS.includes(updateFault)) fail();
          fault = updateFault;
          change(meta);
          if (fault === 'abort-before-write') { abort(); return false; }
          persist(meta, []);
          if (fault === 'abort-after-write') { abort(); return false; }
          return true;
        },
      };

      const metaKeys = metaStore.getAllKeys(undefined, 3);
      const stored = metaStore.get('custody');
      const get = metaStore.get('state');
      get.onsuccess = () => {
          try {
            const meta = get.result, names = metaKeys.result.slice().sort().join(',');
            if (names === 'state' && isMarker(meta)) {
              response = handler(ctx, null);
              return;
            }
            // The capsule this worker unlocked must still be the stored one.
            if (names !== 'custody,state' || !validCustody(stored.result) || stored.result.vault !== custody.vault ||
                !equal(stored.result.capsule, custody.capsule)) fail();
            validMeta(meta);
            const run = () => { try { response = handler(ctx, meta); } catch (_) { abort(); } };
            if (!session || known !== meta.revision) load(meta, run); else run();
          } catch (_) { abort(); }
      };
    });
  }

  return {open, close, readCustody, unlock, transaction, metaBytes};
}
