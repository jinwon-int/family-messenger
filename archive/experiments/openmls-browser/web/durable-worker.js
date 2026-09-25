// Development-only synthetic keys in IndexedDB. No production key protection:
// entries are authenticated (HMAC) but not encrypted until the custody stack (#177 M2b-3).
import init, {Session, entry_tag, entry_verify, meta_verify, meta_tag} from './pkg/family_mls_browser_experiment.js';
const wasm = await init();
// Storage v2 (#177 §3.5): the device lives in a resident WASM `Session`; each
// operation persists only the changed store entries, one IDB record per entry
// keyed [room, entry key], plus one authenticated `meta` record. See PERSISTENCE.md.
const MAX_BINARY = 2 * 1024 * 1024, MAX_LEDGER = 256, TAG = 32;
const allowed = new Set(['key_package', 'create', 'invite', 'join', 'encrypt', 'decrypt', 'remove', 'commit']);
let db, identity, room, key;
// Resident state, valid only while `known` equals the durable meta revision.
let session = null, known = -1, tags = new Map();
const fail = () => { throw new Error('rejected'); };
const exact = (value, keys) => value && Object.getPrototypeOf(value) === Object.prototype &&
  Object.keys(value).sort().join(',') === keys.sort().join(',');
const equal = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
const bytesOf = value => value instanceof Uint8Array ? value : value instanceof ArrayBuffer ? new Uint8Array(value) : fail();
function input(value, max = 65536) {
  if (!Array.isArray(value) || value.length > max || !value.every(v => Number.isInteger(v) && v >= 0 && v <= 255)) fail();
  return new Uint8Array(value);
}
function xor(into, tag) { for (let i = 0; i < TAG; i++) into[i] ^= tag[i]; }

// Fixed field order and byte hex encoding; no host-dependent object serialization.
function metaBytes(meta) {
  return new TextEncoder().encode(JSON.stringify(['family-mls-meta-v2', meta.version, meta.identity, meta.room,
    hex(meta.public_key), hex(meta.group_id), meta.format, meta.revision, meta.cursor, meta.epoch, hex(meta.set),
    meta.count, meta.ledger.map(x => [x.id, x.method, x.sequence, x.epoch, hex(x.input), hex(x.output)])]));
}
const META_KEYS = ['version', 'identity', 'room', 'public_key', 'group_id', 'format', 'revision', 'cursor', 'epoch',
  'set', 'count', 'ledger', 'tag'];
function validMeta(meta, verifyTag = true) {
  if (!exact(meta, META_KEYS) || meta.version !== 2 || meta.identity !== identity || meta.room !== room ||
      !(meta.public_key instanceof Uint8Array) || meta.public_key.length !== 32 ||
      !(meta.group_id instanceof Uint8Array) || meta.group_id.length > 128 || meta.format !== Session.format_version() ||
      !Number.isSafeInteger(meta.revision) || meta.revision < 1 || !Number.isSafeInteger(meta.cursor) || meta.cursor < 0 ||
      typeof meta.epoch !== 'string' || meta.epoch.length > 20 || !(meta.set instanceof Uint8Array) || meta.set.length !== TAG ||
      !Number.isSafeInteger(meta.count) || meta.count < 1 || !(meta.tag instanceof Uint8Array) || meta.tag.length !== TAG ||
      !Array.isArray(meta.ledger) || meta.ledger.length > MAX_LEDGER) fail();
  let size = 0;
  const ids = new Set();
  for (const item of meta.ledger) {
    if (!exact(item, ['id', 'method', 'input', 'output', 'sequence', 'epoch']) ||
        typeof item.id !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(item.id) || ids.has(item.id) || !allowed.has(item.method) ||
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

// Session framing (src/session.rs): u32 LE count, then per entry
// u32 LE key_len ‖ key ‖ u32 LE value_len ‖ value (value_len 0xFFFFFFFF = delete).
function frame(entries) {
  const size = entries.reduce((n, [k, v]) => n + 8 + k.length + v.length, 4);
  const out = new Uint8Array(size), view = new DataView(out.buffer);
  let at = 0;
  const word = n => { view.setUint32(at, n, true); at += 4; };
  word(entries.length);
  for (const [k, v] of entries) { word(k.length); out.set(k, at); at += k.length; word(v.length); out.set(v, at); at += v.length; }
  return out;
}
function unframe(bytes) {
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

function open(name) {
  if (typeof name !== 'string' || !/^family-mls-synthetic-[a-z0-9-]{1,64}$/.test(name)) fail();
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
      resolve(opened);
    };
  });
}

function dropSession() { if (session) { try { session.free(); } catch (_) {} } session = null; known = -1; tags = new Map(); }

function transaction(operation, argument) {
  return new Promise((resolve, reject) => {
    // Read/write transactions across tabs serialize the complete read-modify-write.
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
      const nextTags = new Map(tags), set = meta.set.slice();
      let written = 0;
      for (const [k, v] of changes) {
        const id = hex(k), old = nextTags.get(id);
        if (old) { xor(set, old); nextTags.delete(id); meta.count--; }
        if (v === null) { if (!old) fail(); entryStore.delete([room, k]); continue; }
        const t = entry_tag(key, room, k, v);
        xor(set, t); nextTags.set(id, t); meta.count++;
        entryStore.put({v, t}, [room, k]); written += k.length + v.length;
      }
      meta.set = set; meta.revision++;
      seal(meta);
      metaStore.put(meta, 'state');
      next = {tags: nextTags, revision: meta.revision};
      return written;
    }
    // Rebuild the resident session from durable entries (other tab wrote, or first use).
    function load(meta, then) {
      const keysRequest = entryStore.getAllKeys(), valuesRequest = entryStore.getAll();
      valuesRequest.onsuccess = () => {
        try {
          const keys = keysRequest.result, values = valuesRequest.result;
          if (keys.length !== meta.count || values.length !== keys.length) fail();
          const set = new Uint8Array(TAG), loaded = new Map(), entries = [];
          keys.forEach((pair, i) => {
            const value = values[i];
            if (!Array.isArray(pair) || pair.length !== 2 || pair[0] !== room || !exact(value, ['v', 't'])) fail();
            const k = bytesOf(pair[1]), v = bytesOf(value.v), t = bytesOf(value.t);
            if (!entry_verify(key, room, k, v, t)) fail();
            xor(set, t); loaded.set(hex(k), t); entries.push([k, v]);
          });
          if (!equal(set, meta.set)) fail();
          dropSession();
          const opened = Session.open(identity, meta.public_key, meta.group_id, meta.format, frame(entries));
          if (opened.migrated() || opened.current_epoch() !== meta.epoch || !equal(opened.public_key(), meta.public_key)) {
            opened.free(); fail();
          }
          session = opened; known = meta.revision; tags = loaded;
          then();
        } catch (_) { abort(); }
      };
    }

    const metaKeys = metaStore.getAllKeys(undefined, 2);
    metaKeys.onsuccess = () => {
      if (metaKeys.result.length !== 1 || metaKeys.result[0] !== 'state') { abort(); return; }
      const get = metaStore.get('state');
      get.onsuccess = () => {
        try {
          const meta = get.result;
          if (operation === 'initialize' && exact(meta, ['version', 'identity', 'room']) && meta.version === 0 &&
              meta.identity === identity && meta.room === room) {
            dropSession();
            session = Session.create(identity); inflight = true;
            const fresh = {version: 2, identity, room, public_key: session.public_key(), group_id: new Uint8Array(0),
              format: Session.format_version(), revision: 0, cursor: 0, epoch: 'none', set: new Uint8Array(TAG),
              count: 0, ledger: [], tag: new Uint8Array(TAG)};
            persist(fresh, unframe(session.pending_changes()));
            response = {revision: fresh.revision, cursor: fresh.cursor};
            return;
          }
          validMeta(meta);
          const run = () => { try { step(meta); } catch (_) { abort(); } };
          if (!session || known !== meta.revision) load(meta, run); else run();
        } catch (_) { abort(); }
      };
    };

    function step(meta) {
      if (operation === 'initialize' || operation === 'status') {
        response = {revision: meta.revision, cursor: meta.cursor, operations: meta.ledger.map(x => x.id),
          public_key: Array.from(meta.public_key), entries: meta.count,
          full_serializations: session.full_serializations()};
        return;
      }
      if (operation === 'ack') {
        // Delivered/processed items leave the ledger (§3.5 pruning). Unknown ids reject.
        if (!exact(argument, ['ids']) || !Array.isArray(argument.ids) || !argument.ids.length ||
            argument.ids.length > MAX_LEDGER || new Set(argument.ids).size !== argument.ids.length ||
            !argument.ids.every(id => meta.ledger.some(x => x.id === id))) fail();
        meta.ledger = meta.ledger.filter(x => !argument.ids.includes(x.id));
        persist(meta, []);
        response = {revision: meta.revision, operations: meta.ledger.map(x => x.id)};
        return;
      }
      if (!exact(argument, ['id', 'method', 'bytes', 'sequence', 'fault']) ||
          typeof argument.id !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(argument.id) || !allowed.has(argument.method) ||
          !Number.isSafeInteger(argument.sequence) || argument.sequence < 0 ||
          !['', 'abort-before-write', 'abort-after-write', 'lost-response'].includes(argument.fault)) fail();
      fault = argument.fault;
      const bytes = input(argument.bytes);
      const prior = meta.ledger.find(x => x.id === argument.id);
      if (prior) {
        if (prior.method !== argument.method || prior.sequence !== argument.sequence || !equal(prior.input, bytes) ||
            (prior.method === 'encrypt' && prior.epoch !== meta.epoch)) fail();
        response = {output: Array.from(prior.output), revision: meta.revision, cursor: meta.cursor, replay: true, changed: 0};
        return;
      }
      if (meta.ledger.length >= MAX_LEDGER || meta.revision >= Number.MAX_SAFE_INTEGER) fail();
      if (argument.method === 'decrypt' ? argument.sequence !== meta.cursor + 1 : argument.sequence !== 0) fail();
      // Synchronous WASM call inside the active IDB transaction callback. A
      // rejection has already been rolled back inside the session.
      const result = session.apply(argument.method, bytes);
      inflight = true;
      const output = result.output(), changes = unframe(result.changes());
      meta.epoch = result.epoch();
      meta.group_id = session.group_id();
      result.free();
      meta.ledger.push({id: argument.id, method: argument.method, input: bytes, output, sequence: argument.sequence, epoch: meta.epoch});
      if (argument.method === 'decrypt') meta.cursor = argument.sequence;
      if (fault === 'abort-before-write') { abort(); return; }
      const written = persist(meta, changes);
      if (fault === 'abort-after-write') { abort(); return; }
      response = {output: Array.from(output), revision: meta.revision, cursor: meta.cursor, replay: false,
        changed: changes.length, bytes_written: written};
    }
  });
}
// A timed-out caller must close the worker and reopen the DB, then reconcile its
// exact immutable operation ID.
let queue = Promise.resolve();
self.onmessage = ({data: {id, method, argument}}) => {
  queue = queue.then(async () => {
    try {
      let result;
      if (method === 'init') {
        if (db || !exact(argument, ['identity', 'database', 'room', 'record_key']) ||
            typeof argument.identity !== 'string' || !/^[a-zA-Z0-9_.:-]{1,64}$/.test(argument.identity) ||
            typeof argument.room !== 'string' || !/^[a-z0-9-]{1,64}$/.test(argument.room)) fail();
        const recordKey = input(argument.record_key, 32);
        if (recordKey.length !== 32) fail();
        identity = argument.identity; room = argument.room; key = recordKey;
        db = await open(argument.database);
        result = await transaction('initialize');
      } else {
        if (!db) fail();
        if (method === 'status' || method === 'ack') result = await transaction(method, argument);
        else if (method === 'operation') result = await transaction('operation', argument);
        else fail();
      }
      self.postMessage({id, ok: true, result, memory_bytes: wasm.memory.buffer.byteLength});
    } catch (_) {
      self.postMessage({id, ok: false, error: 'operation rejected', memory_bytes: wasm.memory.buffer.byteLength});
    }
  });
};
self.postMessage({boot: true});
