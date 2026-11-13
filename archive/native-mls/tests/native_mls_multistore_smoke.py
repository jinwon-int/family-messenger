#!/usr/bin/env python3
"""Multi-store durable worker smoke (#431 stage 4): one identity store, cloned
room stores and a lobby store inside a single durable worker, driven over
loopback with Python shuttling the MLS bytes. No relay, no human device.

  context A  owner-web-aaaaaa  MULTI mode  (init_multi → open_room r1 / -lobby / r2)
  context B  mom-web-bbbbbb    SINGLE mode (plain init, room r2) — unchanged worker
  context C  jin-web-cccccc    legacy single-store DB migrated into an identity store
  context D  dad-web-dddddd    MULTI mode with the unlock cache (#766 C1)
  context E  sis-web-eeeeee    legacy migration with the unlock cache

Flow: A creates r1 from the identity store and mints two lobby key packages; B
(single-store) invites A's first lobby package with a Welcome-only `invite`; A
opens r2 as a lobby clone, joins from the Welcome, exchanges messages with B
while r1 stays untouched; lobby bookkeeping; negatives; worker restart (resume);
legacy migration on C. Then the unlock cache on D and E: `unlock_cache {enabled: true}`
before `init_multi` makes later starts open the identity store from wrapped record keys
(no KDF); a tampered record, a validly sealed record holding the wrong keys, a wrong
passphrase and a start without the message all take the KDF path as before, and the
cache database holds a non-extractable key and nothing readable.

  python3 archive/native-mls/tests/native_mls_multistore_smoke.py --bundle <pkg dir>

Receipt: archive/artifacts/native-multistore-*/verification.json. Exit status
is non-zero on any failed check (page consoles are dumped to stderr).
"""
import argparse
import hashlib
import json
import os
import secrets
import struct
import sys
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

ARCHIVE = Path(__file__).resolve().parents[2]           # archive/
WEB = ARCHIVE / 'experiments/openmls-browser/web'
MEMORY_CAP = 128 * 1024 * 1024
ROOM_SCOPED_METHODS = ('status', 'ack', 'operation', 'history_put', 'history_list', 'history_get')

# Device ids, one per browser context (the identity is the device id).
OWNER, MOM, JIN = 'owner-web-aaaaaa', 'mom-web-bbbbbb', 'jin-web-cccccc'
DAD, SIS = 'dad-web-dddddd', 'sis-web-eeeeee'
# Step 7 (migration) uses the fixed names from the stage-4 brief; context C is a
# fresh browser context, so they cannot collide with anything.
JIN_LEGACY_DB = 'family-mls-synthetic-legacy-jin'
JIN_IDENTITY_DB = 'family-mls-synthetic-ms-jin--identity'
JIN_OTHER_DB = 'family-mls-synthetic-ms-jin-other'


# ---------------------------------------------------------------- helpers ----

# Unlock cache (#766 C1) — raw IndexedDB access from the page (the worker is stopped, or
# has closed its cache handle: it opens the cache database per operation).
JS_IDB = '''
const openDb = name => new Promise((res, rej) => { const r = indexedDB.open(name); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
const done = q => new Promise((res, rej) => { q.onsuccess = () => res(q.result); q.onerror = () => rej(q.error); });
const exists = async name => (await indexedDB.databases()).some(d => d.name === name);
const withCache = async (name, mode, work) => {
  const db = await openDb(name);
  try {
    const tx = db.transaction('cache', mode), store = tx.objectStore('cache');
    const finished = new Promise((res, rej) => { tx.oncomplete = () => res(); tx.onabort = tx.onerror = () => rej(tx.error); });
    const value = await work(store, db);
    await finished;
    return value;
  } finally { db.close(); }
};
'''
JS_CACHE_READ = '(async name => {' + JS_IDB + '''
  if (!await exists(name)) return {exists: false};
  const {record, stores, version} = await withCache(name, 'readonly', async (store, db) =>
    ({record: await done(store.get('record')), stores: Array.from(db.objectStoreNames), version: db.version}));
  if (!record) return {exists: true, stores, version, record: null};
  let exported = 'exported';
  try { await crypto.subtle.exportKey('raw', record.key); } catch (e) { exported = e.name; }
  return {exists: true, stores, version, fields: Object.keys(record).sort(), record_version: record.version,
    vault: record.vault, capsule: record.capsule, iv: Array.from(record.iv), sealed: Array.from(record.sealed),
    key: {type: record.key.type, extractable: record.key.extractable, algorithm: record.key.algorithm.name,
          length: record.key.algorithm.length, usages: Array.from(record.key.usages).sort()},
    export_attempt: exported};
})'''
JS_CACHE_TAMPER = '(async name => {' + JS_IDB + '''
  await withCache(name, 'readwrite', async store => {
    const record = await done(store.get('record'));
    record.sealed[5] ^= 1;
    await done(store.put(record, 'record'));
  });
})'''
# A record that authenticates (right wrapping key, right additional data) but carries
# keys that do not open the store: only the worker's own retry can recover from it.
JS_CACHE_FORGE = '(async ([name, identity, database, passphrase]) => {' + JS_IDB + '''
  const {unlockCacheAd} = await import('/session-store.js');
  const sdb = await openDb(database);
  let custody;
  try { custody = await done(sdb.transaction('meta').objectStore('meta').get('custody')); } finally { sdb.close(); }
  const {ad} = await unlockCacheAd({identity, database, custody, passphrase});
  await withCache(name, 'readwrite', async store => {
    const record = await done(store.get('record'));
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const sealed = new Uint8Array(await crypto.subtle.encrypt({name: 'AES-GCM', iv, additionalData: ad}, record.key, new Uint8Array(64).fill(9)));
    await done(store.put({...record, iv, sealed}, 'record'));
  });
})'''
JS_DB_EXISTS = 'async name => (await indexedDB.databases()).some(d => d.name === name)'

def parse_members(framed):
    """relay-app.js parseMembers: u32 LE count, then (u32 LE len ‖ identity ‖ 32-byte key)*."""
    data = bytes(framed)
    (count,) = struct.unpack_from('<I', data, 0)
    at, out = 4, []
    for _ in range(count):
        (n,) = struct.unpack_from('<I', data, at)
        at += 4
        out.append(data[at:at + n].decode())
        at += n + 32
    assert at == len(data), ('members frame has trailing bytes', len(data) - at)
    return out


def op_id():
    """Unique ledger id per call (ids must never be reused: PERSISTENCE.md ledger rules)."""
    return format(int(time.time() * 1000), 'x') + '-' + secrets.token_hex(6)


class Rejected(AssertionError):
    pass


class Worker:
    """One durable worker in one page. `call` is the raw envelope; `op` is relay-app's
    op(): one `operation` call followed by an `ack` of its ledger id (unless transient)."""

    def __init__(self, context, name, label, receipt, host):
        self.name, self.label, self.receipt = name, label, receipt
        self.console = []
        self.page = context.new_page()
        self.page.on('console', lambda m: self.console.append(f'[{m.type}] {m.text}'))
        self.page.on('pageerror', lambda e: self.console.append(f'[pageerror] {e}'))
        self.page.goto('http://' + host)
        self.page.wait_for_function('window.ready === true')
        self.spawn()

    def spawn(self):
        self.page.evaluate('name => spawn(name, true)', self.name)

    def stop(self):
        self.page.evaluate('name => stopWorker(name)', self.name)

    def call(self, method, argument=None, reject=False):
        """Envelope {id, method, argument} → {id, ok, result|error, memory_bytes}."""
        value = self.page.evaluate('([name, method, argument]) => call(name, method, argument)',
                                   [self.name, method, argument])
        memory = value.get('memory_bytes', 0)
        self.receipt['max_worker_linear_memory_bytes'] = max(self.receipt['max_worker_linear_memory_bytes'], memory)
        assert memory <= MEMORY_CAP, ('worker memory over cap', memory)
        if reject:
            if value.get('ok') is not False or 'result' in value:
                raise AssertionError(f'{self.label}: {method} must be rejected, got {json.dumps(value)[:400]}')
            return None
        if value.get('ok') is not True:
            raise Rejected(f'{self.label}: {method} {json.dumps(argument, default=str)[:200]} → {json.dumps(value)[:400]}')
        return value['result']

    def op(self, room, method, data=None, sequence=0, reject=False):
        """room=None → single-store worker (no `room` key at all); else room-scoped."""
        argument = {'id': op_id(), 'method': method, 'bytes': list(data or []), 'sequence': sequence, 'fault': ''}
        if room is not None:
            argument['room'] = room
        result = self.call('operation', argument, reject)
        if reject:
            return None
        if not result.get('transient'):   # stage_commit has no ledger item; everything else does (tombstones too)
            ack = {'ids': [argument['id']]}
            if room is not None:
                ack['room'] = room
            self.call('ack', ack)
        return result

    def status(self, room=None):
        return self.call('status', None if room is None else {'room': room})

    def members(self, room=None):
        return parse_members(self.op(room, 'members')['output'])

    def decrypt(self, room, ciphertext):
        """§3.6: the durable worker binds room/client itself — raw ciphertext in, plaintext out.
        sequence = cursor + 1 from the latest status{room}."""
        cursor = self.status(room)['cursor']
        result = self.op(room, 'decrypt', ciphertext, sequence=cursor + 1)
        assert result.get('rejected') is not True, (self.label, 'decrypt tombstoned', result)
        assert result['cursor'] == cursor + 1, (self.label, 'cursor did not advance', result)
        return result


# --------------------------------------------------------------- the flow ----

def run_flow(browser, host, receipt):
    checks = receipt['checks']
    prefix = 'family-mls-synthetic-ms-' + secrets.token_hex(6)
    db = {'a_identity': f'{prefix}-a-identity', 'a_r1': f'{prefix}-a-r1', 'a_lobby': f'{prefix}-a-lobby',
          'a_r2': f'{prefix}-a-r2', 'a_r3': f'{prefix}-a-r3', 'a_single': f'{prefix}-a-single', 'b': f'{prefix}-b'}
    receipt['databases'] = {**db, 'c_legacy': JIN_LEGACY_DB, 'c_identity': JIN_IDENTITY_DB, 'c_other': JIN_OTHER_DB}
    # Custody passphrases (32–128 chars, same rule as `init`): synthetic, never logged.
    passphrase = {k: secrets.token_urlsafe(36) for k in 'abc'}
    workers = []

    def timed(label, fn):
        started = time.monotonic()
        value = fn()
        receipt['timings_seconds'][label] = round(time.monotonic() - started, 3)
        return value

    try:
        # ---- 1. A: identity store, r1 from identity, create, fingerprint ----
        A = Worker(browser.new_context(), 'A', OWNER, receipt, host)
        workers.append(A)
        init_a = timed('init_multi_first', lambda: A.call('init_multi', {
            'identity': OWNER, 'passphrase': passphrase['a'], 'identity_database': db['a_identity']}))
        assert init_a['fresh'] is True and init_a['migrated'] is False and init_a['unlock'] == 'fresh', init_a
        pk = init_a['public_key']
        assert isinstance(pk, list) and len(pk) == 32, ('public_key', pk)
        checks['init_multi_fresh_identity_store'] = True

        r1 = timed('open_room_r1_first', lambda: A.call('open_room', {'room': 'r1', 'database': db['a_r1'], 'from': 'identity'}))
        assert r1['fresh'] is True and r1['public_key'] == pk, r1
        st_r1 = A.status('r1')
        assert st_r1['public_key'] == pk, st_r1
        A.op('r1', 'create')
        assert A.members('r1') == [OWNER]
        checks['room_cloned_from_identity_shares_signing_key_and_creates_group'] = True

        fingerprint = bytes(A.op('-identity', 'fingerprint')['output']).decode()
        assert fingerprint == hashlib.sha256(bytes(pk)).hexdigest(), (fingerprint, 'sha256(public_key)')
        checks['identity_store_fingerprint_is_sha256_of_public_key'] = True

        # ---- 2. A: lobby store, two key packages, reopen r1 ----
        lobby = timed('open_room_lobby_first', lambda: A.call('open_room', {'room': '-lobby', 'database': db['a_lobby'], 'from': 'identity'}))
        assert lobby['fresh'] is True and lobby['public_key'] == pk, lobby
        kp1 = A.op('-lobby', 'key_package')['output']
        kp2 = A.op('-lobby', 'key_package')['output']
        assert kp1 and kp2 and kp1 != kp2
        assert A.status('-lobby')['public_key'] == pk
        checks['lobby_store_mints_two_key_packages'] = True

        # A second open_room on an already-open room is idempotent, or (if the worker
        # refuses that) close_room + open_room must reopen the existing DB.
        try:
            again = A.call('open_room', {'room': 'r1', 'database': db['a_r1'], 'from': 'identity'})
            receipt['reopen_path'] = 'idempotent open_room'
        except Rejected:
            A.call('close_room', {'room': 'r1'})
            again = A.call('open_room', {'room': 'r1', 'database': db['a_r1'], 'from': 'identity'})
            receipt['reopen_path'] = 'close_room then open_room'
        assert again['fresh'] is False and again['public_key'] == pk, again
        assert A.members('r1') == [OWNER]
        checks['reopen_existing_room_keeps_group'] = True

        # ---- 3. B single-store invites A's lobby package; A joins r2 as a lobby clone ----
        B = Worker(browser.new_context(), 'B', MOM, receipt, host)
        workers.append(B)
        init_b = timed('init_single_b', lambda: B.call('init', {'identity': MOM, 'database': db['b'], 'room': 'r2', 'passphrase': passphrase['b']}))
        assert init_b['fresh'] is True, init_b
        B.op(None, 'create')
        # Durable-lane `invite` = Welcome-only add that merges immediately (lib.rs add_members_inner(.., merge=true)).
        welcome = B.op(None, 'invite', kp1)['output']
        assert sorted(B.members()) == sorted([MOM, OWNER]), B.members()   # merged immediately: A's lobby identity is a member

        r1_before = A.status('r1')
        r2 = timed('open_room_r2_from_lobby', lambda: A.call('open_room', {'room': 'r2', 'database': db['a_r2'], 'from': 'lobby'}))
        assert r2['fresh'] is True and r2['public_key'] == pk, r2
        A.op('r2', 'join', welcome)
        assert A.members('r2') == sorted([MOM, OWNER])
        assert B.members() == sorted([MOM, OWNER])
        checks['single_store_welcome_joined_via_lobby_clone'] = True

        c1 = B.op(None, 'encrypt', b'hello r2')['output']
        d1 = A.decrypt('r2', c1)
        assert bytes(d1['output']) == b'hello r2' and d1['sender'] == MOM, d1
        c2 = A.op('r2', 'encrypt', 'hello from owner 한글'.encode())['output']
        b_cursor = B.status()['cursor']
        d2 = B.op(None, 'decrypt', c2, sequence=b_cursor + 1)
        assert bytes(d2['output']) == 'hello from owner 한글'.encode() and d2['sender'] == OWNER, d2
        checks['messages_both_ways_between_multi_r2_and_single_store'] = True

        r1_after = A.status('r1')
        frozen = ('revision', 'cursor', 'entries', 'public_key', 'epoch')   # epoch only if the worker reports it
        assert {k: r1_before.get(k) for k in frozen} == {k: r1_after.get(k) for k in frozen}, (r1_before, r1_after)
        assert A.members('r1') == [OWNER]
        checks['r1_unaffected_by_r2_join_and_messages'] = True

        # ---- 4. lobby bookkeeping ----
        assert A.status('-lobby')['public_key'] == pk
        A.op('-lobby', 'delete_key_package', kp1)
        A.op('-lobby', 'delete_key_package', kp1, reject=True)
        checks['lobby_consumed_key_package_deleted_once_then_rejected'] = True

        # ---- 5. negatives ----
        A.call('open_room', {'room': 'r3', 'database': db['a_r3'], 'from': 'bogus'}, reject=True)
        A.call('operation', {'id': op_id(), 'method': 'members', 'bytes': [], 'sequence': 0, 'fault': ''}, reject=True)
        A.op('r9', 'members', reject=True)
        A.call('init', {'identity': OWNER, 'database': db['a_single'], 'room': 'r1', 'passphrase': passphrase['a']}, reject=True)
        assert A.members('r1') == [OWNER]   # the worker is still healthy after the refusals
        checks['negative_bogus_from_roomless_op_unopened_room_single_init_after_multi'] = True

        # reset_room: a group-less room store (identity clone) is replaced by a lobby clone
        # under the same database name — the documented recovery for a room opened too early.
        r3 = A.call('open_room', {'room': 'r3', 'database': db['a_r3'], 'from': 'identity'})
        assert r3['fresh'] is True and r3['public_key'] == pk, r3
        A.op('r3', 'members', reject=True)   # no group yet
        A.call('reset_room', {'room': 'r3', 'database': db['a_r3']})
        A.op('r3', 'members', reject=True)   # closed: room-scoped messages refuse
        r3_lobby = A.call('open_room', {'room': 'r3', 'database': db['a_r3'], 'from': 'lobby'})
        assert r3_lobby['fresh'] is True and r3_lobby['public_key'] == pk, r3_lobby
        checks['reset_room_replaces_groupless_store_with_lobby_clone'] = True

        # ---- 6. resume: stop the worker, spawn again, same identity DB + passphrase ----
        A.stop()
        A.spawn()
        started = time.monotonic()
        init_again = A.call('init_multi', {'identity': OWNER, 'passphrase': passphrase['a'], 'identity_database': db['a_identity']})
        assert init_again['fresh'] is False and init_again['migrated'] is False and init_again['public_key'] == pk, init_again
        # No `unlock_cache` message on A: the KDF ran again and nothing was cached (#766 C1).
        assert init_again['unlock'] == 'kdf', init_again
        assert A.page.evaluate(JS_DB_EXISTS, db['a_identity'] + '-unlock') is False
        checks['no_unlock_cache_without_the_message'] = True
        r1_again = A.call('open_room', {'room': 'r1', 'database': db['a_r1'], 'from': 'identity'})
        r2_again = A.call('open_room', {'room': 'r2', 'database': db['a_r2'], 'from': 'lobby'})
        receipt['timings_seconds']['resume_init_multi_plus_two_open_room'] = round(time.monotonic() - started, 3)
        assert r1_again['fresh'] is False and r2_again['fresh'] is False, (r1_again, r2_again)
        assert r1_again['public_key'] == pk and r2_again['public_key'] == pk
        assert A.members('r2') == sorted([MOM, OWNER]) and A.members('r1') == [OWNER]
        checks['resume_reopens_identity_and_rooms_without_fresh_keys'] = True
        c3 = B.op(None, 'encrypt', b'after resume')['output']
        d3 = A.decrypt('r2', c3)
        assert bytes(d3['output']) == b'after resume' and d3['sender'] == MOM, d3
        checks['resume_decrypts_new_message_on_r2'] = True

        # ---- 7. migration: legacy single-store DB → identity store, group kept ----
        C = Worker(browser.new_context(), 'C', JIN, receipt, host)
        workers.append(C)
        legacy = timed('init_single_c_legacy', lambda: C.call('init', {'identity': JIN, 'database': JIN_LEGACY_DB, 'room': 'fam', 'passphrase': passphrase['c']}))
        assert legacy['fresh'] is True, legacy
        C.op(None, 'create')
        pk_c = C.status()['public_key']
        assert C.members() == [JIN]
        C.stop()
        C.spawn()
        migrated = timed('init_multi_c_migrated', lambda: C.call('init_multi', {
            'identity': JIN, 'passphrase': passphrase['c'], 'identity_database': JIN_IDENTITY_DB,
            'legacy': {'database': JIN_LEGACY_DB, 'room': 'fam'}}))
        assert migrated['fresh'] is True and migrated['migrated'] is True and migrated['public_key'] == pk_c, migrated
        fam = C.call('open_room', {'room': 'fam', 'database': JIN_LEGACY_DB, 'from': 'identity'})
        assert fam['fresh'] is False and fam['public_key'] == pk_c, fam
        assert C.members('fam') == [JIN]
        checks['legacy_single_store_migrates_identity_and_keeps_group'] = True
        other = C.call('open_room', {'room': 'other', 'database': JIN_OTHER_DB, 'from': 'identity'})
        assert other['fresh'] is True and other['public_key'] == pk_c, other
        checks['migrated_identity_clones_new_room_with_same_key'] = True

        # ---- 8. unlock cache (#766 C1): later starts skip the KDF; every miss is the old path ----
        D = Worker(browser.new_context(), 'D', DAD, receipt, host)
        workers.append(D)
        d_identity, d_r1, d_cache = f'{prefix}-d-identity', f'{prefix}-d-r1', f'{prefix}-d-identity-unlock'
        d_pass = secrets.token_urlsafe(36)
        d_init = {'identity': DAD, 'passphrase': d_pass, 'identity_database': d_identity}
        cache = lambda: D.page.evaluate(JS_CACHE_READ, d_cache)   # noqa: E731

        def restart(enable=True):
            D.stop()
            D.spawn()
            if enable:
                assert D.call('unlock_cache', {'enabled': True}) == {'enabled': True}

        for bad in ({}, {'enabled': 'yes'}, {'enabled': 1}, {'enabled': True, 'x': 1}, None):
            D.call('unlock_cache', bad, reject=True)
        assert D.call('unlock_cache', {'enabled': False}) == {'enabled': False}
        assert D.call('unlock_cache', {'enabled': True}) == {'enabled': True}   # the last one before init_multi counts
        d_first = timed('unlock_cache_first_start', lambda: D.call('init_multi', d_init))
        assert d_first['fresh'] is True and d_first['unlock'] == 'fresh', d_first
        d_pk = d_first['public_key']
        D.call('unlock_cache', {'enabled': False}, reject=True)   # not after init_multi
        assert D.call('open_room', {'room': 'r1', 'database': d_r1, 'from': 'identity'})['fresh'] is True
        D.op('r1', 'create')
        saved = cache()
        assert saved['exists'] and saved['stores'] == ['cache'] and saved['version'] == 1, saved
        assert saved['fields'] == ['capsule', 'iv', 'key', 'sealed', 'vault', 'version'] and saved['record_version'] == 1, saved
        assert saved['key'] == {'type': 'secret', 'extractable': False, 'algorithm': 'AES-GCM', 'length': 256,
                                'usages': ['decrypt', 'encrypt']}, saved['key']
        assert saved['export_attempt'] != 'exported', 'the wrapping key must not be readable'
        assert len(saved['iv']) == 12 and len(saved['sealed']) == 80, saved
        checks['unlock_cache_saved_after_first_start_with_non_extractable_key'] = True

        restart()
        d_fast = timed('unlock_cache_hit_start', lambda: D.call('init_multi', d_init))
        assert d_fast['unlock'] == 'cache' and d_fast['fresh'] is False and d_fast['public_key'] == d_pk, d_fast
        r1_fast = D.call('open_room', {'room': 'r1', 'database': d_r1, 'from': 'identity'})
        assert r1_fast['fresh'] is False and r1_fast['public_key'] == d_pk and D.members('r1') == [DAD], r1_fast
        assert cache()['sealed'] == saved['sealed'], 'a hit does not rewrite the record'
        checks['unlock_cache_hit_opens_identity_and_sibling_room_without_kdf'] = True

        # wrong passphrase: the cache does not open for it and the KDF refuses it, as before
        restart()
        refused = D.page.evaluate('([name, method, argument]) => call(name, method, argument)',
                                  [D.name, 'init_multi', {**d_init, 'passphrase': secrets.token_urlsafe(36)}])
        assert refused.get('ok') is False and refused.get('stage') == 'identity_unlock', refused
        assert cache()['sealed'] == saved['sealed'], 'a refused start leaves the cache alone'
        checks['unlock_cache_does_not_open_for_another_passphrase'] = True

        # tampered record → KDF → record rewritten → hit again
        restart(enable=False)
        D.page.evaluate(JS_CACHE_TAMPER, d_cache)
        tampered = cache()['sealed']
        assert tampered != saved['sealed']
        restart()
        d_kdf = timed('unlock_cache_miss_start_kdf', lambda: D.call('init_multi', d_init))
        assert d_kdf['unlock'] == 'kdf' and d_kdf['fresh'] is False and d_kdf['public_key'] == d_pk, d_kdf
        rewritten = cache()
        assert rewritten['sealed'] not in (tampered, saved['sealed']) and rewritten['iv'] != saved['iv'], 'rewritten under a new key and nonce'
        restart()
        assert D.call('init_multi', d_init)['unlock'] == 'cache'
        checks['unlock_cache_tampered_record_falls_back_to_kdf_and_is_rebuilt'] = True
        assert receipt['timings_seconds']['unlock_cache_hit_start'] < receipt['timings_seconds']['unlock_cache_miss_start_kdf'], receipt['timings_seconds']

        # validly sealed record with the wrong keys → the store refuses them → the worker drops the cache and runs the KDF
        restart(enable=False)
        D.page.evaluate(JS_CACHE_FORGE, [d_cache, DAD, d_identity, d_pass])
        forged = cache()['sealed']
        restart()
        d_retry = timed('unlock_cache_wrong_keys_retry_start', lambda: D.call('init_multi', d_init))
        assert d_retry['unlock'] == 'kdf' and d_retry['fresh'] is False and d_retry['public_key'] == d_pk, d_retry
        r1_retry = D.call('open_room', {'room': 'r1', 'database': d_r1, 'from': 'identity'})
        assert r1_retry['fresh'] is False and D.members('r1') == [DAD], r1_retry
        assert cache()['sealed'] != forged
        restart()
        assert D.call('init_multi', d_init)['unlock'] == 'cache'
        checks['unlock_cache_wrong_keys_are_dropped_and_the_store_still_opens'] = True

        # a start without the message: KDF, and the cache database is gone
        restart(enable=False)
        d_off = D.call('init_multi', d_init)
        assert d_off['unlock'] == 'kdf' and d_off['public_key'] == d_pk, d_off
        assert D.page.evaluate(JS_DB_EXISTS, d_cache) is False
        assert D.page.evaluate(JS_DB_EXISTS, d_identity) is True
        checks['unlock_cache_deleted_when_not_enabled'] = True

        # migration with the cache: the adopted legacy capsule is what the next start opens
        E = Worker(browser.new_context(), 'E', SIS, receipt, host)
        workers.append(E)
        e_legacy, e_identity, e_pass = f'{prefix}-e-legacy', f'{prefix}-e-identity', secrets.token_urlsafe(36)
        assert E.call('init', {'identity': SIS, 'database': e_legacy, 'room': 'fam', 'passphrase': e_pass})['fresh'] is True
        E.op(None, 'create')
        e_pk = E.status()['public_key']
        e_init = {'identity': SIS, 'passphrase': e_pass, 'identity_database': e_identity, 'legacy': {'database': e_legacy, 'room': 'fam'}}
        E.stop()
        E.spawn()
        E.call('unlock_cache', {'enabled': True})
        e_migrated = E.call('init_multi', e_init)
        assert e_migrated['migrated'] is True and e_migrated['unlock'] == 'fresh' and e_migrated['public_key'] == e_pk, e_migrated
        E.stop()
        E.spawn()
        E.call('unlock_cache', {'enabled': True})
        e_again = E.call('init_multi', e_init)
        assert e_again['unlock'] == 'cache' and e_again['migrated'] is False and e_again['fresh'] is False and e_again['public_key'] == e_pk, e_again
        e_fam = E.call('open_room', {'room': 'fam', 'database': e_legacy, 'from': 'identity'})
        assert e_fam['fresh'] is False and E.members('fam') == [SIS], e_fam
        checks['unlock_cache_after_legacy_migration_opens_identity_and_legacy_room'] = True
    except BaseException:
        for w in workers:
            print(f'--- {w.label} ({w.name}) console:\n' + '\n'.join(w.console[-60:]), file=sys.stderr)
        raise
    finally:
        receipt['console'] = {w.label: w.console[-60:] for w in workers}
        receipt['checks_passed_count'] = len(checks)


# ------------------------------------------------------------------ main ----

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--bundle', required=True, type=Path, help='pkg dir with family_mls_browser_experiment*.{js,wasm} + custody.js')
    args = parser.parse_args()
    os.umask(0o077)
    (ARCHIVE / 'artifacts').mkdir(mode=0o700, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='native-multistore-', dir=ARCHIVE / 'artifacts'))

    files = {'/': WEB / 'index.html'}
    for name in ['main.js', 'worker.js', 'durable-worker.js', 'session-store.js', 'history-store.js', 'enroll.js']:
        files['/' + name] = WEB / name
    for name in ['family_mls_browser_experiment.js', 'family_mls_browser_experiment_bg.wasm', 'custody.js']:
        files['/pkg/' + name] = args.bundle / name
    assets = {}
    for route, file in files.items():
        st = file.lstat()
        if not file.is_file() or file.is_symlink() or st.st_nlink != 1 or st.st_size > 32 * 1024 * 1024:
            raise RuntimeError(f'unsafe or oversized asset: {file}')
        assets[route] = file.read_bytes()
    original_hashes = {route: hashlib.sha256(raw).hexdigest() for route, raw in assets.items()}
    # Served-bytes-only instrumentation (as the persistence smoke does): main.js gives
    # only `init` the 3-minute custody (scrypt) deadline. init_multi / open_room also
    # unlock custody, so they get the same deadline here. Tracked source unchanged.
    old, new = b"method === 'init' ? 180000 : 10000", b"['init', 'init_multi', 'open_room'].includes(method) ? 180000 : 10000"
    assert assets['/main.js'].count(old) == 1, 'main.js deadline expression changed; update the served patch'
    assets['/main.js'] = assets['/main.js'].replace(old, new)

    receipt = {'synthetic_only': True, 'lane': 'durable worker multi-store protocol (#431 stage 4)',
               'checks': {}, 'timings_seconds': {}, 'max_worker_linear_memory_bytes': 0, 'passed': False,
               'original_assets_sha256': original_hashes,
               'test_instrumentation': 'served main.js: init_multi/open_room share the init call deadline; source unchanged',
               'assets_sha256': {route: hashlib.sha256(raw).hexdigest() for route, raw in assets.items()},
               'protocol': {
                   'envelope': '{id, method, argument} → {id, ok, result} | {id, ok:false, error}',
                   'init_multi': "{identity, passphrase, identity_database, legacy?: {database, room}} → {fresh, migrated, public_key[32], revision, cursor, unlock: 'cache'|'kdf'|'fresh'}",
                   'unlock_cache': '{enabled} before init_multi → {enabled} (#766 C1: later identity-store starts skip the KDF)',
                   'open_room': "{room, database, from: 'identity'|'lobby'} → {fresh, revision, cursor, public_key, history}",
                   'close_room': '{room} → {}', 'reset_room': '{room, database} → {} (unused here)',
                   'room_scoped': {m: '+ room' for m in ROOM_SCOPED_METHODS},
                   'operation': '{room, id, method, bytes, sequence, fault} → {output, cursor, revision, replay, transient?, rejected?, sender? (decrypt)}',
                   'ack': '{room, ids} after every non-transient operation (ledger cap 256)',
                   'identity_room': '-identity (fingerprint/policy_fingerprint/sign_approval)', 'lobby_room': '-lobby (key_package/delete_key_package)',
               }}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.headers.get('Host') != host or self.headers.get('Origin') not in (None, 'http://' + host):
                self.send_error(403)
                return
            if self.path not in assets:
                self.send_error(404)
                return
            raw = assets[self.path]
            self.send_response(200)
            self.send_header('Content-Type', 'application/wasm' if self.path.endswith('.wasm') else
                             'text/javascript' if self.path.endswith('.js') else 'text/html')
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(raw)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    host = f'127.0.0.1:{server.server_port}'   # 127.0.0.1 is a secure context: crypto.subtle, IndexedDB, module workers
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    status = 0
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch()
            receipt['browser'] = browser.version
            try:
                run_flow(browser, host, receipt)
                receipt['passed'] = True
            except Exception:   # noqa: BLE001 — every failure is reported with the page consoles
                receipt['error'] = traceback.format_exc()
                print(receipt['error'], file=sys.stderr)
                status = 1
            finally:
                browser.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        (evidence / 'verification.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(receipt['checks'], ensure_ascii=False))
        print(evidence / 'verification.json', flush=True)
    sys.exit(status)


if __name__ == '__main__':
    main()
