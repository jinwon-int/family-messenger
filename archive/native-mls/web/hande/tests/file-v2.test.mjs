// file-v2 detached attachments (#499, FILE-V2.md) — descriptor validation, base64url,
// AES-256-GCM round trip and every tamper case, safe download names. Node ≥ 20 WebCrypto.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {isFileV2, parseDescriptor, encodeDescriptor, encryptFile, decryptFile, sha256Hex, safeFileName,
  base64urlEncode, base64urlDecode, MAX_FILE_V2, MAX_DESCRIPTOR_BYTES, FILE_V2_AAD, GCM_TAG_BYTES} from '../file-v2.js';

const key32 = new Uint8Array(32).fill(1), nonce12 = new Uint8Array(12).fill(2);
const base = () => ({v: 2, blob: 'a'.repeat(64), size: 10, key: base64urlEncode(key32), nonce: base64urlEncode(nonce12)});
const json = o => JSON.stringify(o);

test('isFileV2: lowercase uuid shape only', () => {
  assert.equal(isFileV2('file-v2-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2'), true);
  for (const id of ['file-v1-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2', 'file-v2-0F3C2A9B-1D2E-4F5A-8B6C-7D8E9FA0B1C2', 'file-v2-short', '', null, undefined]) {
    assert.equal(isFileV2(id), false, String(id));
  }
});

test('base64url: canonical, unpadded, strict', () => {
  for (const n of [0, 1, 2, 3, 12, 32, 33]) {
    const bytes = Uint8Array.from({length: n}, (_, i) => (i * 37 + 250) & 255);
    const text = base64urlEncode(bytes);
    assert.ok(!/[=+/]/.test(text));
    assert.deepEqual(base64urlDecode(text), bytes);
  }
  for (const bad of ['AQ==', 'A+B/', 'A', 'AR', 'a b', 12, null]) assert.equal(base64urlDecode(bad), null, String(bad));
  assert.equal(base64urlDecode('AR'), null, 'non-canonical trailing bits rejected');
});

test('parseDescriptor accepts the required set and every optional key', () => {
  const d = parseDescriptor(json(base()));
  assert.equal(d.v, 2); assert.equal(d.size, 10); assert.deepEqual(d.key, key32); assert.deepEqual(d.nonce, nonce12);
  const full = parseDescriptor(json({...base(), mime: 'image/jpeg', name: '사진 1.jpg', w: 4032, h: 3024}));
  assert.equal(full.mime, 'image/jpeg'); assert.equal(full.name, '사진 1.jpg'); assert.equal(full.w, 4032); assert.equal(full.h, 3024);
  assert.equal(parseDescriptor(new TextEncoder().encode(json(base()))).blob, 'a'.repeat(64), 'UTF-8 bytes accepted');
  assert.equal(parseDescriptor(json({...base(), size: MAX_FILE_V2})).size, MAX_FILE_V2);
});

test('parseDescriptor rejection matrix', () => {
  const bad = {
    'unknown key': {...base(), extra: 1},
    'missing key': (({key, ...r}) => r)(base()),
    'missing nonce': (({nonce, ...r}) => r)(base()),
    'v 1': {...base(), v: 1}, 'v "2"': {...base(), v: '2'},
    'blob upper': {...base(), blob: 'A'.repeat(64)}, 'blob short': {...base(), blob: 'a'.repeat(63)},
    'size 0': {...base(), size: 0}, 'size over': {...base(), size: MAX_FILE_V2 + 1}, 'size float': {...base(), size: 1.5}, 'size string': {...base(), size: '10'},
    'key 31 bytes': {...base(), key: base64urlEncode(new Uint8Array(31))}, 'key padded': {...base(), key: base64urlEncode(key32) + '='},
    'key std alphabet': {...base(), key: btoa(String.fromCharCode(...new Uint8Array(32).fill(251)))},
    'nonce 16 bytes': {...base(), nonce: base64urlEncode(new Uint8Array(16))},
    'mime no slash': {...base(), mime: 'jpeg'}, 'mime space': {...base(), mime: 'image/ jpeg'}, 'mime long': {...base(), mime: 'a/' + 'b'.repeat(99)},
    'name empty': {...base(), name: ''}, 'name control': {...base(), name: 'a\nb'}, 'name long': {...base(), name: 'x'.repeat(256)}, 'name number': {...base(), name: 7},
    'w 0': {...base(), w: 0}, 'h big': {...base(), h: 20001}, 'w float': {...base(), w: 1.5},
  };
  for (const [label, obj] of Object.entries(bad)) assert.throws(() => parseDescriptor(json(obj)), /file-v2 descriptor rejected/, label);
  for (const [label, text] of Object.entries({'array': '[]', 'null': 'null', 'not json': '{', 'string': '"x"', 'number': '2'})) {
    assert.throws(() => parseDescriptor(text), /file-v2 descriptor rejected/, label);
  }
  assert.throws(() => parseDescriptor(json({...base(), name: 'n'.repeat(250), mime: 'a/b'}) + ' '.repeat(MAX_DESCRIPTOR_BYTES)), /too large/);
  assert.throws(() => parseDescriptor(new Uint8Array([0xff, 0xfe])), /not utf-8/);
});

test('encodeDescriptor round-trips through parseDescriptor with a fixed key order', () => {
  const text = encodeDescriptor({blob: 'b'.repeat(64), size: 5, key: key32, nonce: nonce12, mime: 'image/png', name: 'a.png', w: 1, h: 2});
  assert.equal(Object.keys(JSON.parse(text)).join(','), 'v,blob,size,key,nonce,mime,name,w,h');
  const d = parseDescriptor(text);
  assert.deepEqual([d.blob, d.size, d.mime, d.name, d.w, d.h], ['b'.repeat(64), 5, 'image/png', 'a.png', 1, 2]);
  assert.throws(() => encodeDescriptor({blob: 'x', size: 5, key: key32, nonce: nonce12}), /rejected/);
});

test('encrypt → descriptor → decrypt round trip; ciphertext = size + tag; blob = sha256(ciphertext)', async () => {
  const file = Uint8Array.from({length: 100_003}, (_, i) => (i * 13) & 255);
  const enc = await encryptFile(file);
  assert.equal(enc.ciphertext.length, file.length + GCM_TAG_BYTES);
  assert.equal(enc.blob, await sha256Hex(enc.ciphertext));
  const d = parseDescriptor(encodeDescriptor({blob: enc.blob, size: enc.size, key: enc.key, nonce: enc.nonce}));
  assert.deepEqual(await decryptFile(enc.ciphertext, d), file);
  const again = await encryptFile(file);
  assert.notDeepEqual(again.key, enc.key, 'fresh key per file'); assert.notDeepEqual(again.nonce, enc.nonce, 'fresh nonce per file');
});

test('tamper: ciphertext byte, wrong key, wrong nonce, wrong AAD, size and sha256 mismatch all fail', async () => {
  const file = new TextEncoder().encode('hello file-v2');
  const enc = await encryptFile(file);
  const d = parseDescriptor(encodeDescriptor({blob: enc.blob, size: enc.size, key: enc.key, nonce: enc.nonce}));
  const flipped = enc.ciphertext.slice(); flipped[3] ^= 1;
  await assert.rejects(() => decryptFile(flipped, d), /sha256 mismatch/, 'changed byte → hash');
  const flippedId = await sha256Hex(flipped);
  await assert.rejects(() => decryptFile(flipped, {...d, blob: flippedId}), /authentication failed/, 'hash fixed up → GCM tag');
  await assert.rejects(() => decryptFile(enc.ciphertext, {...d, key: new Uint8Array(32).fill(9)}), /authentication failed/, 'wrong key');
  await assert.rejects(() => decryptFile(enc.ciphertext, {...d, nonce: new Uint8Array(12).fill(9)}), /authentication failed/, 'wrong nonce');
  await assert.rejects(() => decryptFile(enc.ciphertext, {...d, size: d.size + 1}), /length mismatch/, 'size');
  await assert.rejects(() => decryptFile(enc.ciphertext, {...d, blob: 'f'.repeat(64)}), /sha256 mismatch/, 'blob id');
  await assert.rejects(() => decryptFile(null, d), /no ciphertext/);
  // Same key/nonce but no AAD (or another AAD) does not authenticate.
  const subtle = globalThis.crypto.subtle;
  const k = await subtle.importKey('raw', enc.key, {name: 'AES-GCM'}, false, ['encrypt']);
  const noAad = new Uint8Array(await subtle.encrypt({name: 'AES-GCM', iv: enc.nonce}, k, file));
  const noAadId = await sha256Hex(noAad);
  await assert.rejects(() => decryptFile(noAad, {...d, blob: noAadId}), /authentication failed/, 'AAD is bound');
  assert.equal(FILE_V2_AAD, 'hande-file-v2');
});

test('safeFileName keeps the last segment and refuses control chars, dot names and overlong names', () => {
  assert.equal(safeFileName('사진.jpg'), '사진.jpg');
  assert.equal(safeFileName('../../etc/passwd'), 'passwd');
  assert.equal(safeFileName('C:\\Users\\x\\a.txt'), 'a.txt');
  for (const bad of ['', '.', '..', '.bashrc', 'a\u0000b', 'dir/', 'x'.repeat(256), null, 5]) assert.equal(safeFileName(bad), null, String(bad));
});
