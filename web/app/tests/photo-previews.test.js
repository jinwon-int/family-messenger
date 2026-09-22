import test from 'node:test';
import assert from 'node:assert/strict';
import { PhotoPreviews } from '../src/photo-previews.js';

const photo = (id = 'one') => ({ kind: 'photo', url: `mxc://hs/${id}`, mimetype: 'image/png', encrypted: null });
const flush = () => new Promise((resolve) => setImmediate(resolve));
function setup(fetchPhoto) {
  const created = [], revoked = [], changes = [];
  const cache = new PhotoPreviews({ fetchPhoto, onChange: () => changes.push(true),
    createUrl: (blob) => { created.push(blob); return `blob:test/${created.length}`; },
    revokeUrl: (url) => revoked.push(url) });
  return { cache, created, revoked, changes };
}

test('photo renders from fetched bytes; repeated syncs share pending and ready downloads', async () => {
  let resolve, calls = 0;
  const blob = new Blob(['photo']);
  const { cache, created } = setup(() => { calls++; return new Promise((r) => { resolve = r; }); });
  cache.sync('room', [photo(), { kind: 'file', url: 'mxc://hs/file' }]);
  await flush();
  cache.sync('room', [photo()]);
  assert.equal(cache.get(photo()).status, 'loading');
  assert.equal(calls, 1);
  resolve(blob);
  await flush();
  cache.sync('room', [photo()]);
  assert.equal(cache.get(photo()).status, 'ready');
  assert.equal(cache.get(photo()).src, 'blob:test/1');
  assert.deepEqual(created, [blob]);
  assert.equal(calls, 1);
});

test('download failures stay visible until explicit retry; decode failures release their URL', async () => {
  let calls = 0;
  const { cache, revoked } = setup(async () => { if (++calls === 1) throw Error('403'); return new Blob(['photo']); });
  cache.sync('room', [photo()]);
  await flush();
  assert.equal(cache.get(photo()).status, 'error');
  cache.sync('room', [photo()]);
  await flush();
  assert.equal(calls, 1);
  cache.retry(photo());
  await flush();
  assert.equal(cache.get(photo()).status, 'ready');
  cache.fail(photo());
  assert.equal(cache.get(photo()).status, 'error');
  assert.deepEqual(revoked, ['blob:test/1']);
  cache.clear();
  assert.equal(revoked.length, 1);
});

test('room switch and logout abort requests and discard late decrypted bytes', async () => {
  let resolve, signal;
  const { cache, created, changes } = setup((_, options) => {
    signal = options.signal;
    return new Promise((r) => { resolve = r; });
  });
  cache.sync('old', [photo()]);
  await flush();
  cache.sync('new', []);
  assert.equal(signal.aborted, true);
  resolve(new Blob(['old room']));
  await flush();
  assert.equal(created.length, 0);
  assert.equal(changes.length, 0);
  cache.sync('new', [photo()]);
  await flush();
  cache.clear();
  resolve(new Blob(['logged out']));
  await flush();
  assert.equal(created.length, 0);
});

test('removal, changed encryption metadata and room switch release ready URLs', async () => {
  const seen = [];
  const { cache, revoked } = setup(async (attachment) => { seen.push(attachment); return new Blob(['photo']); });
  cache.sync('room', [photo()]);
  await flush();
  const encrypted = { ...photo(), encrypted: { key: { k: 'synthetic' }, iv: 'iv', hashes: { sha256: 'hash' } } };
  cache.sync('room', [encrypted]);
  await flush();
  assert.deepEqual(revoked, ['blob:test/1']);
  assert.equal(seen[1], encrypted);
  cache.sync('room', []);
  assert.deepEqual(revoked, ['blob:test/1', 'blob:test/2']);
  cache.sync('room', [photo()]);
  await flush();
  cache.sync(null, []);
  assert.equal(revoked.length, 3);
});

test('downloads are limited to three in flight and queued stale work never starts', async () => {
  const pending = [];
  const { cache } = setup((attachment) => new Promise((resolve) => pending.push({ attachment, resolve })));
  cache.sync('room', Array.from({ length: 8 }, (_, i) => photo(String(i))));
  await flush();
  assert.equal(pending.length, 3);
  pending[0].resolve(new Blob(['photo']));
  await flush();
  assert.equal(pending.length, 4);
  cache.clear();
  for (const item of pending) item.resolve(new Blob(['photo']));
  await flush();
  assert.equal(pending.length, 4);
});
