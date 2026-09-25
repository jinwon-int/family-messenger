// Development-only synthetic keys in IndexedDB. No production key protection:
// entries are authenticated (HMAC) but not encrypted until the custody stack (#177 M2b-3).
// Storage layout, authentication and tab reload: ./session-store.js (see PERSISTENCE.md).
// Trust: a pinned pair (independent ceremony) that must match the live directory
// on every transaction; the Session enforces the pinned membership in Rust.
import init, * as api from './pkg/family_mls_browser_experiment.js';
import {createStore, exact, fail, input, hex, fromHex} from './session-store.js';
import {normalizePins, readDirectory, matchDirectory} from './trust-directory.js';
const wasm = await init();
const allowed = new Set(['key_package', 'create', 'invite', 'join', 'encrypt', 'decrypt']);
let store, identity, room, retired = false;

// Pins are an authenticated meta field. Checked whenever the session is rebuilt
// from durable entries (and when first set): canonical form, own pin = our
// signer, and the group holds exactly our leaf plus the pinned peer.
const pinsExtra = {
  keys: ['pins'],
  initial: () => ({pins: null}),
  bytes: meta => meta.pins,
  valid(meta, session) {
    if (meta.pins === null) {
      if (meta.ledger.length !== 0 || meta.group_id.length !== 0 || meta.epoch !== 'none') fail();
      return;
    }
    const pins = normalizePins(meta.pins);
    if (JSON.stringify(pins) !== JSON.stringify(meta.pins)) fail();
    const own = pins.find(x => x.actor === identity), peer = pins.find(x => x.actor !== identity);
    if (!own || !peer || own.signing_key !== hex(session.public_key())) fail();
    session.check_trust(peer.actor, fromHex(peer.signing_key));
  },
};

// The live directory must agree on every transaction (revocation blocks even cached output).
function current(meta, directory) {
  if (meta.pins !== null) { matchDirectory(meta.pins, directory); return; }
  const own = directory.devices.find(x => x.actor === identity);
  if (own && (own.status !== 'active' || own.signing_key !== hex(meta.public_key))) fail();
}
function publicStatus(ctx, meta) {
  return {revision: meta.revision, cursor: meta.cursor, operations: meta.ledger.map(x => x.id), pins: meta.pins,
    public_key: Array.from(meta.public_key), group_id: hex(meta.group_id), reloads: ctx.reloads};
}
function handle(operation, argument, directory) {
  return store.transaction((ctx, meta) => {
    if (meta === null) {
      // A device the directory already knows must never silently regenerate keys.
      if (operation !== 'initialize' || directory.devices.some(x => x.actor === identity)) fail();
      meta = ctx.create();
      current(meta, directory);
      return publicStatus(ctx, meta);
    }
    current(meta, directory);
    if (operation === 'initialize' || operation === 'status') return publicStatus(ctx, meta);
    if (operation === 'pin') {
      if (!exact(argument, ['pins', 'fault'])) fail();
      const pins = normalizePins(argument.pins);
      matchDirectory(pins, directory);
      if (meta.pins !== null) {
        // Accepted pins can never be replaced; the same pins are an idempotent retry.
        if (JSON.stringify(meta.pins) !== JSON.stringify(pins)) fail();
        return publicStatus(ctx, meta);
      }
      const done = ctx.update(meta, m => { m.pins = pins; pinsExtra.valid(m, ctx.session); }, argument.fault);
      return done ? publicStatus(ctx, meta) : undefined;
    }
    if (meta.pins === null) fail();
    if (operation === 'ack') return ctx.ack(meta, argument);
    if (operation !== 'operation') fail();
    const peer = meta.pins.find(x => x.actor !== identity);
    return ctx.operation(meta, argument,
      bytes => ctx.session.apply_trusted(argument.method, bytes, peer.actor, fromHex(peer.signing_key)));
  });
}
// Network admission is always outside IDB; each transaction re-reads and
// re-validates the current meta. Any failure retires this worker.
let queue = Promise.resolve();
self.onmessage = ({data}) => {
  queue = queue.then(async () => {
    let id;
    try {
      if (!exact(data, ['id', 'method', 'argument']) || !Number.isSafeInteger(data.id) || data.id < 1 || typeof data.method !== 'string') fail();
      id = data.id;
      const {method, argument} = data;
      if (retired) fail();
      let result;
      if (method === 'init') {
        if (store || !exact(argument, ['identity', 'room', 'database', 'record_key']) ||
            typeof argument.identity !== 'string' || !/^[a-zA-Z0-9_.:-]{1,64}$/.test(argument.identity) ||
            typeof argument.room !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(argument.room)) fail();
        const key = input(argument.record_key, 32);
        if (key.length !== 32) fail();
        identity = argument.identity; room = argument.room;
        const directory = await readDirectory(identity, room);
        const opened = createStore(api, {identity, room, key, allowed, extra: pinsExtra,
          namePattern: /^family-mls-trusted-synthetic-[a-z0-9-]{1,64}$/});
        await opened.open(argument.database);
        store = opened;
        result = await handle('initialize', undefined, directory);
      } else {
        if (!store || !['status', 'pin', 'ack', 'operation'].includes(method)) fail();
        const directory = await readDirectory(identity, room);
        result = await handle(method, argument, directory);
      }
      if (wasm.memory.buffer.byteLength > 128 * 1024 * 1024) fail();
      self.postMessage({id, ok: true, result, memory_bytes: wasm.memory.buffer.byteLength});
    } catch (_) {
      retired = true;
      if (store) { store.close(); store = undefined; }
      self.postMessage({id, ok: false, error: 'trusted state rejected', memory_bytes: wasm.memory.buffer.byteLength});
    }
  });
};
self.postMessage({boot: true});
