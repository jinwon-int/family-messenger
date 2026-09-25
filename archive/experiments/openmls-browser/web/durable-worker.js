// Development-only synthetic keys in IndexedDB. The record key comes from the
// custody capsule (./pkg/custody.js, #177 M2b-3a); entries are authenticated, not
// yet encrypted (M2b-3b).
// Storage layout, authentication and tab reload: ./session-store.js (see PERSISTENCE.md).
import init, * as api from './pkg/family_mls_browser_experiment.js';
import {createStore, exact, fail} from './session-store.js';
import {createVault, unlockVault, validPassphrase, sodium} from './pkg/custody.js';
const wasm = await init();
const allowed = new Set(['key_package', 'create', 'invite', 'join', 'encrypt', 'decrypt', 'remove', 'commit']);
let store;
const noExtra = {keys: [], initial: () => ({}), bytes: () => null, valid: () => {}};

function status(ctx, meta) {
  return {revision: meta.revision, cursor: meta.cursor, operations: meta.ledger.map(x => x.id),
    public_key: Array.from(meta.public_key), entries: meta.count,
    full_serializations: ctx.session.full_serializations(), reloads: ctx.reloads};
}
function handle(operation, argument) {
  return store.transaction((ctx, meta) => {
    if (meta === null) {
      // Only the pending-initialization marker written at database creation permits key creation.
      if (operation !== 'initialize') fail();
      const fresh = ctx.create();
      return {revision: fresh.revision, cursor: fresh.cursor};
    }
    if (operation === 'initialize' || operation === 'status') return status(ctx, meta);
    if (operation === 'ack') return ctx.ack(meta, argument);
    if (operation !== 'operation') fail();
    return ctx.operation(meta, argument, bytes => ctx.session.apply(argument.method, bytes));
  });
}
// Custody runs outside any IndexedDB transaction (scrypt is asynchronous): a new
// database gets a fresh capsule, an existing one must open with this passphrase.
async function unlock(opened, passphrase) {
  const {fresh, custody} = await opened.readCustody();
  const vault = fresh ? await createVault(passphrase) : null;
  const keys = fresh ? vault.keys : await unlockVault(custody.capsule, custody.vault, passphrase);
  sodium.memzero(keys.enc);  // at-rest encryption key: used from M2b-3b
  opened.unlock(keys.auth, fresh ? vault : custody);
}
// A timed-out caller must close the worker and reopen the DB, then reconcile its
// exact immutable operation ID.
let queue = Promise.resolve();
self.onmessage = ({data: {id, method, argument}}) => {
  queue = queue.then(async () => {
    try {
      let result;
      if (method === 'init') {
        if (store || !exact(argument, ['identity', 'database', 'room', 'passphrase']) ||
            typeof argument.identity !== 'string' || !/^[a-zA-Z0-9_.:-]{1,64}$/.test(argument.identity) ||
            typeof argument.room !== 'string' || !/^[a-z0-9-]{1,64}$/.test(argument.room)) fail();
        const passphrase = validPassphrase(argument.passphrase);
        const opened = createStore(api, {kind: 'durable', identity: argument.identity, room: argument.room, allowed,
          namePattern: /^family-mls-synthetic-[a-z0-9-]{1,64}$/, extra: noExtra});
        await opened.open(argument.database);
        try { await unlock(opened, passphrase); } catch (error) { opened.close(); throw error; }
        store = opened;
        result = await handle('initialize');
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
