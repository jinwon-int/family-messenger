// CI-only smoke: proves the pinned matrix-js-sdk loads in Node and
// exposes the Rust crypto (WASM) surface the adapter depends on.
// Requires `npm install` first (see .github/workflows/web.yml).

import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

function check(label, condition) {
  if (!condition) {
    console.error(`transport smoke failed: ${label}`);
    process.exit(1);
  }
  console.log(`ok: ${label}`);
}

const sdk = require('matrix-js-sdk');
check('createClient export', typeof sdk.createClient === 'function');
check('MatrixClient export', typeof sdk.MatrixClient === 'function');
check('MatrixClient#initRustCrypto (rust/WASM crypto)', typeof sdk.MatrixClient.prototype.initRustCrypto === 'function');
check('MatrixClient#login (m.login.password)', typeof sdk.MatrixClient.prototype.login === 'function');
check('MatrixClient#uploadContent', typeof sdk.MatrixClient.prototype.uploadContent === 'function');

const cryptoWasm = require('@matrix-org/matrix-sdk-crypto-wasm');
check('@matrix-org/matrix-sdk-crypto-wasm resolvable', Boolean(cryptoWasm));
check('rust crypto WASM exposes EmojiVerification SAS', typeof cryptoWasm.Sas === 'function');

const esbuild = require('esbuild');
check('esbuild bundler resolvable', typeof esbuild.build === 'function');
