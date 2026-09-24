import init, { Device } from './pkg/family_mls_browser_experiment.js';
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
        case 'decrypt': result = device.decrypt(new Uint8Array(argument)); break;
        case 'public_key': result = device.public_key(); break;
        case 'remove': result = device.remove_member(new Uint8Array(argument)); break;
        case 'commit': result = device.apply_commit(new Uint8Array(argument)); break;
        case 'remove_pending': result = device.remove_member_pending(new Uint8Array(argument)); break;
        case 'merge_pending': device.merge_pending(); result = null; break;
        case 'clear_pending': device.clear_pending(); result = null; break;
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
