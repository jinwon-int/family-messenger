// #308: 실제 matrix-encrypt-attachment로 암호화 업로드 → content.file → 복호화 왕복.
// 단위 테스트(npm test)는 의존성 없이 돌아야 하므로 라이브러리 왕복은 npm ci 뒤의 이 묶음에서 본다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { decryptAttachment } from 'matrix-encrypt-attachment';
import { ClientAdapter } from '../../src/matrix/client.js';
import { attachmentContent } from '../../src/messages.js';
import { attachmentFromContent } from '../../src/attachments.js';

function adapter() {
  const client = new EventEmitter();
  client.uploads = [];
  client.uploadContent = async (data, opts) => { client.uploads.push({ data, opts }); return { content_uri: 'mxc://example.com/enc1' }; };
  client.getHomeserverUrl = () => 'https://matrix.example.com';
  client.getAccessToken = () => 'syt-token';
  return new ClientAdapter(client, '@me:example.com');
}

test('실제 라이브러리: 업로드 바이트는 원문과 다르고, content.file은 수신측 검증 형식이며, decryptAttachment로 원문이 된다', async () => {
  const fam = adapter();
  const plaintext = new TextEncoder().encode(JSON.stringify({ macro: '가족 매크로', steps: Array.from({ length: 64 }, (_, i) => i) }));
  const { file } = await fam.uploadMedia({ name: 'macro.json', type: 'application/json' }, plaintext.slice().buffer);
  const { data, opts } = fam.client.uploads[0];
  assert.equal(opts.type, 'application/octet-stream');
  assert.equal(opts.includeFilename, false);
  assert.notEqual(opts.name, 'macro.json');
  const uploaded = new Uint8Array(data.buffer ?? data, data.byteOffset ?? 0, data.byteLength);
  assert.equal(uploaded.byteLength, plaintext.byteLength);
  assert.notDeepEqual(Array.from(uploaded), Array.from(plaintext));

  const content = attachmentContent({ name: 'macro.json', type: 'application/json', size: plaintext.byteLength }, file);
  assert.equal('url' in content, false);
  assert.equal(content.msgtype, 'm.file');
  assert.deepEqual(content.info, { mimetype: 'application/json', size: plaintext.byteLength });
  // ccc-node 브리지 검증 규칙과 같은 형식
  const f = content.file;
  assert.match(f.url, /^mxc:\/\//);
  assert.equal(f.v, 'v2');
  assert.equal(f.key.kty, 'oct');
  assert.equal(f.key.alg, 'A256CTR');
  assert.equal(f.key.ext, true);
  assert.deepEqual(f.key.key_ops, ['encrypt', 'decrypt']);
  assert.match(f.key.k, /^[A-Za-z0-9_-]+$/);
  assert.match(f.iv, /^[A-Za-z0-9+/]+$/);
  assert.match(f.hashes.sha256, /^[A-Za-z0-9+/]+$/);

  const decrypted = new Uint8Array(await decryptAttachment(uploaded.slice().buffer, f));
  assert.deepEqual(Array.from(decrypted), Array.from(plaintext));

  // 웹 자신의 수신 경로: attachmentFromContent → fetchAttachment(기본 decrypt = 라이브러리)
  const record = attachmentFromContent(content);
  assert.ok(record.encrypted);
  const blob = await fam.fetchAttachment(record, { fetchFn: async () => ({ ok: true, arrayBuffer: async () => uploaded.slice().buffer }) });
  assert.equal(blob.type, 'application/json');
  assert.deepEqual(Array.from(new Uint8Array(await blob.arrayBuffer())), Array.from(plaintext));
});
