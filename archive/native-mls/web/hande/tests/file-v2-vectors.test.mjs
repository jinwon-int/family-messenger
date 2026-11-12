// file-v2 공유 벡터(#366 3d) — host-core `file_v2`(봇·Android ffi)·Android `FileV2.kt` 와 같은 파일
// archive/native-mls/tests/fixtures/file-v2-vectors.json 을 웹 parseDescriptor·decryptFile 로 돌린다.
// `lenient` 에 "web" 이 있는 항목은 웹이 일부러 더 너그러운 곳(JSON.parse 중복 키 · TextDecoder BOM · 짝 없는 서로게이트) — 받아야 한다.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {parseDescriptor, decryptFile} from '../file-v2.js';

const vectors = JSON.parse(readFileSync(new URL('../../../tests/fixtures/file-v2-vectors.json', import.meta.url), 'utf8'));
const unhex = h => Uint8Array.from(h.match(/../g) ?? [], b => parseInt(b, 16));
const bytesOf = c => (c.hex !== undefined ? unhex(c.hex) : new TextEncoder().encode(c.text));

test('descriptor vectors: same decision as host-core and Android', () => {
  assert.ok(vectors.descriptors.length >= 50);
  for (const c of vectors.descriptors) {
    const accept = c.expect === 'accept' || (c.lenient ?? []).includes('web');
    if (accept) {
      const d = parseDescriptor(bytesOf(c));
      if (c.expect === 'accept') assert.equal(d.size, c.size, c.name);
      continue;
    }
    assert.throws(() => parseDescriptor(bytesOf(c)), err => {
      // 웹 사유는 `unknown key <k>` 처럼 뒤에 키 이름이 붙을 수 있다 — 앞부분이 같으면 같은 사유.
      if (c.reason !== undefined) assert.ok(err.fileV2?.startsWith(c.reason), `${c.name}: ${err.fileV2} ≠ ${c.reason}`);
      return true;
    }, c.name);
  }
});

test('ciphertext vector opens with the web decryptFile', async () => {
  const {descriptor, ciphertext_hex, plaintext_hex} = vectors.ciphertext;
  assert.deepEqual(await decryptFile(unhex(ciphertext_hex), parseDescriptor(descriptor)), unhex(plaintext_hex));
});
