import test from 'node:test';
import assert from 'node:assert/strict';
import {attachmentOutbox, MAX_ATTACHMENT, isAttachment} from './relay-attachments.js';

const uuid = '12345678-1234-1234-1234-123456789abc';
const file = bytes => ({size: bytes.length, arrayBuffer: async () => Uint8Array.from(bytes).buffer});
function fixture() {
  const records = new Map(), posts = [];
  let encrypted = 0;
  const storage = {getItem: key => records.get(key) ?? null,
    setItem: (key, value) => records.set(key, value), removeItem: key => records.delete(key)};
  const options = {storage, key: 'synthetic-device', device: 'owner-test', newId: () => uuid,
    encrypt: async bytes => { encrypted++; return bytes.map(b => b ^ 0xff); },
    post: async payload => { posts.push(structuredClone(payload)); return {status: 201, body: {seq: 7, epoch: 3}}; }};
  return {options, records, posts, encrypted: () => encrypted};
}

test('a full 256 KiB file fits in one raw application payload', async () => {
  const f = fixture(), box = attachmentOutbox(f.options);
  const bytes = Uint8Array.from({length: MAX_ATTACHMENT}, (_, i) => i % 256);
  const result = await box.send(file(bytes), 3);
  assert.equal(result.size, MAX_ATTACHMENT);
  assert.deepEqual(new Uint8Array(Buffer.from(f.posts[0].bytes, 'base64')).map(b => b ^ 0xff), bytes);
  assert.equal(f.encrypted(), 1); assert.equal(f.posts.length, 1);
  assert.equal(f.records.size, 0); assert.equal(box.pending, false);
});

test('oversize or changed files never consume an encryption step or POST', async () => {
  const f = fixture(), box = attachmentOutbox(f.options);
  await assert.rejects(box.send({size: MAX_ATTACHMENT + 1}, 0), /256 KiB/);
  await assert.rejects(box.send({size: 1, arrayBuffer: async () => new ArrayBuffer(2)}, 0), /크기/);
  assert.equal(f.encrypted(), 0); assert.equal(f.posts.length, 0);
});

test('a lost response survives reload and resends byte-identical payload at the original epoch', async () => {
  const f = fixture(); let sent;
  f.options.post = async payload => { sent = structuredClone(payload); throw new Error('lost response'); };
  await assert.rejects(attachmentOutbox(f.options).send(file([1, 2, 3]), 3), /lost response/);
  const saved = JSON.parse(f.records.get(f.options.key));
  assert.equal(saved.bytes, '/v38'); assert.equal('name' in saved, false);
  f.options.post = async payload => {
    assert.deepEqual(payload, sent);
    return {status: 200, body: {seq: 7, epoch: 3, duplicate: true}};
  };
  const result = await attachmentOutbox(f.options).send(null, 9);
  assert.equal(result.duplicate, true); assert.equal(f.encrypted(), 1);
  assert.equal(f.records.size, 0);
});

test('failed persistence never posts and retries without another encryption', async () => {
  const f = fixture(), original = f.options.storage.setItem;
  f.options.storage.setItem = () => { throw new Error('quota'); };
  const box = attachmentOutbox(f.options);
  await assert.rejects(box.send(file([4]), 0), /quota/);
  assert.equal(f.posts.length, 0); assert.equal(box.pending, true);
  f.options.storage.setItem = original;
  await box.send(null, 0);
  assert.equal(f.encrypted(), 1); assert.equal(f.posts.length, 1);
});

test('CAS rejection permits fresh encryption; unknown failures retain the outbox', async () => {
  const f = fixture();
  f.options.post = async () => ({status: 503, body: null});
  const box = attachmentOutbox(f.options);
  await assert.rejects(box.send(file([1]), 0), /503/);
  assert.equal(box.pending, true);
  // Use a fresh instance because the injected transport is fixed at construction.
  f.options.post = async () => ({status: 409, body: {error: 'cas_mismatch'}});
  const retry = attachmentOutbox(f.options);
  await assert.rejects(retry.send(null, 1), /방이 변경/);
  assert.equal(retry.pending, false); assert.equal(f.records.size, 0);
});

test('a generic HTTP 200 is not delivery confirmation', async () => {
  const f = fixture();
  f.options.post = async () => ({status: 200, body: {seq: 3}});
  const box = attachmentOutbox(f.options);
  await assert.rejects(box.send(file([1]), 0), /미확인/);
  assert.equal(box.pending, true);
});

test('an already running send cannot produce a second ciphertext', async () => {
  const f = fixture(); let release;
  f.options.encrypt = async () => new Promise(resolve => { release = resolve; });
  const box = attachmentOutbox(f.options), first = box.send(file([1]), 0);
  await assert.rejects(box.send(file([1]), 0), /전송 중/);
  release([7]); await first;
  assert.equal(f.posts.length, 1);
});

test('foreign-device or malformed outboxes are never sent', () => {
  const f = fixture();
  f.records.set(f.options.key, JSON.stringify({device: 'other'}));
  assert.throws(() => attachmentOutbox(f.options), /손상/);
  assert.equal(isAttachment(`file-v1-${uuid}`), true);
  assert.equal(isAttachment(`file-v1-${uuid}<script>`), false);
});
