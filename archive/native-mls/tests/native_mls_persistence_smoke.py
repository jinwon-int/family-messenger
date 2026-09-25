#!/usr/bin/env python3
"""Synthetic IndexedDB proof: never accepts a live server or human device."""
import argparse
import hashlib
import json
import os
import secrets
import signal
from pathlib import Path
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from playwright.sync_api import sync_playwright, Error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    repo = Path(__file__).resolve().parents[2]  # archive/
    (repo / 'artifacts').mkdir(mode=0o700, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='native-mls-persistence-', dir=repo / 'artifacts'))
    assets = {}
    files = {'/': repo / 'experiments/openmls-browser/web/index.html'}
    for name in ['main.js', 'worker.js', 'durable-worker.js', 'session-store.js']:
        files['/' + name] = repo / 'experiments/openmls-browser/web' / name
    for name in ['family_mls_browser_experiment.js', 'family_mls_browser_experiment_bg.wasm']:
        files['/pkg/' + name] = args.bundle / name
    for path, file in files.items():
        st = file.lstat()
        assert file.is_file() and not file.is_symlink() and st.st_nlink == 1 and st.st_size <= 32 * 1024 * 1024
        assets[path] = file.read_bytes()
    original_hashes = {name: hashlib.sha256(raw).hexdigest() for name, raw in assets.items()}
    # Instrument only bytes served by this private test. Tracked runtime has no
    # spin/kill command. Hold the callback after put so IDB cannot commit yet.
    patches = {
        '/session-store.js': [
            (b"'abort-after-write', 'lost-response'", b"'abort-after-write', 'lost-response', 'crash-before-complete'"),
            (b"if (fault === 'abort-after-write') { abort(); return undefined; }", b"if (fault === 'crash-before-complete') { self.postMessage({test_crash_boundary:true}); while(true) {} }\n          if (fault === 'abort-after-write') { abort(); return undefined; }")],
        '/main.js': [(b'    if (data.id !== id) return;', b'    if (data.test_crash_boundary) window.test_crash_boundary=true;\n    if (data.id !== id) return;')],
    }
    for name, replacements in patches.items():
        for old, new in replacements:
            assert assets[name].count(old) == 1, 'test instrumentation boundary changed'
            assets[name] = assets[name].replace(old, new)
    proof = {'synthetic_only': True, 'keys_at_rest': 'unencrypted synthetic IndexedDB only; entries and meta HMAC-authenticated (storage v2)',
             'storage': 'v2: resident Session, one IDB record per changed store entry + authenticated meta (#177 M2b-1)',
             'checks': {}, 'max_worker_linear_memory_bytes': 0,
             'original_assets_sha256': original_hashes,
             'test_instrumentation': 'served worker callback hold after put; served page marker; source unchanged',
             'assets_sha256': {name: hashlib.sha256(raw).hexdigest() for name, raw in assets.items()}}

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
            self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(raw)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    host = f'127.0.0.1:{server.server_port}'
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        with sync_playwright() as pw:
            profiles = [evidence / 'alice-profile', evidence / 'bob-profile']
            for profile in profiles:
                profile.mkdir(mode=0o700)
            contexts = [pw.chromium.launch_persistent_context(str(profile)) for profile in profiles]
            proof['browser'] = contexts[0].browser.version

            def crash_restart(index, old_page):
                session = contexts[index].browser.new_browser_cdp_session()
                processes = session.send('SystemInfo.getProcessInfo')['processInfo']
                pid = next(int(item['id']) for item in processes if item['type'] == 'browser')
                command = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                # Only the browser we created with this private synthetic profile.
                expected = ('--user-data-dir=' + str(profiles[index])).encode()
                assert expected in command
                os.kill(pid, signal.SIGKILL)
                try:
                    contexts[index].close()
                except Error:
                    pass
                contexts[index] = pw.chromium.launch_persistent_context(str(profiles[index]))
            prefix = 'family-mls-synthetic-' + uuid.uuid4().hex
            databases = {'alice': prefix + '-alice', 'bob': prefix + '-bob'}
            # Stand-in for the custody-unlock-derived record key (M2b-3). Never logged.
            record_keys = {actor: list(secrets.token_bytes(32)) for actor in databases}

            def page(context):
                result = context.new_page()
                result.goto('http://' + host)
                result.wait_for_function('window.ready === true')
                result.evaluate("spawn('device', true)")
                return result

            def rpc(p, method, argument=None, reject=False):
                value = p.evaluate('([method, argument]) => call("device", method, argument)', [method, argument])
                proof['max_worker_linear_memory_bytes'] = max(proof['max_worker_linear_memory_bytes'], value['memory_bytes'])
                assert value['memory_bytes'] <= 128 * 1024 * 1024
                if reject:
                    assert value['ok'] is False and 'result' not in value, (method, value)
                    return
                assert value['ok'] is True, (method, value)
                return value['result']

            def init(p, actor, db=None, reject=False, key=None):
                return rpc(p, 'init', {'identity': actor, 'database': db or databases[actor], 'room': 'main',
                                       'record_key': key or record_keys[actor]}, reject)

            def arg(id, method, data=None, sequence=0, fault=''):
                return {'id': id, 'method': method, 'bytes': data or [], 'sequence': sequence, 'fault': fault}

            def op(p, id, method, data=None, sequence=0, fault='', reject=False):
                return rpc(p, 'operation', arg(id, method, data, sequence, fault), reject)

            # Whole durable state: meta record + every entry, canonically encoded.
            DUMP = '''async name => {
              const db = await new Promise((r,j) => { const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j; });
              const names = Array.from(db.objectStoreNames).sort();
              const read = (store, kind) => new Promise((r,j) => { const q=db.transaction(store).objectStore(store)[kind]();q.onsuccess=()=>r(q.result);q.onerror=j; });
              const hex = b => Array.from(b instanceof ArrayBuffer ? new Uint8Array(b) : b, x => x.toString(16).padStart(2,'0')).join('');
              const enc = v => v instanceof Uint8Array || v instanceof ArrayBuffer ? 'x' + hex(v) : Array.isArray(v) ? v.map(enc) :
                v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map(k => [k, enc(v[k])])) : v;
              const out = {names};
              for (const store of names) out[store] = {keys: enc(await read(store, 'getAllKeys')), values: enc(await read(store, 'getAll'))};
              db.close();
              return JSON.stringify(out);
            }'''

            def state_digest(p, db):
                # Return only a digest and counters; never print/store synthetic private keys.
                dump = json.loads(p.evaluate(DUMP, db))
                meta = dump['meta']['values'][dump['meta']['keys'].index('state')]
                return {'hash': hashlib.sha256(json.dumps(dump, sort_keys=True).encode()).hexdigest(),
                        'revision': meta.get('revision'), 'cursor': meta.get('cursor')}

            alice, bob = page(contexts[0]), page(contexts[1])
            assert init(alice, 'alice')['revision'] == 1
            init(bob, 'bob')
            before = state_digest(bob, databases['bob'])
            wrong_key = page(contexts[1]); init(wrong_key, 'bob', key=list(secrets.token_bytes(32)), reject=True)
            assert state_digest(bob, databases['bob']) == before
            wrong_key.close()
            proof['checks']['wrong_record_key_denied_without_mutation'] = True
            before = state_digest(bob, databases['bob'])
            invalid_id = arg('array-id', 'key_package'); invalid_id['id'] = ['array-id']
            rpc(bob, 'operation', invalid_id, reject=True)
            assert state_digest(bob, databases['bob']) == before
            proof['checks']['nonstring_id_rejected_without_mutation'] = True
            package = op(bob, 'kp', 'key_package')['output']
            op(alice, 'create', 'create')
            welcome = op(alice, 'invite', 'invite', package)['output']
            before = state_digest(bob, databases['bob'])
            damaged = welcome.copy(); damaged[-1] ^= 1
            op(bob, 'join', 'join', damaged, reject=True)
            assert state_digest(bob, databases['bob']) == before
            op(bob, 'join', 'join', welcome)
            proof['checks']['damaged_welcome_discards_complete_provider'] = True

            text = list('synthetic durable hello 한글'.encode())
            before = state_digest(alice, databases['alice'])
            op(alice, 'send1', 'encrypt', text, fault='abort-before-write', reject=True)
            assert state_digest(alice, databases['alice']) == before
            sent = op(alice, 'send1', 'encrypt', text)
            cipher = sent['output']
            proof['per_operation'] = {'encrypt_changed_entries': sent['changed'], 'encrypt_bytes_written': sent['bytes_written'],
                                      'encrypt_meta_bytes': sent['meta_bytes'],
                                      'store_entries': rpc(alice, 'status')['entries']}
            before = state_digest(bob, databases['bob'])
            damaged = cipher.copy(); damaged[-1] ^= 1
            op(bob, 'receive1', 'decrypt', damaged, sequence=1, reject=True)
            assert state_digest(bob, databases['bob']) == before
            op(bob, 'receive1', 'decrypt', cipher, sequence=1, fault='abort-after-write', reject=True)
            assert state_digest(bob, databases['bob']) == before
            received = op(bob, 'receive1', 'decrypt', cipher, sequence=1)
            assert received['output'] == text and received['cursor'] == 1
            again = op(bob, 'receive1', 'decrypt', cipher, sequence=1)
            assert again['replay'] and again['revision'] == received['revision']
            op(bob, 'new-id-replay', 'decrypt', cipher, sequence=2, reject=True)
            proof['checks']['tamper_abort_and_original_exactly_once'] = True

            # Read/write IDB transactions across connections provide the serialization.
            observer = page(contexts[0]); init(observer, 'alice')
            lost = arg('lost', 'encrypt', list(b'lost response'), fault='lost-response')
            alice.evaluate('a => { window.unfinished=call("device","operation",a).catch(()=>null); }', lost)
            for _ in range(100):
                if 'lost' in rpc(observer, 'status')['operations']:
                    break
            else:
                raise AssertionError('lost response was not committed')
            crash_restart(0, alice)  # Actual browser-process crash after an unacknowledged commit.
            alice = page(contexts[0]); init(alice, 'alice')
            observer = page(contexts[0]); init(observer, 'alice')
            recovered = op(alice, 'lost', 'encrypt', list(b'lost response'))
            assert recovered['replay']
            assert op(bob, 'receive2', 'decrypt', recovered['output'], sequence=2)['output'] == list(b'lost response')
            op(alice, 'lost', 'encrypt', list(b'changed request'), reject=True)
            proof['checks']['lost_reply_browser_crash_exact_ciphertext_retry'] = True

            concurrent = arg('concurrent', 'encrypt', list(b'two tabs'))
            for p in [alice, observer]:
                p.evaluate('a => { window.racing=call("device","operation",a); }', concurrent)
            outcomes = [p.evaluate('window.racing') for p in [alice, observer]]
            assert all(x['ok'] for x in outcomes)
            assert sorted(x['result']['replay'] for x in outcomes) == [False, True]
            assert outcomes[0]['result']['output'] == outcomes[1]['result']['output']
            assert op(bob, 'receive3', 'decrypt', outcomes[0]['result']['output'], sequence=3)['output'] == list(b'two tabs')
            proof['checks']['concurrent_tabs_single_encryption'] = True
            # Each tab keeps a resident session: a tab must continue from the other
            # tab's committed state (reload on a newer revision), never from its own
            # stale copy — that would reuse a sending generation.
            reloads = rpc(alice, 'status')['reloads']
            first = op(alice, 'tab-one', 'encrypt', list(b'from tab one'))['output']
            assert rpc(alice, 'status')['reloads'] == reloads, 'same-tab operations must not rebuild the session'
            second = op(observer, 'tab-two', 'encrypt', list(b'from tab two'))['output']
            third = op(alice, 'tab-one-again', 'encrypt', list(b'tab one again'))['output']
            assert rpc(alice, 'status')['reloads'] == reloads + 1, 'exactly one rebuild after the other tab wrote'
            assert op(bob, 'receive-tab1', 'decrypt', first, sequence=4)['output'] == list(b'from tab one')
            assert op(bob, 'receive-tab2', 'decrypt', second, sequence=5)['output'] == list(b'from tab two')
            assert op(bob, 'receive-tab1b', 'decrypt', third, sequence=6)['output'] == list(b'tab one again')
            proof['checks']['stale_tab_session_reloads_once_before_new_operation'] = True

            # Receiver restart preserves replay state, cursor, and future decryption.
            crash_restart(1, bob)
            bob = page(contexts[1]); init(bob, 'bob')
            assert rpc(bob, 'status')['cursor'] == 6
            op(bob, 'replayed-after-restart', 'decrypt', outcomes[0]['result']['output'], sequence=7, reject=True)
            future = op(alice, 'future', 'encrypt', list(b'after restart'))['output']
            assert op(bob, 'receive4', 'decrypt', future, sequence=7)['output'] == list(b'after restart')
            proof['checks']['receiver_browser_crash_and_future_message'] = True

            # Kill after the write is issued, while the callback blocks commit.
            before_crash = state_digest(alice, databases['alice'])
            pending = arg('inflight', 'encrypt', list(b'in flight crash'), fault='crash-before-complete')
            alice.evaluate('a=>{window.unfinished=call("device","operation",a).catch(()=>null)}', pending)
            alice.wait_for_function('() => window.test_crash_boundary === true', timeout=5000)
            crash_restart(0, alice)
            alice = page(contexts[0]); init(alice, 'alice')
            assert state_digest(alice, databases['alice']) == before_crash
            retry = op(alice, 'inflight', 'encrypt', list(b'in flight crash'))
            assert retry['replay'] is False
            assert op(bob, 'receive5', 'decrypt', retry['output'], sequence=8)['output'] == list(b'in flight crash')
            proof['checks']['inflight_transaction_browser_crash_preserves_complete_committed_state'] = True

            wrong = page(contexts[0]); init(wrong, 'bob', databases['alice'], reject=True)
            rpc(wrong, 'status', reject=True)
            proof['checks']['wrong_actor_cannot_reopen_state'] = True
            # Clone a database, optionally mutating it (runs in the page; no key material leaves it).
            CLONE = '''async ([source, target, kind, key]) => {
              const src = await new Promise((r,j)=>{const q=indexedDB.open(source);q.onsuccess=()=>r(q.result);q.onerror=j;});
              const read = (store, what) => new Promise((r,j)=>{const q=src.transaction(store).objectStore(store)[what]();q.onsuccess=()=>r(q.result);q.onerror=j;});
              const metaKeys = await read('meta','getAllKeys'), metas = await read('meta','getAll');
              const entryKeys = await read('entries','getAllKeys'), entries = await read('entries','getAll');
              src.close();
              const meta = metas[metaKeys.indexOf('state')];
              const hex = b => Array.from(b, x => x.toString(16).padStart(2,'0')).join('');
              const reseal = async () => {  // what an attacker holding the record key could do (src/record.rs construction)
                const body = new TextEncoder().encode(JSON.stringify(['family-mls-meta-v3/durable', meta.version, meta.identity, meta.room,
                  hex(meta.public_key), hex(meta.group_id), meta.format, meta.revision, meta.cursor, meta.epoch, hex(meta.set),
                  meta.count, meta.ledger.map(x => [x.id, x.method, x.sequence, x.epoch, hex(x.input), hex(x.output)]), meta.acked, null]));  // null: durable worker has no extra meta
                const domain = new TextEncoder().encode('family-mls-v2/meta\\u0000');
                const message = new Uint8Array(domain.length + 4 + body.length);
                message.set(domain); new DataView(message.buffer).setUint32(domain.length, body.length, true); message.set(body, domain.length + 4);
                const k = await crypto.subtle.importKey('raw', new Uint8Array(key), {name:'HMAC', hash:'SHA-256'}, false, ['sign']);
                meta.tag = new Uint8Array(await crypto.subtle.sign('HMAC', k, message));
              };
              const item = meta.ledger.find(x => x.id === 'send1');
              if (kind === 'actor') { meta.identity = 'bob'; await reseal(); }
              else if (kind === 'reseal') await reseal();
              else if (kind === 'input' || kind === 'output') item[kind][0] ^= 1;
              else if (kind === 'id') item.id = 'changed-id';
              else if (kind === 'tag') meta.tag[0] ^= 1;
              else if (kind === 'entry') entries[0].v[0] ^= 1;
              else if (kind === 'rollback-value' || kind === 'rollback-entry') {
                // One entry back to its value (and tag) from before the last encrypt.
                const old = new Map(window.entrySnapshot.keys.map((k, i) => [hex(new Uint8Array(k[1])), window.entrySnapshot.values[i]]));
                const i = entryKeys.findIndex((k, n) => { const o = old.get(hex(new Uint8Array(k[1]))); return o && hex(o.v) !== hex(entries[n].v); });
                if (i < 0) throw new Error('no changed entry to roll back');
                const o = old.get(hex(new Uint8Array(entryKeys[i][1])));
                entries[i] = kind === 'rollback-value' ? {v: o.v, t: entries[i].t} : o;
              }
              let skip = kind === 'missing' ? 0 : -1;
              await new Promise((r,j)=>{const q=indexedDB.open(target,2);q.onupgradeneeded=()=>{
                const m=q.result.createObjectStore('meta'); metaKeys.forEach((k,i)=>m.add(k==='state'?meta:metas[i],k));
                const e=q.result.createObjectStore('entries'); entryKeys.forEach((k,i)=>{ if(i!==skip) e.add(entries[i],k); });
              };q.onsuccess=()=>{q.result.close();r();};q.onerror=j;});
            }'''
            # Positive control: the WebCrypto reseal reproduces src/record.rs exactly, so the
            # forged-actor rejection below is the credential check, not a tag mismatch.
            resealed_db = prefix + '-resealed'
            alice.evaluate(CLONE, [databases['alice'], resealed_db, 'reseal', record_keys['alice']])
            resealed = page(contexts[0]); init(resealed, 'alice', resealed_db)
            assert rpc(resealed, 'status')['operations'] == rpc(alice, 'status')['operations']
            resealed.close()
            forged_db = prefix + '-forged'
            alice.evaluate(CLONE, [databases['alice'], forged_db, 'actor', record_keys['alice']])
            forged = page(contexts[0]); init(forged, 'bob', forged_db, reject=True, key=record_keys['alice'])
            proof['checks']['snapshot_actor_must_match_group_credential'] = True
            # Snapshot the entries, encrypt once, then roll one changed entry back:
            # value only (entry tag must fail) or value+tag (set digest must fail).
            alice.evaluate('''async name => {
              const db = await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j;});
              const read = what => new Promise((r,j)=>{const q=db.transaction('entries').objectStore('entries')[what]();q.onsuccess=()=>r(q.result);q.onerror=j;});
              window.entrySnapshot = {keys: await read('getAllKeys'), values: await read('getAll')}; db.close();
            }''', databases['alice'])
            op(alice, 'rollback-probe', 'encrypt', list(b'rollback probe'))
            # Clone only synthetic records, corrupt one field (or drop / roll back one entry), retain and deny it.
            for corruption in ['output', 'input', 'id', 'entry', 'tag', 'missing', 'rollback-value', 'rollback-entry']:
                target = prefix + '-corrupt-' + corruption
                alice.evaluate(CLONE, [databases['alice'], target, corruption, record_keys['alice']])
                before = alice.evaluate(DUMP, target)
                corrupt=page(contexts[0]);init(corrupt,'alice',target,reject=True)
                op(corrupt,'send1','encrypt',text,reject=True)
                assert before == corrupt.evaluate(DUMP, target)
                corrupt.close()
            proof['checks']['corrupt_ledger_entry_tag_missing_or_rolled_back_entry_retained_denied'] = True
            before = rpc(alice, 'status')
            commit = op(alice, 'remove', 'remove', rpc(bob, 'status')['public_key'])['output']
            op(alice, 'future', 'encrypt', list(b'after restart'), reject=True)
            assert rpc(alice, 'status')['operations'] == before['operations'] + ['remove']
            op(bob, 'remove', 'commit', commit)
            op(bob, 'after-remove', 'encrypt', text, reject=True)
            proof['checks']['stale_epoch_outbox_retained_but_not_released'] = True

            empty = page(contexts[0]); empty_db = prefix + '-empty'
            empty.evaluate('''name => new Promise((r,j) => {
              const q=indexedDB.open(name,2);q.onupgradeneeded=()=>{q.result.createObjectStore('meta');q.result.createObjectStore('entries');};q.onsuccess=()=>{q.result.close();r();};q.onerror=j;
            })''', empty_db)
            init(empty, 'alice', empty_db, reject=True)
            proof['checks']['missing_state_does_not_regenerate_keys'] = True

            legacy = page(contexts[0]); legacy_db = prefix + '-legacy'
            legacy.evaluate('''name => new Promise((r,j) => {
              const q=indexedDB.open(name,1);q.onupgradeneeded=()=>q.result.createObjectStore('device').add({version:1,identity:'alice'},'state');q.onsuccess=()=>{q.result.close();r();};q.onerror=j;
            })''', legacy_db)
            init(legacy, 'alice', legacy_db, reject=True)
            assert legacy.evaluate('''name => new Promise((r,j) => { const q=indexedDB.open(name);q.onsuccess=()=>{const v=[q.result.version,Array.from(q.result.objectStoreNames)];q.result.close();r(v);};q.onerror=j; })''', legacy_db) == [1, ['device']]
            proof['checks']['legacy_v1_database_retained_and_denied'] = True

            quota = page(contexts[0]); quota_db = prefix + '-quota'; init(quota, 'alice', quota_db)
            for n in range(600):
                value = quota.evaluate('([method, argument]) => call("device", method, argument)', ['operation', arg(f'key{n}', 'key_package')])
                if not value['ok']:
                    break
                before = state_digest(quota, quota_db)
            else:
                raise AssertionError('capacity never reached')
            proof['capacity_operations'] = n
            assert state_digest(quota, quota_db) == before
            op(quota, 'overflow', 'key_package', reject=True)
            assert state_digest(quota, quota_db) == before
            proof['checks']['capacity_preserves_committed_state'] = True
            quota.evaluate('''name => new Promise((r,j) => {
              const q=indexedDB.open(name);q.onsuccess=()=>{const db=q.result;const t=db.transaction('meta','readwrite');t.objectStore('meta').put({unknown:true},'unexpected');t.oncomplete=()=>{db.close();r();};t.onabort=j;};q.onerror=j;
            })''', quota_db)
            unknown = state_digest(quota, quota_db)
            rpc(quota, 'status', reject=True)
            quota.close(); quota = page(contexts[0]); init(quota, 'alice', quota_db, reject=True)
            assert state_digest(quota, quota_db) == unknown
            proof['checks']['unknown_record_preserved_and_reopen_denied'] = True

            # Outbox pruning (§3.5): acknowledged items leave the ledger; unknown ids reject.
            listed = rpc(alice, 'status')['operations']
            assert 'send1' in listed
            rpc(alice, 'ack', {'ids': ['send1', 'lost']})
            after = rpc(alice, 'status')
            assert 'send1' not in after['operations'] and 'lost' not in after['operations'] and len(after['operations']) == len(listed) - 2
            rpc(alice, 'ack', {'ids': ['send1']}, reject=True)
            op(alice, 'send1', 'encrypt', text, reject=True)  # acked id retried: tombstone, no second encryption
            proof['full_serializations_after_reopen'] = after['full_serializations']
            proof['checks']['ack_prunes_ledger_and_tombstones_ids'] = True
            for context in contexts:
                context.close()
        proof['passed'] = True
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5)
        (evidence / 'verification.json').write_text(json.dumps(proof, indent=2) + '\n')
        print(evidence / 'verification.json', flush=True)


if __name__ == '__main__':
    main()
