// Custody (#177 §3.5, M2b-3): the single at-rest key stack for the native E2EE
// workers — the SESSION-RECORDS model from archive/experiments/device-keystore.
// Bundled by build.sh (esbuild) to <bundle>/custody.js; the source is never served.
//
// - One age password capsule per device database, default scrypt work factor
//   (logN 18, never reduced), holding a 32-byte root key and a public vault id.
//   Unlock admits only a single default-work scrypt recipient before the full
//   (expensive) decryption, as in device-keystore/session-worker.js.
// - Per-purpose subkeys come from libsodium crypto_kdf_derive_from_key (BLAKE2b)
//   under a fixed 8-byte context: no custom KDF.
// - Asynchronous work (scrypt) happens here, before any IndexedDB transaction;
//   everything the transactions need afterwards is synchronous.
// Development-only synthetic custody: not a reviewed human keystore.
import {Encrypter, Decrypter} from 'age-encryption';
import sodiumModule from 'libsodium-wrappers';

await sodiumModule.ready;
export const sodium = sodiumModule;

const CONTEXT = 'fmlsvlt1';            // crypto_kdf context (exactly 8 bytes)
const SUBKEY = {auth: 1, enc: 2};      // record authentication / record encryption (M2b-3b)
const PAYLOAD = 1;                     // capsule payload version

export function validPassphrase(value) {
  if (typeof value !== 'string' || value.length < 32 || value.length > 128) throw new Error('passphrase');
  return value;
}
export function validVault(value) {
  if (typeof value !== 'string' || !/^[0-9a-f]{32}$/.test(value)) throw new Error('vault');
  return value;
}

function derive(root) {
  if (!(root instanceof Uint8Array) || root.length !== sodium.crypto_kdf_KEYBYTES) throw new Error('root');
  return {
    auth: sodium.crypto_kdf_derive_from_key(32, SUBKEY.auth, CONTEXT, root),
    enc: sodium.crypto_kdf_derive_from_key(32, SUBKEY.enc, CONTEXT, root),
  };
}

/** New root key + vault id sealed in an age password capsule. */
export async function createVault(passphrase) {
  const password = validPassphrase(passphrase);
  const root = sodium.crypto_secretstream_xchacha20poly1305_keygen();
  const vault = sodium.to_hex(sodium.randombytes_buf(16));
  const payload = new TextEncoder().encode(JSON.stringify([PAYLOAD, vault, Array.from(root)]));
  try {
    const encrypter = new Encrypter();
    encrypter.setPassphrase(password);  // default scrypt work factor (logN 18)
    const capsule = await encrypter.encrypt(payload);
    return {capsule, vault, keys: derive(root)};
  } finally {
    sodium.memzero(payload); sodium.memzero(root);
  }
}

// Reject anything but one default-work scrypt recipient before paying for the KDF.
async function admitted(capsule) {
  const accepted = {};
  const inspector = new Decrypter();
  inspector.addIdentity({unwrapFileKey(stanzas) {
    if (stanzas.length !== 1 || stanzas[0].args.length !== 3 || stanzas[0].args[0] !== 'scrypt' ||
        stanzas[0].args[2] !== '18' || stanzas[0].body.length !== 32) throw new Error('work policy');
    throw accepted;
  }});
  try { await inspector.decrypt(capsule); } catch (error) { if (error === accepted) return; }
  throw new Error('admission');
}

/** Open a capsule whose vault id must equal `vault`; returns the derived subkeys. */
export async function unlockVault(capsule, vault, passphrase) {
  const password = validPassphrase(passphrase), expected = validVault(vault);
  if (!(capsule instanceof Uint8Array) || !capsule.length || capsule.length > 8192) throw new Error('capsule');
  await admitted(capsule);
  const decrypter = new Decrypter();
  decrypter.addPassphrase(password);
  const plaintext = await decrypter.decrypt(capsule);
  try {
    if (plaintext.length > 1024) throw new Error('capsule size');
    const value = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(plaintext));
    if (!Array.isArray(value) || value.length !== 3 || value[0] !== PAYLOAD || validVault(value[1]) !== expected ||
        !Array.isArray(value[2]) || value[2].length !== 32 ||
        !value[2].every(x => Number.isInteger(x) && x >= 0 && x <= 255)) throw new Error('capsule');
    const root = new Uint8Array(value[2]);
    try { return derive(root); } finally { sodium.memzero(root); }
  } finally {
    sodium.memzero(plaintext);
  }
}
