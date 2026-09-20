// Explicit synthetic encrypted-store entry; no fixture fallback.
import {serveNative} from './native-worker.js';
import {NativeVaultStore} from './native-vault-store.js';
await serveNative(new NativeVaultStore());
