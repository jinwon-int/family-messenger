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

// #496: an orphaned (inherited) deferAck decrypt must not block later large decrypts forever.
test('inheritedDecryptsToEvict: only over MAX_BINARY, only inherited decrypts, oldest first, only if it makes room', async () => {
  const {inheritedDecryptsToEvict, ledgerBytes} = await import('./session-store.js');
  const item = (id, method, inBytes, outBytes) => ({id, method, input: new Uint8Array(inBytes), output: new Uint8Array(outBytes), sequence: 1, epoch: '6'});
  // 2026-10-26 field case: leftover 4.2 MB photo decrypt + new 3.0 MB photo decrypt.
  const leftover = item('old-539', 'decrypt', 4215541, 4215500), next = item('new-600', 'decrypt', 3035163, 3035100);
  assert.ok(ledgerBytes([leftover, next]) > MAX_BINARY);
  assert.deepEqual(inheritedDecryptsToEvict([leftover, next], new Set(['old-539'])), ['old-539']);
  assert.ok(ledgerBytes([next]) <= MAX_BINARY);
  // Under the bound: nothing is touched, inherited or not.
  assert.deepEqual(inheritedDecryptsToEvict([leftover], new Set(['old-539'])), []);
  // This worker's own items are never evicted (not inherited) → no room → nothing changes.
  assert.deepEqual(inheritedDecryptsToEvict([leftover, next], new Set()), []);
  assert.deepEqual(inheritedDecryptsToEvict([leftover, next], null), []);
  // Inherited encrypts are not evicted.
  assert.deepEqual(inheritedDecryptsToEvict([item('e', 'encrypt', 4215541, 4215600), next], new Set(['e'])), []);
  // Oldest first, and only as many as needed.
  const a = item('a', 'decrypt', 2_000_000, 2_000_000), b = item('b', 'decrypt', 2_000_000, 2_000_000), big = item('big', 'decrypt', 3_500_000, 3_500_000);
  assert.deepEqual(inheritedDecryptsToEvict([a, b, big], new Set(['a', 'b'])), ['a']);   // 15 MB → 11 MB ≤ bound
  // Evicting every inherited decrypt still cannot make room → evict nothing (operation fails as before).
  const huge = item('huge', 'decrypt', 5_000_000, 5_000_000), small = item('s', 'decrypt', 1_000_000, 1_000_000);
  assert.deepEqual(inheritedDecryptsToEvict([small, huge, item('h2', 'decrypt', 2_000_000, 0)], new Set(['s'])), []);
});

// ---- #766 C1 unlock cache: WebCrypto is node's own; storage is a map (IndexedDB itself is
// exercised by the browser smoke, archive/native-mls/tests/native_mls_multistore_smoke.py). ----
const {createUnlockCache, unlockCacheName, unlockCacheAd, idbUnlockStorage, UNLOCK_CACHE_VERSION} = await import('./session-store.js');
const mapStorage = () => {
  const m = new Map();
  return {m, read: async name => m.get(name), write: async (name, record) => { m.set(name, record); }, remove: async name => { m.delete(name); }};
};
const cacheTarget = (over = {}) => ({identity: 'owner-web-aaaaaa', database: 'family-mls-synthetic-hande--identity',
  custody: {version: 1, vault: 'ab'.repeat(16), capsule: Uint8Array.from({length: 200}, (_, i) => i)},
  passphrase: 'p'.repeat(64), ...over});
const recordKeys = () => ({auth: Uint8Array.from({length: 32}, (_, i) => 100 + i), enc: Uint8Array.from({length: 32}, (_, i) => 200 - i)});
const includesBytes = (hay, needle) => { for (let i = 0; i + needle.length <= hay.length; i++) if (needle.every((v, j) => hay[i + j] === v)) return true; return false; };

test('unlock cache: the database sits next to the store under its own name', () => {
  assert.equal(unlockCacheName('family-mls-synthetic-hande--identity'), 'family-mls-synthetic-hande--identity-unlock');
  assert.equal(UNLOCK_CACHE_VERSION, 1);
});

test('unlock cache: save then load returns the same record keys, as fresh copies', async () => {
  const storage = mapStorage(), cache = createUnlockCache({storage}), keys = recordKeys();
  assert.equal(await cache.load(cacheTarget()), null, 'nothing saved yet → miss');
  assert.equal(await cache.save({...cacheTarget(), ...keys}), true);
  const loaded = await cache.load(cacheTarget());
  assert.deepEqual(loaded, recordKeys());
  assert.deepEqual(keys, recordKeys(), 'save leaves the caller\'s keys alone');
  loaded.auth.fill(0);
  assert.deepEqual((await cache.load(cacheTarget())).auth, recordKeys().auth, 'each load is its own copy');
});

test('unlock cache: the stored record holds a non-extractable key and no raw record key', async () => {
  const storage = mapStorage(), cache = createUnlockCache({storage}), keys = recordKeys();
  await cache.save({...cacheTarget(), ...keys});
  assert.deepEqual([...storage.m.keys()], ['family-mls-synthetic-hande--identity-unlock']);
  const record = storage.m.get('family-mls-synthetic-hande--identity-unlock');
  assert.deepEqual(Object.keys(record).sort(), ['capsule', 'iv', 'key', 'sealed', 'vault', 'version']);
  assert.equal(record.key.extractable, false);
  assert.equal(record.key.type, 'secret');
  assert.deepEqual(record.key.algorithm, {name: 'AES-GCM', length: 256});
  await assert.rejects(crypto.subtle.exportKey('raw', record.key), 'the wrapping key cannot be read out');
  assert.equal(record.sealed.length, 80);
  assert.equal(record.iv.length, 12);
  for (const part of [keys.auth, keys.enc, keys.auth.slice(0, 8), keys.enc.slice(24)]) {
    assert.equal(includesBytes(record.sealed, part), false, 'no record key bytes at rest');
  }
  assert.equal(record.vault, 'ab'.repeat(16));
  assert.match(record.capsule, /^[0-9a-f]{64}$/);
  assert.equal(JSON.stringify(record).includes('p'.repeat(32)), false, 'the passphrase is not stored');
  // Two saves never share a wrapping key or a nonce.
  const first = {iv: record.iv, sealed: record.sealed, key: record.key};
  await cache.save({...cacheTarget(), ...keys});
  const second = storage.m.get('family-mls-synthetic-hande--identity-unlock');
  assert.notEqual(second.key, first.key);
  assert.notDeepEqual(second.iv, first.iv);
  assert.notDeepEqual(second.sealed, first.sealed);
});

test('unlock cache: another device id, database, vault, capsule or passphrase is a miss', async () => {
  const storage = mapStorage(), cache = createUnlockCache({storage});
  await cache.save({...cacheTarget(), ...recordKeys()});
  const moved = name => storage.m.set(unlockCacheName(name), storage.m.get(unlockCacheName(cacheTarget().database)));
  moved('family-mls-synthetic-other');
  const otherCapsule = cacheTarget().custody.capsule.slice(); otherCapsule[7] ^= 1;
  const misses = {
    'device id': cacheTarget({identity: 'owner-web-bbbbbb'}),
    'database (record copied under another name)': cacheTarget({database: 'family-mls-synthetic-other'}),
    'vault': cacheTarget({custody: {...cacheTarget().custody, vault: 'cd'.repeat(16)}}),
    'capsule': cacheTarget({custody: {...cacheTarget().custody, capsule: otherCapsule}}),
    'passphrase': cacheTarget({passphrase: 'q'.repeat(64)}),
  };
  for (const [what, target] of Object.entries(misses)) assert.equal(await cache.load(target), null, what);
  assert.deepEqual(await cache.load(cacheTarget()), recordKeys(), 'the right target still opens');
  // The additional data is what separates them (store format, identity, database, vault, capsule, passphrase).
  const ads = await Promise.all([cacheTarget(), ...Object.values(misses)].map(async t => new TextDecoder().decode((await unlockCacheAd(t)).ad)));
  assert.equal(new Set(ads).size, ads.length);
  assert.ok(ads[0].startsWith('["family-mls-unlock-cache-v1",2,4,"owner-web-aaaaaa","family-mls-synthetic-hande--identity","' + 'ab'.repeat(16) + '",'));
  assert.equal(ads[0].includes('p'.repeat(8)), false, 'the passphrase enters only as a digest');
});

test('unlock cache: a tampered or malformed record is a miss, never an error', async () => {
  const storage = mapStorage(), cache = createUnlockCache({storage}), name = unlockCacheName(cacheTarget().database);
  await cache.save({...cacheTarget(), ...recordKeys()});
  const good = storage.m.get(name);
  const flip = (bytes, at) => { const b = bytes.slice(); b[at] ^= 1; return b; };
  const extractable = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, true, ['encrypt', 'decrypt']);
  const shortKey = await crypto.subtle.generateKey({name: 'AES-GCM', length: 128}, false, ['encrypt', 'decrypt']);
  const otherKey = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, false, ['encrypt', 'decrypt']);
  const hmac = await crypto.subtle.generateKey({name: 'HMAC', hash: 'SHA-256'}, false, ['sign']);
  const bad = {
    'sealed flipped (first byte)': {...good, sealed: flip(good.sealed, 0)},
    'sealed flipped (tag)': {...good, sealed: flip(good.sealed, 79)},
    'iv flipped': {...good, iv: flip(good.iv, 3)},
    'sealed too short': {...good, sealed: good.sealed.slice(0, 79)},
    'sealed too long': {...good, sealed: new Uint8Array(81)},
    'iv wrong length': {...good, iv: new Uint8Array(16)},
    'another wrapping key': {...good, key: otherKey},
    'extractable wrapping key': {...good, key: extractable},
    '128-bit wrapping key': {...good, key: shortKey},
    'not an AES-GCM key': {...good, key: hmac},
    'key is not a key': {...good, key: 'x'}, 'key is null': {...good, key: null},
    'version': {...good, version: 2}, 'vault shape': {...good, vault: 'AB'.repeat(16)}, 'capsule shape': {...good, capsule: 'ab'},
    'extra field': {...good, extra: 1}, 'missing field': (({iv, ...rest}) => rest)(good),
    'arrays as plain arrays': {...good, sealed: Array.from(good.sealed)},
    'null': null, 'string': 'record', 'array': [good],
  };
  for (const [what, record] of Object.entries(bad)) {
    storage.m.set(name, record);
    assert.equal(await cache.load(cacheTarget()), null, what);
  }
  storage.m.set(name, good);
  assert.deepEqual(await cache.load(cacheTarget()), recordKeys());
});

test('unlock cache: a record that authenticates under a readable or weaker wrapping key is still refused', async () => {
  // Everything about these records is right — additional data, seal, sizes — except the
  // wrapping key itself, so only the key check stands between them and the record keys.
  const storage = mapStorage(), cache = createUnlockCache({storage}), name = unlockCacheName(cacheTarget().database);
  const {capsule, ad} = await unlockCacheAd(cacheTarget());
  const plain = new Uint8Array(64); plain.set(recordKeys().auth); plain.set(recordKeys().enc, 32);
  const sealedUnder = async key => {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    return {version: 1, vault: cacheTarget().custody.vault, capsule, key, iv,
      sealed: new Uint8Array(await crypto.subtle.encrypt({name: 'AES-GCM', iv, additionalData: ad}, key, plain))};
  };
  const proper = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, false, ['encrypt', 'decrypt']);
  storage.m.set(name, await sealedUnder(proper));
  assert.deepEqual(await cache.load(cacheTarget()), recordKeys(), 'the hand-built record is otherwise valid');
  const extractable = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, true, ['encrypt', 'decrypt']);
  storage.m.set(name, await sealedUnder(extractable));
  assert.equal(await cache.load(cacheTarget()), null, 'extractable wrapping key');
  const short = await crypto.subtle.generateKey({name: 'AES-GCM', length: 128}, false, ['encrypt', 'decrypt']);
  storage.m.set(name, await sealedUnder(short));
  assert.equal(await cache.load(cacheTarget()), null, '128-bit wrapping key');
});

test('unlock cache: wrong-size keys are not saved', async () => {
  const storage = mapStorage(), cache = createUnlockCache({storage});
  for (const keys of [{auth: new Uint8Array(31), enc: new Uint8Array(32)}, {auth: new Uint8Array(32), enc: new Uint8Array(33)},
    {auth: Array(32).fill(1), enc: new Uint8Array(32)}, {auth: new Uint8Array(32)}]) {
    assert.equal(await cache.save({...cacheTarget(), ...keys}), false);
  }
  assert.equal(storage.m.size, 0);
});

test('unlock cache: storage that refuses, throws or never answers is harmless', async () => {
  // CryptoKey not storable (DataCloneError), a blocked database, a private-mode failure…
  const refusing = {read: async () => { throw new Error('DataCloneError'); }, write: async () => { throw new Error('DataCloneError'); },
    remove: async () => { throw new Error('blocked'); }};
  const a = createUnlockCache({storage: refusing});
  assert.equal(await a.save({...cacheTarget(), ...recordKeys()}), false);
  assert.equal(await a.load(cacheTarget()), null);
  assert.equal(await a.clear(cacheTarget().database), false);
  const throwing = {read: () => { throw new Error('sync'); }, write: () => { throw new Error('sync'); }, remove: () => { throw new Error('sync'); }};
  const b = createUnlockCache({storage: throwing});
  assert.equal(await b.save({...cacheTarget(), ...recordKeys()}), false);
  assert.equal(await b.load(cacheTarget()), null);
  assert.equal(await b.clear(cacheTarget().database), false);
  // Never answers: each call gives up at the deadline instead of holding the start.
  const hanging = {read: () => new Promise(() => {}), write: () => new Promise(() => {}), remove: () => new Promise(() => {})};
  const c = createUnlockCache({storage: hanging, timeoutMs: 30});
  const started = Date.now();
  assert.equal(await c.load(cacheTarget()), null);
  assert.equal(await c.save({...cacheTarget(), ...recordKeys()}), false);
  assert.equal(await c.clear(cacheTarget().database), false);
  assert.ok(Date.now() - started < 1000, 'bounded by timeoutMs');
});

test('unlock cache: a load that finishes after the deadline wipes the keys it produced', async () => {
  const storage = mapStorage(), fast = createUnlockCache({storage});
  await fast.save({...cacheTarget(), ...recordKeys()});
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const produced = [];
  const subtle = {digest: (...a) => crypto.subtle.digest(...a),
    decrypt: async (...a) => { await gate; const plain = new Uint8Array(await crypto.subtle.decrypt(...a)); produced.push(plain); return plain.buffer; }};
  const slow = createUnlockCache({storage, subtle, timeoutMs: 20});
  assert.equal(await slow.load(cacheTarget()), null, 'deadline → miss');
  // The two 32-byte copies the late load hands to nobody are only reachable through the wipe itself.
  const wiped = [], fill = Uint8Array.prototype.fill;
  Uint8Array.prototype.fill = function (...args) { if (this.length === 32 && args[0] === 0) wiped.push(Array.from(this)); return fill.apply(this, args); };
  try {
    release();
    await new Promise(resolve => setTimeout(resolve, 20));
  } finally { Uint8Array.prototype.fill = fill; }
  assert.equal(produced.length, 1);
  assert.ok(produced[0].every(v => v === 0), 'the late plaintext is zeroed');
  assert.deepEqual(wiped, [Array.from(recordKeys().auth), Array.from(recordKeys().enc)], 'and so are both key copies');
});

test('unlock cache: no WebCrypto means no cache, not a failure', async () => {
  // What a worker outside a secure context sees: `crypto.subtle` is absent.
  const storage = mapStorage(), cache = createUnlockCache({storage, subtle: null});
  assert.equal(await cache.save({...cacheTarget(), ...recordKeys()}), false);
  assert.equal(await cache.load(cacheTarget()), null);
  assert.equal(storage.m.size, 0);
});

test('unlock cache: clear removes exactly the cache database', async () => {
  const storage = mapStorage(), cache = createUnlockCache({storage});
  await cache.save({...cacheTarget(), ...recordKeys()});
  storage.m.set('family-mls-synthetic-hande--identity', 'the store itself');
  assert.equal(await cache.clear(cacheTarget().database), true);
  assert.deepEqual([...storage.m.keys()], ['family-mls-synthetic-hande--identity']);
  assert.equal(await cache.load(cacheTarget()), null);
  assert.equal(await cache.clear(cacheTarget().database), true, 'clearing nothing is fine');
});

test('unlock cache: IndexedDB backing opens one store, closes every handle and refuses another schema', async () => {
  const log = [];
  const fakeIdb = ({stores = [], oldVersion = 0, value} = {}) => ({
    open(name, version) {
      const request = {};
      const db = {objectStoreNames: {length: stores.length, contains: n => stores.includes(n)},
        createObjectStore: n => { stores.push(n); db.objectStoreNames.length = stores.length; },
        close: () => log.push('close'),
        transaction(store, mode) {
          log.push(`tx ${store} ${mode}`);
          const tx = {objectStore: () => ({get: key => { log.push(`get ${key}`); return {result: value}; }, put: (v, key) => { log.push(`put ${key}`); value = v; return {result: key}; }})};
          queueMicrotask(() => tx.oncomplete());
          return tx;
        }};
      queueMicrotask(() => {
        log.push(`open ${name} v${version}`);
        request.result = db;
        if (stores.length === 0 || oldVersion !== 0) request.onupgradeneeded({oldVersion});
        request.onsuccess();
      });
      return request;
    },
    deleteDatabase(name) { const request = {}; queueMicrotask(() => { log.push(`delete ${name}`); request.onsuccess(); }); return request; },
  });
  const fresh = idbUnlockStorage(fakeIdb());
  assert.equal(await fresh.read('db-unlock'), undefined);
  await fresh.write('db-unlock', {any: 1});
  await fresh.remove('db-unlock');
  assert.deepEqual(log, ['open db-unlock v1', 'tx cache readonly', 'get record', 'close',
    'open db-unlock v1', 'tx cache readwrite', 'put record', 'close', 'delete db-unlock']);
  log.length = 0;
  const foreign = idbUnlockStorage(fakeIdb({stores: ['cache', 'other']}));
  await assert.rejects(foreign.read('db-unlock'), /unknown schema/);
  assert.deepEqual(log, ['open db-unlock v1', 'close']);
  // Through the cache, that is just a miss.
  const cache = createUnlockCache({storage: foreign});
  assert.equal(await cache.load(cacheTarget()), null);
});
