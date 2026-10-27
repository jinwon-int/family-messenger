// file-v2 송신 보관함(#499 3단계, FILE-V2.md §3) — 업로드 → 설명자 MLS 암호화 → 보관 → 게시, 재시도·409·한도·보관 내용.
import test from 'node:test';
import assert from 'node:assert/strict';
import {fileV2Outbox, sendsFileV2, SEND_FILE_V2, SEND_OVERRIDE_KEY, isFileV2Client} from '../file-v2-outbox.js';
import {parseDescriptor, decryptFile, sha256Hex, MAX_FILE_V2} from '../file-v2.js';

const KEY = 'hande:attachment-v2:db:family:me-pc';
const MARK = new TextEncoder().encode('MLS:');   // 가짜 MLS 암호화 = 접두 + 평문(테스트에서 평문을 되찾기 위함)

function memoryStorage() {
  const m = new Map();
  return {getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), map: m};
}
const locks = {request: async (_name, _opts, fn) => fn({})};
function fileOf(bytes, {type = 'image/jpeg', name = '사진.jpg'} = {}) {
  return {size: bytes.length, type, name, arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length)};
}
function harness({uploadStatus = 201, uploadId = null, postResults = [{status: 201, body: {seq: 42}}]} = {}) {
  const storage = memoryStorage();
  const calls = {upload: [], post: [], encrypt: [], storedAtPost: []};
  const deps = {
    storage, key: KEY, device: 'me-pc', locks,
    newId: () => '0f8fad5b-d9cb-469f-a165-70867728950e',
    encrypt: async bytes => { calls.encrypt.push(bytes); return new Uint8Array([...MARK, ...bytes]); },
    upload: async ct => { calls.upload.push(ct); return {status: uploadStatus, body: {id: uploadId ?? await sha256Hex(ct), size: ct.length}}; },
    post: async payload => { calls.post.push(payload); calls.storedAtPost.push(storage.getItem(KEY)); return postResults.shift() ?? {status: 502, body: null}; },
  };
  return {storage, calls, deps, outbox: fileV2Outbox(deps)};
}
const photo = () => Uint8Array.from({length: 2000}, (_, i) => (i * 7) % 256);
const unwrapDescriptor = plaintext => new TextDecoder().decode(plaintext);   // calls.encrypt 는 MLS 암호화 전 평문

test('송신 스위치: 기본 꺼짐, 시험용 덮어쓰기, 켜진 기본값', () => {
  assert.equal(SEND_FILE_V2, false, 'stage 3 ships off — flip only after every device receives v2');
  const s = memoryStorage();
  assert.equal(sendsFileV2(s), false);
  s.setItem(SEND_OVERRIDE_KEY, '1');
  assert.equal(sendsFileV2(s), true);
  assert.equal(sendsFileV2(memoryStorage(), true), true);
  assert.equal(sendsFileV2(null), false);
});

test('정상: 업로드(id = sha256) → 설명자 MLS 암호화 → 보관 뒤 게시 → 보관 해제, 받는 쪽이 열 수 있다', async () => {
  const {outbox, calls, storage} = harness();
  const bytes = photo();
  const result = await outbox.send(fileOf(bytes), 3);
  assert.equal(calls.upload.length, 1);
  assert.equal(calls.post.length, 1);
  const descriptor = parseDescriptor(unwrapDescriptor(calls.encrypt[0]));
  assert.equal(descriptor.blob, await sha256Hex(calls.upload[0]));
  assert.equal(descriptor.size, bytes.length);
  assert.equal(descriptor.mime, 'image/jpeg');
  assert.equal(descriptor.name, '사진.jpg');
  assert.deepEqual(await decryptFile(calls.upload[0], descriptor), bytes, 'the uploaded blob opens with the sent descriptor');
  const payload = calls.post[0];
  assert.ok(isFileV2Client(payload.client_id), payload.client_id);
  assert.equal(payload.kind, 'application');
  assert.equal(payload.epoch, 3);
  assert.equal(payload.device, 'me-pc');
  assert.equal(payload.size, undefined, 'size is local only');
  assert.ok(calls.storedAtPost[0], 'persisted before POST');
  assert.equal(storage.getItem(KEY), null, 'cleared after a confirmed delivery');
  assert.equal(result.seq, 42);
  assert.equal(result.size, bytes.length);
  assert.equal(result.client_id, payload.client_id);
  assert.equal(parseDescriptor(result.descriptor).blob, descriptor.blob);
  assert.equal(outbox.pending, false);
});

test('보관 내용: MLS 암호문뿐 — 파일 키·설명자 평문·파일 이름은 localStorage 에 없다', async () => {
  const {outbox, calls} = harness({postResults: [{status: 502, body: null}]});
  await assert.rejects(outbox.send(fileOf(photo()), 1), /전송 미확인\(502\)/);
  const saved = calls.storedAtPost[0];
  const descriptorText = unwrapDescriptor(calls.encrypt[0]);
  const keyText = JSON.parse(descriptorText).key;
  assert.ok(!saved.includes(keyText), 'no raw key');
  assert.ok(!saved.includes('"blob"'), 'no descriptor JSON');
  assert.ok(!saved.includes('사진'), 'no file name');
  assert.deepEqual(Object.keys(JSON.parse(saved)).sort(), ['bytes', 'client_id', 'device', 'epoch', 'kind', 'size']);
});

test('업로드 실패·id 불일치: 아무것도 보관·게시하지 않는다', async () => {
  for (const opts of [{uploadStatus: 413}, {uploadStatus: 403}, {uploadId: 'f'.repeat(64)}]) {
    const {outbox, calls, storage} = harness(opts);
    await assert.rejects(outbox.send(fileOf(photo()), 1), /업로드 실패/);
    assert.equal(calls.post.length, 0);
    assert.equal(calls.encrypt.length, 0, 'no MLS ratchet use for an upload that failed');
    assert.equal(storage.getItem(KEY), null);
    assert.equal(outbox.pending, false);
  }
});

test('게시 불확실 → 같은 바이트로만 재시도(다시 올리거나 다시 암호화하지 않음), 새로고침 뒤에도', async () => {
  const {outbox, calls, deps} = harness({postResults: [{status: 502, body: null}, {status: 504, body: null}]});
  await assert.rejects(outbox.send(fileOf(photo()), 1));
  assert.equal(outbox.pending, true);
  await assert.rejects(outbox.send(null, 1));
  assert.equal(calls.upload.length, 1);
  assert.equal(calls.encrypt.length, 1);
  assert.deepEqual(calls.post[1], calls.post[0], 'identical payload');
  // 새로고침: 새 인스턴스가 보관 기록에서 이어 받는다 — 설명자는 없다(MLS 암호문만 보관).
  const reloaded = fileV2Outbox({...deps, post: async payload => { calls.post.push(payload); return {status: 200, body: {seq: 42, duplicate: true}}; }});
  assert.equal(reloaded.pending, true);
  const result = await reloaded.send(null, 1);
  assert.deepEqual(calls.post[2], calls.post[0]);
  assert.equal(result.seq, 42);
  assert.equal(result.descriptor, null);
  assert.equal(deps.storage.getItem(KEY), null);
});

test('409 cas_mismatch: 게시되지 않았음이 확실 — 보관 해제, 다시 선택하라고 알린다', async () => {
  const {outbox, storage} = harness({postResults: [{status: 409, body: {error: 'cas_mismatch'}}]});
  await assert.rejects(outbox.send(fileOf(photo()), 1), /방이 변경돼/);
  assert.equal(storage.getItem(KEY), null);
  assert.equal(outbox.pending, false);
});

test('크기: 0 바이트·50 MiB 초과는 올리지 않는다, 정확히 50 MiB 는 허용 범위', async () => {
  const {outbox, calls} = harness();
  await assert.rejects(outbox.send(fileOf(new Uint8Array(0)), 1), /50 MiB/);
  await assert.rejects(outbox.send({size: MAX_FILE_V2 + 1, type: '', name: 'x', arrayBuffer: async () => new ArrayBuffer(0)}, 1), /50 MiB/);
  assert.equal(calls.upload.length, 0);
  await assert.rejects(outbox.send({size: 10, type: '', name: 'x', arrayBuffer: async () => new ArrayBuffer(9)}, 1), /크기가 바뀌었다/);
});

test('힌트: 형식에 맞지 않는 MIME·이름은 빼고 보낸다(받는 쪽은 내용으로 판단)', async () => {
  const {outbox, calls} = harness();
  await outbox.send(fileOf(photo(), {type: 'not a mime', name: 'a\u0007b'}), 1);
  const d = parseDescriptor(unwrapDescriptor(calls.encrypt[0]));
  assert.equal(d.mime, undefined);
  assert.equal(d.name, undefined);
  const {outbox: o2, calls: c2} = harness();
  await o2.send(fileOf(photo(), {type: '', name: ''}), 1);
  assert.deepEqual(Object.keys(JSON.parse(unwrapDescriptor(c2.encrypt[0]))).sort(), ['blob', 'key', 'nonce', 'size', 'v']);
});

test('손상된 보관 기록·다른 기기 기록은 거부한다', () => {
  for (const bad of [
    {device: 'me-pc', client_id: 'file-v1-0f8fad5b-d9cb-469f-a165-70867728950e', kind: 'application', epoch: 1, bytes: 'AA==', size: 10},
    {device: 'other-pc', client_id: 'file-v2-0f8fad5b-d9cb-469f-a165-70867728950e', kind: 'application', epoch: 1, bytes: 'AA==', size: 10},
    {device: 'me-pc', client_id: 'file-v2-0f8fad5b-d9cb-469f-a165-70867728950e', kind: 'application', epoch: 1, bytes: 'A'.repeat(20000), size: 10},
    {device: 'me-pc', client_id: 'file-v2-0f8fad5b-d9cb-469f-a165-70867728950e', kind: 'application', epoch: 1, bytes: 'AA==', size: 0},
  ]) {
    const storage = memoryStorage();
    storage.setItem(KEY, JSON.stringify(bad));
    assert.throws(() => fileV2Outbox({storage, key: KEY, device: 'me-pc', locks}), /손상/);
  }
});

test('잠금 없는 브라우저·동시 전송은 거부한다', async () => {
  const {deps} = harness();
  await assert.rejects(fileV2Outbox({...deps, locks: undefined}).send(fileOf(photo()), 1), /지원하지 않는다/);
  const {deps: d2} = harness();
  await assert.rejects(fileV2Outbox({...d2, locks: {request: async (_n, _o, fn) => fn(null)}}).send(fileOf(photo()), 1), /다른 탭/);
});
