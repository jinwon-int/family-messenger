// Generated-data library probe only. NOT the native vault or an enrollment API.
// Source, target and private snapshots never leave this worker. No persistence.
import init, {staged_init, staged_apply, staged_trusted_apply, staged_control_apply,
  staged_public_key, staged_group_id, staged_epoch, staged_pending_commit,
  staged_checksum, staged_identity_context} from './pkg/family_mls_browser_experiment.js';
const wasm = await init();
const enc = new TextEncoder(), dec = new TextDecoder();
let identity, source, target, intent, retired = false;
const fail = () => { throw Error('context rejected'); };
const exact = (o, names) => o && Object.getPrototypeOf(o) === Object.prototype &&
  Object.keys(o).sort().join(',') === names.split(',').sort().join(',');
const bytes = (v, max, min = 0) => {
  if (!Array.isArray(v) || v.length < min || v.length > max) fail();
  for (let i = 0; i < v.length; i++) if (!Object.hasOwn(v, i) || !Number.isInteger(v[i]) || v[i] < 0 || v[i] > 255) fail();
  return Uint8Array.from(v);
};
const digest = v => Array.from(staged_checksum(v));
function status(state) {
  if (!state) fail();
  return {key: Array.from(staged_public_key(state, identity)),
    group: Array.from(staged_group_id(state, identity)), epoch: staged_epoch(state, identity),
    pending: staged_pending_commit(state, identity), digest: digest(state),
    entries: JSON.parse(dec.decode(state)).entries.length, bytes: state.length};
}
self.onmessage = ({data}) => {
  let id = null;
  try {
    if (!exact(data, 'id,method,argument') || !Number.isSafeInteger(data.id) || data.id < 1) fail();
    id = data.id;
    if (retired) fail();
    const {method, argument: a} = data;
    let result;
    if (method === 'init') {
      if (source || !['alice', 'bob'].includes(a)) fail();
      identity = a; source = staged_init(identity); result = status(source);
    } else if (method === 'status') {
      if (!['source', 'target'].includes(a)) fail();
      result = status(a === 'source' ? source : target);
    } else if (method === 'fork') {
      if (!source || !exact(a, 'operation,own,group,peer,key') || a.operation !== 'synthetic-new-context-1') fail();
      const own = bytes(a.own, 32, 32), group = bytes(a.group, 128, 16), key = bytes(a.key, 32, 32);
      if (!['alice', 'bob'].includes(a.peer)) fail();
      const canonical = JSON.stringify([a.operation, a.own, a.group, a.peer, a.key]);
      if (target) {
        if (intent !== canonical) fail();
        result = status(target); // Existing memory-only outcome, never regenerate.
      } else {
        const before = digest(source);
        const candidate = staged_identity_context(source, identity, own, group, a.peer, key);
        if (JSON.stringify(before) !== JSON.stringify(digest(source))) fail();
        const checked = status(candidate);
        if (checked.group.length || checked.pending || checked.entries !== 1) fail();
        target = candidate; intent = canonical; result = checked;
      }
    } else if (method === 'op') {
      if (!exact(a, 'context,method,wire,peer,key,aad') || !['source', 'target'].includes(a.context)) fail();
      const state = a.context === 'source' ? source : target;
      if (!state) fail();
      const wire = bytes(a.wire, a.method === 'encrypt' ? 8192 : 65536);
      const key = bytes(a.key, 32, 32), aad = bytes(a.aad, 2048);
      let candidate;
      if (['update', 'merge_update', 'peer_update'].includes(a.method)) {
        candidate = staged_control_apply(state, identity, a.method, wire, a.peer, key, aad);
      } else if (a.method === 'remove' || a.method === 'commit') {
        if (aad.length) fail();
        candidate = staged_apply(state, identity, a.method, wire);
      } else {
        if (aad.length || !['create', 'key_package', 'invite', 'join', 'encrypt', 'decrypt_peer'].includes(a.method)) fail();
        candidate = staged_trusted_apply(state, identity, a.method, wire, a.peer, key);
      }
      try {
        const next = candidate.state(), output = candidate.output(); status(next);
        if (a.context === 'source') source = next; else target = next;
        result = Array.from(output);
      } finally { candidate.free(); }
    } else if (method === 'damage') {
      // Explicit negative fixture: never included in a product worker or bundle.
      if (!source || !['truncated', 'oversize', 'identity', 'key', 'missing-signer'].includes(a)) fail();
      if (a === 'truncated') source = source.slice(0, source.length - 1);
      else if (a === 'oversize') source = new Uint8Array(1048577);
      else {
        const value = JSON.parse(dec.decode(source));
        if (a === 'identity') value.identity = identity === 'alice' ? 'bob' : 'alice';
        if (a === 'key') value.public_key[0] ^= 1;
        if (a === 'missing-signer') value.entries = [];
        source = enc.encode(JSON.stringify(value));
      }
      result = true;
    } else fail();
    if (wasm.memory.buffer.byteLength > 128 * 1024 * 1024) fail();
    self.postMessage({id, ok: true, result, memory_bytes: wasm.memory.buffer.byteLength});
  } catch (_) {
    retired = true; source = target = intent = undefined;
    self.postMessage({id, ok: false, memory_bytes: wasm.memory.buffer.byteLength});
  }
};
self.postMessage({boot: true});
