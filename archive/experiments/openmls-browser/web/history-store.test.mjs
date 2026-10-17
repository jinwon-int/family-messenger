// #370 relay-app sealed message history — pure parts of ./history-store.js.
// The AEAD itself (custody.js sealRecord/openRecord) and IndexedDB are exercised by the
// browser smoke (archive/native-mls/tests/native_relay_app_smoke.py: reload restores rows,
// raw records carry no plaintext, evict deletes the database).
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {historyAd, historyName, validRow, encodeHeader, decodeHeader, pruneVictims, MAX_ROWS, MAX_BYTES, MAX_TEXT, MAX_BLOB}
  from './history-store.js';

const text = (seq, t = 'hello') => ({seq, sender: 'owner-iphone-1', client: 'owner-iphone-1', kind: 'text', text: t, bytes: []});
const file = (seq, bytes) => ({seq, sender: 'owner-iphone-1', client: '', kind: 'attachment', text: '', bytes});
const s = bytes => new TextDecoder().decode(bytes);

test('history database sits next to the MLS store under its own name', () => {
  assert.equal(historyName('family-mls-synthetic-app-owner-pc'), 'family-mls-synthetic-app-owner-pc-history');
});

test('additional data carries the aux domain and binds part, identity, room and seq', () => {
  const ad = s(historyAd('owner-pc', 'family-acc', 7, 'row'));
  assert.ok(ad.startsWith('family-mls-aux-'), 'session-store sealAux refuses any other domain');
  assert.ok(!ad.startsWith('family-mls-meta-') && !ad.startsWith('family-mls-entry-'));
  assert.equal(ad, 'family-mls-aux-history-v1/row\0owner-pc\0family-acc\x007');
  const variants = [historyAd('owner-pc', 'family-acc', 8, 'row'), historyAd('owner-pc', 'family-acc', 7, 'blob'),
    historyAd('owner-pc', 'family', 7, 'row'), historyAd('owner-pc-2', 'family-acc', 7, 'row')].map(s);
  assert.equal(new Set([ad, ...variants]).size, 5, 'another seq, part, room or device is another AD');
});

test('valid text and attachment rows', () => {
  const t = validRow(text(3, '안녕'));
  assert.deepEqual(t.header, {seq: 3, sender: 'owner-iphone-1', client: 'owner-iphone-1', kind: 'text', text: '안녕', size: 0});
  assert.equal(t.blob, null);
  const f = validRow(file(4, [1, 2, 255]));
  assert.equal(f.header.size, 3);
  assert.deepEqual(Array.from(f.blob), [1, 2, 255]);
});

test('rows outside the contract are refused', () => {
  const bad = [
    null, [], {...text(1), extra: 1}, {...text(1), seq: 0}, {...text(1), seq: 1.5}, {...text(1), sender: 'bad id'},
    {...text(1), client: 'x'.repeat(65)}, {...text(1), kind: 'image'}, {...text(1), bytes: [1]},
    {...text(1), text: 'x'.repeat(MAX_TEXT + 1)}, {...file(1, [1]), text: 'not empty'}, file(1, [256]), file(1, [-1]),
    file(1, [0.5]),
  ];
  for (const row of bad) assert.throws(() => validRow(row), undefined, JSON.stringify(row)?.slice(0, 80));
  assert.throws(() => validRow(file(1, {length: MAX_BLOB + 1})));
});

test('header round trip is bound to its seq', () => {
  const {header} = validRow(text(9, 'round trip'));
  const plain = encodeHeader(header, 1_700_000_000_000);
  const back = decodeHeader(plain, 9);
  assert.deepEqual(back, {...header, received_at: 1_700_000_000_000});
  assert.throws(() => decodeHeader(plain, 10), undefined, 'a header stored under another seq is refused');
  assert.throws(() => decodeHeader(new TextEncoder().encode('{"seq":9}'), 9));
  assert.throws(() => decodeHeader(Uint8Array.of(0xff, 0xfe), 9), undefined, 'not UTF-8');
});

test('retention removes the oldest rows first until both bounds hold', () => {
  const rows = [{seq: 5, bytes: 10}, {seq: 1, bytes: 10}, {seq: 3, bytes: 10}, {seq: 4, bytes: 10}, {seq: 2, bytes: 10}];
  assert.deepEqual(pruneVictims(rows, {maxRows: 10, maxBytes: 1000}), [], 'within bounds');
  assert.deepEqual(pruneVictims(rows, {maxRows: 3, maxBytes: 1000}), [1, 2], 'row cap');
  assert.deepEqual(pruneVictims(rows, {maxRows: 10, maxBytes: 25}), [1, 2, 3], 'byte cap');
  assert.deepEqual(pruneVictims([{seq: 1, bytes: 100}, {seq: 2, bytes: 1}], {maxRows: 10, maxBytes: 50}), [1], 'one big file goes');
  assert.deepEqual(pruneVictims([], {}), []);
  assert.equal(MAX_ROWS, 2000);
  assert.equal(MAX_BYTES, 200 * 1024 * 1024);
});
