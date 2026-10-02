import init, { Device, policy_fingerprint } from './pkg/family_mls_browser_experiment.js';
// H1: the facade frames decrypt output as u32 LE len ‖ sender ‖ u32 LE len ‖
// client ‖ plaintext (Device.decrypt_format() === 2). This passthrough worker
// returns the plaintext; the authenticated sender/client are in the frame.
const decryptPlaintext = framed => {
  const view = new DataView(framed.buffer, framed.byteOffset, framed.byteLength);
  let at = 0;
  for (let i = 0; i < 2; i++) { const n = view.getUint32(at, true); at += 4 + n; }
  return framed.slice(at);
};
const started = performance.now();
const wasm = await init();
const initMs = performance.now() - started;
let device;
let peak = wasm.memory.buffer.byteLength;
self.onmessage = ({data: {id, method, argument}}) => {
  try {
    let result;
    if (method === 'init') {
      if (device) throw new Error('already initialized');
      device = new Device(argument);
      result = {init_ms: initMs};
    } else {
      if (!device) throw new Error('not initialized');
      switch (method) {
        case 'key_package': result = device.key_package(); break;
        case 'create': result = device.create(); break;
        case 'invite': result = device.invite(new Uint8Array(argument)); break;
        case 'invite_with_commit': result = device.invite_with_commit(new Uint8Array(argument)); break;
        case 'join': result = device.join(new Uint8Array(argument)); break;
        case 'encrypt': result = device.encrypt(new Uint8Array(argument)); break;
        case 'decrypt': result = decryptPlaintext(device.decrypt(new Uint8Array(argument))); break;
        case 'public_key': result = device.public_key(); break;
        case 'fingerprint': result = device.fingerprint(); break;
        case 'members': result = device.members(); break;
        // M2: roster after a pending commit merges — the list to replicate into the
        // outer v2 relay commit JSON before POSTing (members() is still the old epoch).
        case 'members_after_pending': result = device.members_after_pending(); break;
        case 'policy_fingerprint': result = policy_fingerprint(argument); break;
        case 'sign_approval':
          if (!argument || typeof argument !== 'object') throw new Error('bad argument');
          result = device.sign_approval(argument.action, argument.device_id, argument.actor,
            argument.subject, argument.signing_key, argument.acceptance,
            BigInt(argument.base_revision));
          break;
        case 'remove': result = device.remove_member(new Uint8Array(argument)); break;
        case 'commit': result = device.apply_commit(new Uint8Array(argument)); break;
        case 'remove_pending': result = device.remove_member_pending(new Uint8Array(argument)); break;
        case 'merge_pending': device.merge_pending(); result = null; break;
        case 'clear_pending': device.clear_pending(); result = null; break;
        case 'has_pending': result = device.has_pending(); break;
        // Review 2 J-HA (#231): the two-phase incoming commit — stage (report:
        // adds/removes/update-proposals/committer path as four frame_members
        // sections, stage_report_format() === 2), then merge or discard after
        // the caller's policy check — was on the facade but reachable from no
        // worker; `commit` merges unchecked.
        case 'stage_commit': result = device.stage_commit(new Uint8Array(argument)); break;
        case 'merge_staged': device.merge_staged(); result = null; break;
        case 'discard_staged': device.discard_staged(); result = null; break;
        default: throw new Error('unknown method');
      }
    }
    peak = Math.max(peak, wasm.memory.buffer.byteLength);
    if (peak > 128 * 1024 * 1024) throw new Error('memory budget exceeded');
    self.postMessage({id, ok: true, result: result instanceof Uint8Array ? Array.from(result) : result, memory_bytes: peak});
  } catch (_) {
    // No message content, key state, or library diagnostics leave this worker.
    peak = Math.max(peak, wasm.memory.buffer.byteLength);
    self.postMessage({id, ok: false, error: 'operation rejected', memory_bytes: peak});
  }
};
self.postMessage({boot: true});
