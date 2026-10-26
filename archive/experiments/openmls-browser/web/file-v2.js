// file-v2 detached attachments (#499, archive/native-mls/FILE-V2.md) — pure helpers.
//
// The file itself never travels in MLS: the sender encrypts it under a fresh
// AES-256-GCM key, uploads the ciphertext to the relay blob store
// (POST /v2/rooms/{room}/blobs, #505) and sends a small MLS application message
// whose outer client_id is `file-v2-<uuid>` and whose plaintext is the descriptor
// JSON below. A receiver fetches the blob lazily, checks its sha256 against the
// descriptor, decrypts, and checks the length — any mismatch is an unopenable
// attachment, never a crash and never text.
//
// Descriptor (exact keys; FILE-V2.md is the canonical spec):
//   required  v: 2 · blob: 64 lowercase hex (sha256 of the ciphertext = relay blob id)
//             size: plaintext bytes, 1..MAX_FILE_V2 · key: base64url(32 B) · nonce: base64url(12 B)
//   optional  mime: "type/subtype" (≤ 100) · name: ≤ 255 chars, no control chars · w, h: 1..20000
// Cipher: AES-256-GCM, AAD = UTF-8 "hande-file-v2", ciphertext = plaintext ‖ 16-byte tag.
//
// WebCrypto only (browser workers/pages and Node ≥ 20 `globalThis.crypto`), no dependencies.

export const FILE_V2_VERSION = 2;
export const FILE_V2_AAD = 'hande-file-v2';
export const MAX_FILE_V2 = 50 * 1024 * 1024;   // owner decision on #499
export const MAX_DESCRIPTOR_BYTES = 4096;
export const GCM_TAG_BYTES = 16;
export const KEY_BYTES = 32, NONCE_BYTES = 12;
export const MAX_DIMENSION = 20000;

const REQUIRED = ['blob', 'key', 'nonce', 'size', 'v'];
const OPTIONAL = ['h', 'mime', 'name', 'w'];
const ALLOWED = new Set([...REQUIRED, ...OPTIONAL]);
const BLOB_ID = /^[0-9a-f]{64}$/;
const MIME = /^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}$/;
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/;
// Bidirectional controls let a sender disguise an extension in the saved name
// ("photo\u202Egpj.exe" displays as "photoexe.jpg"); a download name containing
// any of them is not used (the generated name is). Descriptors stay valid.
const BIDI = /[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/;
const utf8 = new TextEncoder();
const fail = reason => { const e = new Error(`file-v2 descriptor rejected: ${reason}`); e.fileV2 = reason; throw e; };

/** Outer relay client_id of a file-v2 message (display hint only, like v1 `file-v1-`). */
export const isFileV2 = id => /^file-v2-[a-f0-9-]{36}$/.test(id ?? '');

// ---- base64url (RFC 4648 §5, no padding, canonical) ----
const B64URL = /^[A-Za-z0-9_-]*$/;
export function base64urlEncode(bytes) {
  let binary = '';
  for (let at = 0; at < bytes.length; at += 8192) binary += String.fromCharCode.apply(null, bytes.subarray(at, at + 8192));
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
/** Strict decode: alphabet, no padding, and canonical (re-encodes to the same string) — else null. */
export function base64urlDecode(text) {
  if (typeof text !== 'string' || !B64URL.test(text) || text.length % 4 === 1) return null;
  let binary;
  try { binary = atob(text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - text.length % 4) % 4)); } catch (_) { return null; }
  const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
  return base64urlEncode(bytes) === text ? bytes : null;
}

const positiveInt = (value, max) => Number.isSafeInteger(value) && value >= 1 && value <= max;

/**
 * Parse and validate a descriptor (the MLS plaintext: a JSON string or its UTF-8 bytes).
 * Returns {v, blob, size, key: Uint8Array(32), nonce: Uint8Array(12), mime?, name?, w?, h?}; throws otherwise.
 */
export function parseDescriptor(input) {
  let text = input;
  if (input instanceof Uint8Array) {
    if (input.length > MAX_DESCRIPTOR_BYTES) fail('too large');
    try { text = new TextDecoder('utf-8', {fatal: true}).decode(input); } catch (_) { fail('not utf-8'); }
  }
  if (typeof text !== 'string') fail('not text');
  if (utf8.encode(text).length > MAX_DESCRIPTOR_BYTES) fail('too large');
  let raw;
  try { raw = JSON.parse(text); } catch (_) { fail('not json'); }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || Object.getPrototypeOf(raw) !== Object.prototype) fail('not an object');
  const keys = Object.keys(raw);
  for (const k of keys) if (!ALLOWED.has(k)) fail(`unknown key ${k}`);
  for (const k of REQUIRED) if (!(k in raw)) fail(`missing ${k}`);
  if (raw.v !== FILE_V2_VERSION) fail('version');
  if (typeof raw.blob !== 'string' || !BLOB_ID.test(raw.blob)) fail('blob');
  if (!positiveInt(raw.size, MAX_FILE_V2)) fail('size');
  const key = base64urlDecode(raw.key), nonce = base64urlDecode(raw.nonce);
  if (!key || key.length !== KEY_BYTES) fail('key');
  if (!nonce || nonce.length !== NONCE_BYTES) fail('nonce');
  const out = {v: FILE_V2_VERSION, blob: raw.blob, size: raw.size, key, nonce};
  if ('mime' in raw) {
    if (typeof raw.mime !== 'string' || raw.mime.length > 100 || !MIME.test(raw.mime)) fail('mime');
    out.mime = raw.mime;
  }
  if ('name' in raw) {
    if (typeof raw.name !== 'string' || raw.name.length < 1 || [...raw.name].length > 255 || CONTROL.test(raw.name)) fail('name');
    out.name = raw.name;
  }
  for (const k of ['w', 'h']) {
    if (k in raw) {
      if (!positiveInt(raw[k], MAX_DIMENSION)) fail(k);
      out[k] = raw[k];
    }
  }
  return out;
}

/** Descriptor → canonical JSON string (fixed key order). Validates by round-trip. */
export function encodeDescriptor({blob, size, key, nonce, mime, name, w, h}) {
  const obj = {v: FILE_V2_VERSION, blob, size, key: base64urlEncode(key), nonce: base64urlEncode(nonce)};
  if (mime !== undefined) obj.mime = mime;
  if (name !== undefined) obj.name = name;
  if (w !== undefined) obj.w = w;
  if (h !== undefined) obj.h = h;
  const text = JSON.stringify(obj);
  parseDescriptor(text);
  return text;
}

const subtleOf = c => (c ?? globalThis.crypto).subtle;
const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');

/** sha256 of bytes as 64 lowercase hex (the relay blob id). */
export async function sha256Hex(bytes, {crypto} = {}) {
  return hex(new Uint8Array(await subtleOf(crypto).digest('SHA-256', bytes)));
}

/**
 * Encrypt one file for upload (stage 3 send side): fresh key + nonce, AES-256-GCM with the
 * file-v2 AAD. Returns {ciphertext, blob, size, key, nonce} — upload `ciphertext`, then send
 * encodeDescriptor({blob, size, key, nonce, …}) over MLS.
 */
export async function encryptFile(plaintext, {crypto} = {}) {
  const c = crypto ?? globalThis.crypto;
  if (!(plaintext instanceof Uint8Array) || plaintext.length < 1 || plaintext.length > MAX_FILE_V2) throw new Error('file-v2: bad file size');
  const key = c.getRandomValues(new Uint8Array(KEY_BYTES)), nonce = c.getRandomValues(new Uint8Array(NONCE_BYTES));
  const k = await c.subtle.importKey('raw', key, {name: 'AES-GCM'}, false, ['encrypt']);
  const ciphertext = new Uint8Array(await c.subtle.encrypt({name: 'AES-GCM', iv: nonce, additionalData: utf8.encode(FILE_V2_AAD), tagLength: 128}, k, plaintext));
  return {ciphertext, blob: await sha256Hex(ciphertext, {crypto: c}), size: plaintext.length, key, nonce};
}

/**
 * Verify and decrypt a downloaded blob against its parsed descriptor: sha256 must equal
 * `blob`, the ciphertext length must be size + tag, GCM must authenticate (key, nonce, AAD),
 * and the plaintext length must equal `size`. Throws on any mismatch.
 */
export async function decryptFile(ciphertext, descriptor, {crypto} = {}) {
  if (!(ciphertext instanceof Uint8Array)) throw new Error('file-v2: no ciphertext');
  if (ciphertext.length !== descriptor.size + GCM_TAG_BYTES) throw new Error('file-v2: ciphertext length mismatch');
  if (await sha256Hex(ciphertext, {crypto}) !== descriptor.blob) throw new Error('file-v2: sha256 mismatch');
  const subtle = subtleOf(crypto);
  const k = await subtle.importKey('raw', descriptor.key, {name: 'AES-GCM'}, false, ['decrypt']);
  let plain;
  try {
    plain = new Uint8Array(await subtle.decrypt({name: 'AES-GCM', iv: descriptor.nonce, additionalData: utf8.encode(FILE_V2_AAD), tagLength: 128}, k, ciphertext));
  } catch (_) { throw new Error('file-v2: authentication failed'); }
  if (plain.length !== descriptor.size) throw new Error('file-v2: size mismatch');
  return plain;
}

/**
 * A sender-supplied file name usable as a download name, or null: the last path segment
 * only, no control characters, not empty or dot-only, ≤ 255 chars. The MIME type is never
 * taken from the sender (attachment-view.js sniffs content).
 */
export function safeFileName(name) {
  if (typeof name !== 'string' || CONTROL.test(name) || BIDI.test(name)) return null;
  const base = name.split(/[\\/]/).pop().trim();
  if (!base || /^\.+$/.test(base) || base.startsWith('.') || [...base].length > 255) return null;
  return base;
}
