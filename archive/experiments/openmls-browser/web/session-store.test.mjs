// Pure-function tests for the H2 poison-message tombstone rule (#177) in
// session-store.js. No wasm, no IndexedDB: only the decision helper, the ledger
// item shape and the tagged meta encoding. Run: node --test web/session-store.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {classifyDecryptFailure, NOT_POISON, validLedgerItemShape, ledgerItemBytes, createStore, hex} from './session-store.js';

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
