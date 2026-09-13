// Isolated library qualification only. No directory, native transport or storage.
// Complete provider candidates never leave this worker. No enrollment API.
import init, {staged_init, staged_apply, staged_trusted_apply,
  staged_public_key, staged_group_id, verify_device_package} from './pkg/family_mls_browser_experiment.js';
const wasm = await init();
let state, identity, retired = false;
const bytes = (value, limit) => {
  if (!Array.isArray(value) || value.length > limit) throw Error('bytes');
  for (let i = 0; i < value.length; i++) {
    if (!Object.hasOwn(value, i) || !Number.isInteger(value[i]) || value[i] < 0 || value[i] > 255) throw Error('bytes');
  }
  return Uint8Array.from(value);
};
self.onmessage = ({data}) => {
  let id = null;
  try {
    if (!data || !Number.isSafeInteger(data.id) || data.id < 1) throw Error('event');
    id = data.id;
    const {method, argument: a} = data;
    if (retired) throw Error('retired');
    let result;
    if (method === 'init') {
      if (state || !['alice', 'bob'].includes(a)) throw Error('identity');
      identity = a; state = staged_init(identity);
      result = Array.from(staged_public_key(state, identity));
    } else {
      if (!state) throw Error('missing');
      if (method === 'group') {
        if (a !== null) throw Error('argument');
        result = Array.from(staged_group_id(state, identity));
      } else if (method === 'verify') {
        verify_device_package(bytes(a.wire, 65536), a.peer, bytes(a.key, 32));
        result = true;
      } else {
        let candidate;
        if (['create', 'key_package', 'remove'].includes(method)) {
          if (a !== null) throw Error('argument');
          candidate = staged_apply(state, identity, method, new Uint8Array());
        } else if (method === 'commit' || method === 'raw_decrypt') {
          // Generic removal semantics only, NOT native membership authorization.
          candidate = staged_apply(state, identity, method === 'commit' ? 'commit' : 'decrypt', bytes(a, 65536));
        } else if (['invite', 'join', 'encrypt', 'decrypt_peer'].includes(method)) {
          candidate = staged_trusted_apply(state, identity, method, bytes(a.wire, method === 'encrypt' ? 16384 : 65536), a.peer, bytes(a.key, 32));
        } else throw Error('method');
        try {
          const next = candidate.state();
          const output = candidate.output();
          state = next; // Memory-only commit; not IDB/native acceptance.
          result = Array.from(output);
        } finally { candidate.free(); }
      }
    }
    if (wasm.memory.buffer.byteLength > 128 * 1024 * 1024) throw Error('budget');
    self.postMessage({id, ok: true, result, memory_bytes: wasm.memory.buffer.byteLength});
  } catch (_) {
    retired = true; state = undefined;
    self.postMessage({id, ok: false, memory_bytes: wasm.memory.buffer.byteLength});
  }
};
self.postMessage({boot: true});
