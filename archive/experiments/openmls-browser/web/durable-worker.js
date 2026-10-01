// Development-only synthetic custody. Record keys come from the custody capsule
// (./pkg/custody.js, #177 M2b-3a); every entry and the meta record are sealed at
// rest (M2b-3b) — see ./session-store.js and PERSISTENCE.md.
// Storage layout, authentication and tab reload: ./session-store.js (see PERSISTENCE.md).
import init, * as api from './pkg/family_mls_browser_experiment.js';
import {createStore, exact, fail, bindEncrypt, bindDecrypt, unframeDecrypt} from './session-store.js';
import {createVault, unlockVault, validPassphrase, sealRecord, openRecord} from './pkg/custody.js';
const wasm = await init();
const allowed = new Set(['key_package', 'create', 'invite', 'join', 'encrypt', 'decrypt', 'remove', 'commit']);
let store, identity, room;
const noExtra = {keys: [], initial: () => ({}), bytes: () => null, valid: () => {}};

function status(ctx, meta) {
  return {revision: meta.revision, cursor: meta.cursor, operations: meta.ledger.map(x => x.id),
    public_key: Array.from(meta.public_key), entries: meta.count,
    full_serializations: ctx.session.full_serializations(), reloads: ctx.reloads, fresh: false};
}
// H1: expose the authenticated sender/client of a decrypt and hand the caller the
// plaintext as `output` (the external contract); the frame is stored in the ledger.
function decrypted(result) {
  if (!result || !result.output) return result;
  const {sender, client, plaintext} = unframeDecrypt(result.output);
  return {...result, output: Array.from(plaintext), sender, client};
}
function handle(operation, argument) {
  return store.transaction((ctx, meta) => {
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
      argument.method === 'encrypt' ? bindEncrypt(room, identity, bytes) :
      argument.method === 'decrypt' ? bindDecrypt(room, bytes) : bytes));
    return argument.method === 'decrypt' ? decrypted(result) : result;
  });
}
// Custody runs outside any IndexedDB transaction (scrypt is asynchronous): a new
// database gets a fresh capsule, an existing one must open with this passphrase.
async function unlock(opened, passphrase) {
  const {fresh, custody} = await opened.readCustody();
  const vault = fresh ? await createVault(passphrase) : null;
  const keys = fresh ? vault.keys : await unlockVault(custody.capsule, custody.vault, passphrase);
  try { opened.unlock(keys.auth, keys.enc, fresh ? vault : custody); }
  catch (error) { keys.auth.fill(0); keys.enc.fill(0); throw error; }
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
        if (store || !exact(argument, ['identity', 'database', 'room', 'passphrase']) ||
            typeof argument.identity !== 'string' || !/^[a-zA-Z0-9_.:-]{1,64}$/.test(argument.identity) ||
            typeof argument.room !== 'string' || !/^[a-z0-9-]{1,64}$/.test(argument.room)) fail();
        identity = argument.identity; room = argument.room;
        const passphrase = validPassphrase(argument.passphrase);
        const opened = createStore(api, {kind: 'durable', identity: argument.identity, room: argument.room, allowed,
          namePattern: /^family-mls-synthetic-[a-z0-9-]{1,64}$/, extra: noExtra, records: {sealRecord, openRecord}});
        await opened.open(argument.database);
        try {
          await unlock(opened, passphrase);
          store = opened;
          result = await handle('initialize');
        } catch (error) {
          // Includes losing a fresh-database race to another tab: close and forget the key.
          opened.close(); store = undefined; throw error;
        }
      } else {
        if (!store || !['status', 'ack', 'operation'].includes(method)) fail();
        result = await handle(method, argument);
      }
      self.postMessage({id, ok: true, result, memory_bytes: wasm.memory.buffer.byteLength});
    } catch (_) {
      self.postMessage({id, ok: false, error: 'operation rejected', memory_bytes: wasm.memory.buffer.byteLength});
    }
  });
};
self.postMessage({boot: true});
