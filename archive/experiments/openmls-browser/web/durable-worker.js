// Development-only synthetic custody. Record keys come from the custody capsule
// (./pkg/custody.js, #177 M2b-3a); every entry and the meta record are sealed at
// rest (M2b-3b) — see ./session-store.js and PERSISTENCE.md.
// Storage layout, authentication and tab reload: ./session-store.js (see PERSISTENCE.md).
//
// Two modes (PERSISTENCE.md "다중 스토어", #431 stage 4):
//   single — `init {identity, database, room, passphrase}`: one store, one room (relay-app).
//   multi  — `init_multi {identity, passphrase, identity_database, legacy?}` then
//            `open_room {room, database, from}`: one identity store (room `-identity`, the
//            signer only) and any number of room stores that share its signing key — one
//            policy-chain enrollment, several rooms (iOS `_identity`/`_lobby` slots). A fresh
//            room store is cloned inside this worker from the identity store (group-less) or
//            from the lobby store `-lobby` (signer + unused lobby key package secrets, so a
//            Welcome built from a lobby key package can be joined). Room-scoped messages carry
//            `room`. Secrets never cross postMessage: clone bytes are produced and consumed
//            here, and the custody KDF runs once (sibling stores share the unlocked keys and
//            the identity store's custody record).
import init, * as api from './pkg/family_mls_browser_experiment.js';
import {createStore, exact, fail, bindEncrypt, bindDecrypt, unframeDecrypt, wipeAll} from './session-store.js';
import {createVault, unlockVault, validPassphrase, sealRecord, openRecord} from './pkg/custody.js';
import {openHistory, historyName} from './history-store.js';
const wasm = await init();
// `delete_key_package` (review 2 L-3): the M4 outstanding-package cap had no
// recovery path in this lane except a join.
// #243 2-a human relay client (web/relay-app.js): the deferred-merge commit
// flow (invite_with_commit → own echo → merge_pending; clear_pending on a 409),
// pending removal, and the read-only roster/fingerprint/approval views that
// used to exist only on the memory worker.
const allowed = new Set(['key_package', 'delete_key_package', 'create', 'invite', 'invite_with_commit', 'join',
  'encrypt', 'decrypt', 'remove', 'remove_pending', 'commit', 'merge_pending', 'clear_pending',
  'members', 'members_after_pending', 'fingerprint', 'policy_fingerprint', 'sign_approval',
  // #261 two-step commit application: stage (transient report) → merge or discard.
  'stage_commit', 'merge_staged', 'discard_staged']);
const NAME = /^family-mls-synthetic-[a-z0-9-]{1,64}$/;
const ROOM = /^[a-z0-9-]{1,64}$/;
const IDENTITY_ROOM = '-identity', LOBBY_ROOM = '-lobby';   // never a relay room: those start with [a-z0-9]
const noExtra = {keys: [], initial: () => ({}), bytes: () => null, valid: () => {}};

let mode = null;              // 'single' | 'multi'
let identity = null;
// single mode: the one store; multi mode: room → {store, history, database}
let store, room;
let history = null;
const stores = new Map();
// multi mode: the identity store's unlocked keys + custody record (sharedKeys) and the
// passphrase, kept to unlock a store sealed under another capsule (a legacy single-store
// database being migrated). Worker memory only.
let shared = null, passphrase = null;

function status(ctx, meta) {
  return {revision: meta.revision, cursor: meta.cursor, operations: meta.ledger.map(x => x.id),
    public_key: Array.from(meta.public_key), entries: meta.count,
    full_serializations: ctx.session.full_serializations(), reloads: ctx.reloads, fresh: false};
}
// H1: expose the authenticated sender/client of a decrypt and hand the caller the
// plaintext as `output` (the external contract); the frame is stored in the ledger.
// H2: a poison-message tombstone ({rejected: true, sequence, cursor, …}, no output)
// is returned as-is inside the normal `ok: true` envelope — it is a verdict the
// store persisted, not a failure of this worker.
function decrypted(result) {
  if (!result || result.rejected === true || !result.output) return result;
  const {sender, client, plaintext} = unframeDecrypt(result.output);
  return {...result, output: Array.from(plaintext), sender, client};
}
function handleOn(st, bound, operation, argument) {
  return st.transaction((ctx, meta) => {
    if (meta === null) {
      // Only the pending-initialization marker written at database creation permits key creation.
      if (operation !== 'initialize') fail();
      const key = ctx.create();
      // H3: tell the caller a key was just generated, so a panel can detect a
      // storage wipe (fresh key under a database it has used before) and warn
      // instead of silently becoming a new device.
      return {revision: key.revision, cursor: key.cursor, fresh: true};
    }
    if (operation === 'initialize' || operation === 'status') return status(ctx, meta);
    if (operation === 'ack') return ctx.ack(meta, argument);
    if (operation !== 'operation') fail();
    // §3.6: the room and client come from this worker's own init, never from
    // the per-operation request, so a caller cannot re-room a ciphertext.
    const result = ctx.operation(meta, argument, bytes => ctx.session.apply(argument.method,
      argument.method === 'encrypt' ? bindEncrypt(bound, identity, bytes) :
      argument.method === 'decrypt' ? bindDecrypt(bound, bytes) : bytes));
    return argument.method === 'decrypt' ? decrypted(result) : result;
  });
}
const handle = (operation, argument) => handleOn(store, room, operation, argument);

// Custody runs outside any IndexedDB transaction (scrypt is asynchronous): a new
// database gets a fresh capsule, an existing one must open with this passphrase.
async function unlock(opened, passphrase) {
  const {fresh, custody} = await opened.readCustody();
  const vault = fresh ? await createVault(passphrase) : null;
  const keys = fresh ? vault.keys : await unlockVault(custody.capsule, custody.vault, passphrase);
  try { opened.unlock(keys.auth, keys.enc, fresh ? vault : custody); }
  catch (error) { keys.auth.fill(0); keys.enc.fill(0); throw error; }
}
// Multi mode: a sibling store sealed under the identity's capsule reuses the unlocked
// keys (no KDF); a fresh database adopts that capsule; any other capsule (legacy
// database) is unlocked with the passphrase. Returns whether the database was fresh.
async function unlockShared(opened) {
  const {fresh, custody} = await opened.readCustody();
  if (fresh) {
    if (shared) { opened.unlock(shared.auth.slice(), shared.enc.slice(), shared.custody); return true; }
    const vault = await createVault(passphrase);
    try { opened.unlock(vault.keys.auth, vault.keys.enc, vault); } catch (error) { vault.keys.auth.fill(0); vault.keys.enc.fill(0); throw error; }
    return true;
  }
  if (shared && custody.vault === shared.custody.vault && sameBytes(custody.capsule, shared.custody.capsule)) {
    opened.unlock(shared.auth.slice(), shared.enc.slice(), custody); return false;
  }
  const keys = await unlockVault(custody.capsule, custody.vault, passphrase);
  try { opened.unlock(keys.auth, keys.enc, custody); } catch (error) { keys.auth.fill(0); keys.enc.fill(0); throw error; }
  return false;
}
const sameBytes = (a, b) => a instanceof Uint8Array && b instanceof Uint8Array && a.length === b.length && a.every((x, i) => x === b[i]);

function openStore(name, database) {
  return createStore(api, {kind: 'durable', identity, room: name, allowed, namePattern: NAME, extra: noExtra,
    records: {sealRecord, openRecord}});
}
async function attachHistory(opened, database, name) {
  try {
    return await openHistory(database, {identity, room: name,
      seal: (ad, bytes) => opened.sealAux(ad, bytes), open: (ad, sealed) => opened.openAux(ad, sealed)});
  } catch (_) { return null; }
}
function entry(name) {
  const st = stores.get(name);
  if (!st) fail();
  return st;
}
/** Status/initialize envelope of one store (meta read inside a transaction). */
const statusOf = st => handleOn(st.store, st.room, 'status');

// ---- multi mode ----
async function initMulti(argument) {
  if (mode || !exact(argument, ['identity', 'passphrase', 'identity_database', 'legacy']) && !exact(argument, ['identity', 'passphrase', 'identity_database'])) fail();
  if (typeof argument.identity !== 'string' || !/^[a-zA-Z0-9_.:-]{1,64}$/.test(argument.identity) ||
      typeof argument.identity_database !== 'string' || !NAME.test(argument.identity_database)) fail();
  const legacy = argument.legacy ?? null;
  if (legacy !== null && (!exact(legacy, ['database', 'room']) || !NAME.test(legacy.database) || !ROOM.test(legacy.room) ||
      legacy.database === argument.identity_database)) fail();
  identity = argument.identity;
  passphrase = validPassphrase(argument.passphrase);
  const opened = openStore(IDENTITY_ROOM, argument.identity_database);
  await opened.open(argument.identity_database);
  let migrated = false, result;
  // Coarse failure stage for the page's fatal screen / self-heal (#431): never a secret.
  let stage = 'identity_unlock';
  try {
    const fresh = await unlockShared(opened);
    stage = 'identity_initialize';
    if (fresh && legacy !== null && await databaseExists(legacy.database)) {
      // Migration: the signer of a single-store database becomes the identity store.
      // The legacy store's custody record is adopted so that database (and every
      // later sibling) shares one capsule — one KDF per start from now on.
      stage = 'legacy_open';
      const old = openStore(legacy.room, legacy.database);
      await old.open(legacy.database);
      let blob = null, publicKey = null;
      try {
        stage = 'legacy_unlock';
        if (await unlockShared(old)) fail();   // a fresh legacy database is not a legacy
        stage = 'legacy_export';
        ({blob, publicKey} = await old.transaction((ctx, meta) => { if (meta === null) fail(); return {blob: ctx.exportIdentity(), publicKey: meta.public_key}; }));
        stage = 'identity_create';
        opened.close();
        const adopted = openStore(IDENTITY_ROOM, argument.identity_database);
        await adopted.open(argument.identity_database);
        const keys = old.sharedKeys();
        adopted.unlock(keys.auth, keys.enc, keys.custody);
        result = await adopted.transaction((ctx, meta) => { if (meta !== null) fail(); const m = ctx.createIdentity(publicKey, blob); return {revision: m.revision, cursor: m.cursor, fresh: true}; });
        stores.set(IDENTITY_ROOM, {store: adopted, room: IDENTITY_ROOM, database: argument.identity_database, history: null});
        shared = adopted.sharedKeys();
        migrated = true;
      } finally { if (blob) wipeAll(blob); old.close(); }
    } else {
      result = await handleOn(opened, IDENTITY_ROOM, 'initialize');
      stores.set(IDENTITY_ROOM, {store: opened, room: IDENTITY_ROOM, database: argument.identity_database, history: null});
      shared = opened.sharedKeys();
    }
  } catch (error) {
    opened.close(); for (const st of stores.values()) st.store.close(); stores.clear(); shared = null; passphrase = null; identity = null;
    throw Object.assign(error instanceof Error ? error : new Error('rejected'), {stage});
  }
  mode = 'multi';
  const st = stores.get(IDENTITY_ROOM);
  const now = result.fresh ? await statusOf(st) : result;
  return {fresh: result.fresh === true, migrated, public_key: now.public_key, revision: now.revision, cursor: now.cursor};
}
function databaseExists(name) {
  return new Promise(resolve => {
    // `databases()` is the only non-creating probe; a browser without it reports "unknown" → false.
    if (typeof indexedDB.databases !== 'function') { resolve(false); return; }
    indexedDB.databases().then(list => resolve(list.some(d => d.name === name))).catch(() => resolve(false));
  });
}
async function openRoom(argument) {
  if (mode !== 'multi' || !exact(argument, ['room', 'database', 'from']) || typeof argument.room !== 'string' || !ROOM.test(argument.room) ||
      argument.room === IDENTITY_ROOM || !NAME.test(argument.database) || !['identity', 'lobby'].includes(argument.from) ||
      (argument.room === LOBBY_ROOM && argument.from !== 'identity')) fail();
  const name = argument.room;
  if (stores.has(name)) {   // idempotent: already open
    const st = stores.get(name);
    if (st.database !== argument.database) fail();
    const now = await statusOf(st);
    return {fresh: false, revision: now.revision, cursor: now.cursor, public_key: now.public_key, history: st.history !== null};
  }
  for (const st of stores.values()) if (st.database === argument.database) fail();   // one database, one room
  const opened = openStore(name, argument.database);
  await opened.open(argument.database);
  try {
    const fresh = await unlockShared(opened);
    let result;
    if (fresh) {
      // Clone inside the worker: identity (signer only) or lobby (signer + lobby key packages).
      const source = entry(argument.from === 'lobby' ? LOBBY_ROOM : IDENTITY_ROOM);
      if (argument.from === 'lobby') {
        const {public_key, entries} = await source.store.transaction((ctx, meta) => { if (meta === null) fail(); return ctx.exportEntries(); });
        try { result = await opened.transaction((ctx, meta) => { if (meta !== null) fail(); const m = ctx.createClone(public_key, entries); return {revision: m.revision, cursor: m.cursor}; }); }
        finally { wipeAll(entries); }
      } else {
        const {blob, public_key} = await source.store.transaction((ctx, meta) => { if (meta === null) fail(); return {blob: ctx.exportIdentity(), public_key: meta.public_key}; });
        try { result = await opened.transaction((ctx, meta) => { if (meta !== null) fail(); const m = ctx.createIdentity(public_key, blob); return {revision: m.revision, cursor: m.cursor}; }); }
        finally { wipeAll(blob); }
      }
    } else {
      result = await handleOn(opened, name, 'initialize');
      if (result.fresh) fail();
    }
    const hist = name === LOBBY_ROOM ? null : await attachHistory(opened, argument.database, name);
    const st = {store: opened, room: name, database: argument.database, history: hist};
    stores.set(name, st);
    const now = await statusOf(st);
    if (!sameBytes(Uint8Array.from(now.public_key), Uint8Array.from(shared ? (await statusOf(entry(IDENTITY_ROOM))).public_key : now.public_key))) { closeRoom(name); fail(); }
    return {fresh, revision: now.revision, cursor: now.cursor, public_key: now.public_key, history: hist !== null};
  } catch (error) { opened.close(); throw error; }
}
function closeRoom(name) {
  const st = stores.get(name);
  if (!st) return;
  try { st.history?.close(); } catch (_) {}
  st.store.close();
  stores.delete(name);
}
function deleteDatabase(name) {
  return new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase(name);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(new Error('deleteDatabase failed'));
    request.onblocked = () => reject(new Error('deleteDatabase blocked'));
  });
}
async function resetRoom(argument) {
  if (mode !== 'multi' || !exact(argument, ['room', 'database']) || !ROOM.test(argument.room) || argument.room === IDENTITY_ROOM ||
      !NAME.test(argument.database) || argument.database === entry(IDENTITY_ROOM).database) fail();
  const st = stores.get(argument.room);
  if (st && st.database !== argument.database) fail();
  closeRoom(argument.room);
  await deleteDatabase(argument.database);
  await deleteDatabase(historyName(argument.database));
  return {};
}
/** Room-scoped dispatch of the single-store messages. */
async function roomMessage(method, argument) {
  if (mode !== 'multi' || !argument || typeof argument.room !== 'string') fail();
  const {room: name, ...rest} = argument;
  const st = entry(name);
  if (method === 'history_put' || method === 'history_list' || method === 'history_get') {
    if (!st.history) fail();
    if (method === 'history_put') return st.history.put(rest);
    if (method === 'history_list') { if (!exact(rest, ['limit'])) fail(); return st.history.list(rest.limit); }
    if (!exact(rest, ['seq'])) fail();
    return {bytes: Array.from(await st.history.get(rest.seq))};
  }
  if (!['status', 'ack', 'operation'].includes(method)) fail();
  return handleOn(st.store, name, method, rest);
}

// A timed-out caller must close the worker and reopen the DB, then reconcile its
// exact immutable operation ID.
let queue = Promise.resolve();
self.onmessage = ({data}) => {
  queue = queue.then(async () => {
    let id;
    try {
      // Validate the message envelope like trusted-state-worker.js (low item).
      if (!exact(data, ['id', 'method', 'argument']) || !Number.isSafeInteger(data.id) || data.id < 1 ||
          typeof data.method !== 'string') fail();
      id = data.id;
      const {method, argument} = data;
      let result;
      if (method === 'init') {
        if (mode || store || !exact(argument, ['identity', 'database', 'room', 'passphrase']) ||
            typeof argument.identity !== 'string' || !/^[a-zA-Z0-9_.:-]{1,64}$/.test(argument.identity) ||
            typeof argument.room !== 'string' || !ROOM.test(argument.room)) fail();
        identity = argument.identity; room = argument.room;
        const passphrase = validPassphrase(argument.passphrase);
        const opened = createStore(api, {kind: 'durable', identity: argument.identity, room: argument.room, allowed,
          namePattern: NAME, extra: noExtra, records: {sealRecord, openRecord}});
        await opened.open(argument.database);
        try {
          await unlock(opened, passphrase);
          store = opened;
          result = await handle('initialize');
          try {
            history = await openHistory(argument.database, {identity, room,
              seal: (ad, bytes) => opened.sealAux(ad, bytes), open: (ad, sealed) => opened.openAux(ad, sealed)});
          } catch (_) { history = null; }
          result = {...result, history: history !== null};
          mode = 'single';
        } catch (error) {
          // Includes losing a fresh-database race to another tab: close and forget the key.
          opened.close(); store = undefined; identity = null; throw error;
        }
      } else if (method === 'init_multi') {
        result = await initMulti(argument);
      } else if (method === 'open_room') {
        result = await openRoom(argument);
      } else if (method === 'close_room') {
        if (mode !== 'multi' || !exact(argument, ['room']) || !ROOM.test(argument.room) || argument.room === IDENTITY_ROOM) fail();
        closeRoom(argument.room); result = {};
      } else if (method === 'reset_room') {
        result = await resetRoom(argument);
      } else if (mode === 'multi') {
        result = await roomMessage(method, argument);
      } else if (method === 'history_put' || method === 'history_list' || method === 'history_get') {
        if (!store || !history) fail();
        if (method === 'history_put') result = await history.put(argument);
        else if (method === 'history_list') {
          if (!exact(argument, ['limit'])) fail();
          result = await history.list(argument.limit);
        } else {
          if (!exact(argument, ['seq'])) fail();
          result = {bytes: Array.from(await history.get(argument.seq))};
        }
      } else {
        if (!store || !['status', 'ack', 'operation'].includes(method)) fail();
        result = await handle(method, argument);
      }
      self.postMessage({id, ok: true, result, memory_bytes: wasm.memory.buffer.byteLength});
    } catch (error) {
      const reply = {id, ok: false, error: 'operation rejected', memory_bytes: wasm.memory.buffer.byteLength};
      if (data?.method === 'init_multi' && typeof error?.stage === 'string') reply.stage = error.stage;
      self.postMessage(reply);
    }
  });
};
self.postMessage({boot: true});
