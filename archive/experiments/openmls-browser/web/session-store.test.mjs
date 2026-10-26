// Pure-function tests for the H2 poison-message tombstone rule (#177) in
// session-store.js. No wasm, no IndexedDB: only the decision helper, the ledger
// item shape and the tagged meta encoding. Run: node --test web/session-store.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {classifyDecryptFailure, NOT_POISON, validLedgerItemShape, ledgerItemBytes, createStore, hex, MAX_WIRE, MAX_BINARY} from './session-store.js';

const head = {method: 'decrypt', sequence: 4, cursor: 3, hasGroup: true, error: 'MLS operation rejected', consistent: true};

test('a facade rejection of a decrypt at the head with a consistent session is a tombstone', () => {
  assert.equal(classifyDecryptFailure(head), 'tombstone');
  for (const error of ['MLS operation rejected', 'sender attribution rejected', 'size rejected']) {
    assert.equal(classifyDecryptFailure({...head, error}), 'tombstone', error);
  }
});

test('structural, sequence and device-state failures keep failing', () => {
  const cases = {
    'not a decrypt': {...head, method: 'encrypt'},
    'behind the head': {...head, sequence: 3},
    'ahead of the head': {...head, sequence: 5},
    'non-integer sequence': {...head, sequence: 4.5},
    'no group yet': {...head, hasGroup: false},
    'session not back at the durable state': {...head, consistent: false},
    'consistency unknown': {...head, consistent: undefined},
    'wasm trap / JS Error is not a facade verdict': {...head, error: new Error('unreachable')},
    'undefined error': {...head, error: undefined},
    'state limit is capacity, not the message': {...head, error: 'state limit'},
    'device retired is the device, not the message': {...head, error: 'device retired'},
  };
  for (const [name, input] of Object.entries(cases)) assert.equal(classifyDecryptFailure(input), 'fail', name);
  assert.deepEqual([...NOT_POISON].sort(), ['device retired', 'state limit']);
});

const item = (over = {}) => ({id: 'a1', method: 'decrypt', input: new Uint8Array([1, 2]), output: new Uint8Array(0),
  sequence: 1, epoch: '3', ...over});

test('ledger item shape: rejected is optional, exactly true, decrypt only, no output', () => {
  assert.equal(validLedgerItemShape(item({output: new Uint8Array([9])})), true, 'legacy item without the field');
  assert.equal(validLedgerItemShape(item({rejected: true})), true, 'tombstone');
  assert.equal(validLedgerItemShape(item({rejected: false})), false, 'false must be absent, not stored');
  assert.equal(validLedgerItemShape(item({rejected: 1})), false, 'truthy non-boolean');
  assert.equal(validLedgerItemShape(item({rejected: true, method: 'encrypt'})), false, 'only decrypts are tombstoned');
  assert.equal(validLedgerItemShape(item({rejected: true, output: new Uint8Array([9])})), false, 'a tombstone has no output');
  assert.equal(validLedgerItemShape(item({rejected: true, extra: 1})), false, 'no other keys');
  assert.equal(validLedgerItemShape(item({rejected: undefined})), false, 'present-but-undefined is not absent');
});

test('tagged encoding: legacy items encode exactly as before, tombstones append a 1', () => {
  const legacy = item({output: new Uint8Array([9])});
  assert.deepEqual(ledgerItemBytes(legacy), ['a1', 'decrypt', 1, '3', '0102', '09']);
  assert.deepEqual(ledgerItemBytes(item({rejected: true})), ['a1', 'decrypt', 1, '3', '0102', '', 1]);
  // The exact field the smoke tampers with: removing the flag changes the tagged bytes.
  const tombstone = item({rejected: true}), stripped = item();
  assert.notDeepEqual(ledgerItemBytes(tombstone), ledgerItemBytes(stripped));
});

test('createStore.metaBytes covers the rejected flag (tamper-evident under the meta tag)', () => {
  // No wasm/IDB is touched: metaBytes is a pure encoding of the meta fields.
  const store = createStore({}, {kind: 'durable', identity: 'alice', room: 'main', namePattern: /^x$/, allowed: new Set(['decrypt']),
    extra: {keys: [], initial: () => ({}), bytes: () => null, valid: () => {}}, records: {}});
  const meta = (ledger) => ({version: 4, identity: 'alice', room: 'main', public_key: new Uint8Array(32), group_id: new Uint8Array([7]),
    format: 2, revision: 5, cursor: 1, epoch: '3', set: new Uint8Array(32), count: 3, ledger, acked: [], tag: new Uint8Array(32)});
  const withFlag = hex(store.metaBytes(meta([item({rejected: true})])));
  const without = hex(store.metaBytes(meta([item()])));
  assert.notEqual(withFlag, without);
  // Pre-H2 formula for a legacy item (what existing databases were tagged with).
  const legacy = item({output: new Uint8Array([9])});
  const expected = new TextEncoder().encode(JSON.stringify(['family-mls-meta-v4/durable', 4, 'alice', 'main', '00'.repeat(32), '07',
    2, 5, 1, '3', '00'.repeat(32), 3, [['a1', 'decrypt', 1, '3', '0102', '09']], [], null]));
  assert.equal(hex(store.metaBytes(meta([legacy]))), hex(expected));
});

test('ledger bound holds one full-size attachment operation (input + output), #364 follow-up', () => {
  // 2026-10-15: MAX_BINARY stayed at 2 MiB after MAX_WIRE went to 5 MiB, so a
  // 1.27 MB photo (ciphertext in, plaintext frame out ≈ 2.55 MB) failed validMeta
  // in persist() and relay-app acked past it. §3.6 binding adds 4 + room (≤ 64)
  // bytes to the input; the decrypt frame adds two length-prefixed labels (≤ 64
  // each) to the output.
  const binding = 4 + 64, frame = 2 * (4 + 64);
  assert.ok(MAX_BINARY >= (MAX_WIRE + binding) + (MAX_WIRE + frame), `MAX_BINARY ${MAX_BINARY} < one max operation`);
  assert.ok(MAX_BINARY < 4 * MAX_WIRE, 'bound still limits how many un-acked attachments a ledger may hold');
});

// Rejection diagnostics (2026-10-26, 한데 PC "encrypt 거부"): only fixed reasons,
// error names and file:line frames may leave the worker — never other message text.
test('rejectionDetail keeps fixed reasons, names and frames, and drops free text', async () => {
  const {rejectionDetail, REJECTION_REASONS} = await import('./session-store.js');
  assert.deepEqual(rejectionDetail('state limit'), {reason: 'state limit'});          // facade Rejected (wasm string)
  assert.deepEqual(rejectionDetail('MLS operation rejected'), {reason: 'MLS operation rejected'});
  assert.equal(rejectionDetail(new Error('rejected')).reason, 'rejected');               // fail()
  assert.equal(REJECTION_REASONS.has('transaction rejected'), true);
  // Free text (a JSON/DOM message can quote store contents) is never forwarded.
  const leaky = new SyntaxError('Unexpected token \'s\', "secret plaintext" is not valid JSON');
  const d = rejectionDetail(leaky);
  assert.equal(d.reason, 'other'); assert.equal(d.name, 'SyntaxError');
  assert.equal(JSON.stringify(d).includes('secret'), false);
  // V8 and Firefox frames → file:line only, message line skipped, at most four, deduplicated.
  const e = new Error('rejected');
  e.stack = 'Error: rejected at x.js:1\n    at fail (https://h.example/session-store.js:45:44)\n' +
    '    at validMeta (https://h.example/session-store.js:282:20)\n    at validMeta (https://h.example/session-store.js:282:20)\n' +
    'readMeta@https://h.example/session-store.js:320:5\n    at a (b.js:1:1)\n    at c (d.js:2:2)';
  assert.deepEqual(rejectionDetail(e).where, ['session-store.js:45', 'session-store.js:282', 'session-store.js:320', 'b.js:1']);
  // transaction(): the handler's error rides along as `cause`, the IDB abort as storageError.
  const tx = new Error('transaction rejected'); tx.cause = e; tx.storageError = 'QuotaExceededError';
  const t = rejectionDetail(tx);
  assert.equal(t.reason, 'transaction rejected'); assert.equal(t.storage, 'QuotaExceededError');
  assert.equal(t.inner.reason, 'rejected'); assert.deepEqual(t.inner.where.slice(0, 1), ['session-store.js:45']);
  assert.equal(rejectionDetail(Object.assign(new Error('x'), {storageError: 'bad name!'})).storage, undefined);
  assert.deepEqual(rejectionDetail(undefined), {reason: 'other'});
  // Nesting stops at one level.
  const deep = new Error('rejected'); deep.cause = Object.assign(new Error('rejected'), {cause: new Error('rejected')});
  assert.equal(rejectionDetail(deep).inner.inner, undefined);
});

// 2026-10-26: a ledger item carrying a ~4 MB attachment made every meta read throw —
// decodeMeta's /^([0-9a-f]{2})*$/ overflowed V8's regexp backtrack stack (RangeError) —
// so the room store could no longer decrypt, encrypt, ack or even reopen.
test('hex/fromHex fast paths return exactly what the original expressions return', async () => {
  const {hex, fromHex, hexBytes} = await import('./session-store.js');
  const oldHex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  const oldFromHex = s => new Uint8Array((s.match(/../g) ?? []).map(x => parseInt(x, 16)));
  const all = Uint8Array.from({length: 256}, (_, i) => i);
  for (const bytes of [new Uint8Array(0), all, Uint8Array.from({length: 4099}, (_, i) => (i * 131 + 7) & 255)]) {
    assert.equal(hex(bytes), oldHex(bytes));
    assert.deepEqual(fromHex(oldHex(bytes)), oldFromHex(oldHex(bytes)));
  }
  assert.equal(hex([1, 255, 16]), oldHex([1, 255, 16]));                       // plain arrays: original path
  for (const s of ['', 'abc', 'ABCD', '0g', 'zz12', 'ffée', '1 2 ']) {   // odd/upper/malformed: original semantics
    assert.deepEqual(fromHex(s), oldFromHex(s), JSON.stringify(s));
  }
  assert.equal(hexBytes('ABCD'), null); assert.equal(hexBytes('abc'), null); assert.equal(hexBytes(7), null);
  assert.deepEqual(hexBytes(''), new Uint8Array(0));
});

test('meta with a MAX_WIRE-sized ledger field round-trips (no RangeError), malformed $b still fails', async () => {
  const {encodeMeta, decodeMeta} = await import('./session-store.js');
  const big = Uint8Array.from({length: MAX_WIRE}, (_, i) => (i * 31 + 3) & 255);
  // The original validator throws at this size — the failure this test pins down.
  assert.throws(() => /^([0-9a-f]{2})*$/.test('ab'.repeat(MAX_WIRE)), RangeError);
  const meta = decodeMeta(encodeMeta({ledger: [{input: big, output: big.subarray(0, 1024)}], tag: new Uint8Array([1, 2])}));
  assert.equal(meta.ledger[0].input.length, MAX_WIRE);
  assert.ok(meta.ledger[0].input.every((v, i) => v === big[i]));
  assert.deepEqual(meta.tag, new Uint8Array([1, 2]));
  const utf8 = s => new TextEncoder().encode(s);
  for (const bad of ['{"x":{"$b":"abc"}}', '{"x":{"$b":"ABCD"}}', '{"x":{"$b":12}}', '{"x":{"$b":"ab","y":1}}', '{"x":{"$b":"0g"}}']) {
    assert.throws(() => decodeMeta(utf8(bad)), /rejected/, bad);
  }
  assert.deepEqual(decodeMeta(utf8('{"x":{"$b":""}}')).x, new Uint8Array(0));
});
