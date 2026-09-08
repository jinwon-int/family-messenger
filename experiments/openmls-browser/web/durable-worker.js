// Development-only synthetic keys in IndexedDB. No production key protection.
import init, {staged_init, staged_apply, staged_epoch} from './pkg/family_mls_browser_experiment.js';
const wasm = await init();
const MAX_STATE = 1024 * 1024, MAX_BINARY = 2 * 1024 * 1024, MAX_LEDGER = 32;
const allowed = new Set(['key_package', 'create', 'invite', 'join', 'encrypt', 'decrypt', 'remove', 'commit']);
let db, identity;
const fail = () => { throw new Error('rejected'); };
const exact = (value, keys) => value && Object.getPrototypeOf(value) === Object.prototype &&
  Object.keys(value).sort().join(',') === keys.sort().join(',');
const equal = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
function input(value) {
  if (!Array.isArray(value) || value.length > 65536 || !value.every(v => Number.isInteger(v) && v >= 0 && v <= 255)) fail();
  return new Uint8Array(value);
}
function valid(record) {
  if (!exact(record, ['version', 'identity', 'revision', 'crypto', 'ledger', 'cursor', 'epoch']) || record.version !== 1 ||
      record.identity !== identity || typeof record.epoch !== 'string' || !Number.isSafeInteger(record.revision) || record.revision < 1 ||
      !Number.isSafeInteger(record.cursor) || record.cursor < 0 ||
      !(record.crypto instanceof Uint8Array) || !record.crypto.length || record.crypto.length > MAX_STATE ||
      !Array.isArray(record.ledger) || record.ledger.length > MAX_LEDGER || record.revision !== record.ledger.length + 1) fail();
  let size = record.crypto.length, cursor = 0;
  const ids = new Set();
  for (const item of record.ledger) {
    if (!exact(item, ['id', 'method', 'input', 'output', 'sequence', 'epoch']) ||
        typeof item.id !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(item.id) || ids.has(item.id) || !allowed.has(item.method) || typeof item.epoch !== 'string' ||
        !(item.input instanceof Uint8Array) || item.input.length > 65536 ||
        !(item.output instanceof Uint8Array) || item.output.length > 65536 ||
        !Number.isSafeInteger(item.sequence) || item.sequence < 0) fail();
    if (item.method === 'decrypt' ? item.sequence !== ++cursor : item.sequence !== 0) fail();
    ids.add(item.id); size += item.input.length + item.output.length;
  }
  if (cursor !== record.cursor || size > MAX_BINARY || staged_epoch(record.crypto, identity) !== record.epoch) fail();
}
function open(name) {
  if (typeof name !== 'string' || !/^family-mls-synthetic-[a-z0-9-]{1,64}$/.test(name)) fail();
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = event => {
      if (event.oldVersion !== 0) { request.transaction.abort(); return; }
      request.result.createObjectStore('device').add({version: 0, identity}, 'state');
    };
    request.onerror = () => reject(new Error('state unavailable'));
    request.onblocked = () => reject(new Error('state blocked'));
    request.onsuccess = () => {
      const opened = request.result;
      if (opened.objectStoreNames.length !== 1 || !opened.objectStoreNames.contains('device')) {
        opened.close(); reject(new Error('unknown schema')); return;
      }
      opened.onversionchange = () => opened.close();
      resolve(opened);
    };
  });
}
function transaction(operation, argument) {
  return new Promise((resolve, reject) => {
    // Cross-tab read/write transactions serialize the complete read-modify-write.
    const tx = db.transaction('device', 'readwrite', {durability: 'strict'});
    const store = tx.objectStore('device');
    let response, fault;
    const abort = () => { try { tx.abort(); } catch (_) {} };
    tx.onerror = () => {}; // onabort is the single failure result.
    tx.onabort = () => reject(new Error('transaction rejected'));
    tx.oncomplete = () => {
      // Test-only lost-response fault. Durable state may now contain the operation.
      if (fault !== 'lost-response') resolve(response);
    };
    const keys = store.getAllKeys(undefined, 2);
    keys.onsuccess = () => {
      if (keys.result.length > 1 || (keys.result.length && keys.result[0] !== 'state')) { abort(); return; }
      const get = store.get('state');
      get.onsuccess = () => {
        try {
          let record = get.result;
          if (operation === 'initialize') {
            if (exact(record, ['version', 'identity']) && record.version === 0 && record.identity === identity) {
              record = {version: 1, identity, revision: 1, crypto: staged_init(identity), ledger: [], cursor: 0, epoch: 'none'};
              valid(record); store.put(record, 'state');
            } else valid(record);
            response = {revision: record.revision, cursor: record.cursor};
            return;
          }
          valid(record);
          if (operation === 'status') {
            response = {revision: record.revision, cursor: record.cursor, operations: record.ledger.map(x => x.id)};
            return;
          }
          if (!exact(argument, ['id', 'method', 'bytes', 'sequence', 'fault']) ||
              typeof argument.id !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(argument.id) || !allowed.has(argument.method) ||
              !Number.isSafeInteger(argument.sequence) || argument.sequence < 0 ||
              !['', 'abort-before-write', 'abort-after-write', 'lost-response'].includes(argument.fault)) fail();
          fault = argument.fault;
          const bytes = input(argument.bytes);
          const prior = record.ledger.find(x => x.id === argument.id);
          if (prior) {
            if (prior.method !== argument.method || prior.sequence !== argument.sequence || !equal(prior.input, bytes) ||
                (prior.method === 'encrypt' && prior.epoch !== record.epoch)) fail();
            response = {output: Array.from(prior.output), revision: record.revision, cursor: record.cursor, replay: true};
            return;
          }
          if (record.ledger.length >= MAX_LEDGER || record.revision >= Number.MAX_SAFE_INTEGER) fail();
          if (argument.method === 'decrypt' ? argument.sequence !== record.cursor + 1 : argument.sequence !== 0) fail();
          let candidate;
          try {
            // Synchronous WASM call inside the active IDB transaction callback.
            // It constructs a fresh provider; no candidate state survives an abort.
            candidate = staged_apply(record.crypto, identity, argument.method, bytes);
            record.crypto = candidate.state();
            record.epoch = candidate.epoch();
            const output = candidate.output();
            record.ledger.push({id: argument.id, method: argument.method, input: bytes, output, sequence: argument.sequence, epoch: record.epoch});
            record.revision++;
            if (argument.method === 'decrypt') record.cursor = argument.sequence;
            valid(record);
            if (fault === 'abort-before-write') { abort(); return; }
            store.put(record, 'state');
            if (fault === 'abort-after-write') { abort(); return; }
            response = {output: Array.from(output), revision: record.revision, cursor: record.cursor, replay: false};
          } finally { if (candidate) candidate.free(); }
        } catch (_) { abort(); }
      };
    };
  });
}
// No crypto object is retained between commands. A timed-out caller must close
// the worker and reopen the DB, then reconcile its exact immutable operation ID.
let queue = Promise.resolve();
self.onmessage = ({data: {id, method, argument}}) => {
  queue = queue.then(async () => {
    try {
      let result;
      if (method === 'init') {
        if (db || !exact(argument, ['identity', 'database']) ||
            !['alice', 'bob', 'outsider', 'alice-second'].includes(argument.identity)) fail();
        identity = argument.identity; db = await open(argument.database);
        result = await transaction('initialize');
      } else {
        if (!db) fail();
        if (method === 'status') result = await transaction('status');
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
