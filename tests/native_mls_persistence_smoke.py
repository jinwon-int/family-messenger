#!/usr/bin/env python3
"""Synthetic IndexedDB proof: never accepts a live server or human device."""
import argparse
import hashlib
import json
import os
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
    repo = Path(__file__).resolve().parents[1]
    evidence = Path(tempfile.mkdtemp(prefix='native-mls-persistence-', dir=repo / 'artifacts'))
    assets = {}
    files = {'/': repo / 'experiments/openmls-browser/web/index.html'}
    for name in ['main.js', 'worker.js', 'durable-worker.js']:
        files['/' + name] = repo / 'experiments/openmls-browser/web' / name
    for name in ['family_mls_browser_experiment.js', 'family_mls_browser_experiment_bg.wasm']:
        files['/pkg/' + name] = args.bundle / name
    for path, file in files.items():
        st = file.lstat()
        assert file.is_file() and not file.is_symlink() and st.st_nlink == 1 and st.st_size <= 32 * 1024 * 1024
        assets[path] = file.read_bytes()
    proof = {'synthetic_only': True, 'keys_at_rest': 'unencrypted synthetic IndexedDB only',
             'checks': {}, 'max_worker_linear_memory_bytes': 0,
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

            def init(p, actor, db=None, reject=False):
                return rpc(p, 'init', {'identity': actor, 'database': db or databases[actor]}, reject)

            def arg(id, method, data=None, sequence=0, fault=''):
                return {'id': id, 'method': method, 'bytes': data or [], 'sequence': sequence, 'fault': fault}

            def op(p, id, method, data=None, sequence=0, fault='', reject=False):
                return rpc(p, 'operation', arg(id, method, data, sequence, fault), reject)

            def state_digest(p, db):
                # Return only a digest and shape; never print/store synthetic private keys.
                return p.evaluate('''async name => {
                  const db = await new Promise((r,j) => { const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j; });
                  const record = await new Promise((r,j) => { const t=db.transaction('device');const q=t.objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j; });
                  db.close();
                  const digest = await crypto.subtle.digest('SHA-256', record.crypto);
                  return {hash:Array.from(new Uint8Array(digest)),revision:record.revision,cursor:record.cursor};
                }''', db)

            alice, bob = page(contexts[0]), page(contexts[1])
            assert init(alice, 'alice')['revision'] == 1
            init(bob, 'bob')
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
            cipher = op(alice, 'send1', 'encrypt', text)['output']
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

            # Receiver restart preserves replay state, cursor, and future decryption.
            crash_restart(1, bob)
            bob = page(contexts[1]); init(bob, 'bob')
            assert rpc(bob, 'status')['cursor'] == 3
            op(bob, 'replayed-after-restart', 'decrypt', outcomes[0]['result']['output'], sequence=4, reject=True)
            future = op(alice, 'future', 'encrypt', list(b'after restart'))['output']
            assert op(bob, 'receive4', 'decrypt', future, sequence=4)['output'] == list(b'after restart')
            proof['checks']['receiver_browser_crash_and_future_message'] = True

            wrong = page(contexts[0]); init(wrong, 'bob', databases['alice'], reject=True)
            rpc(wrong, 'status', reject=True)
            proof['checks']['wrong_actor_cannot_reopen_state'] = True
            forged_db = prefix + '-forged'
            alice.evaluate("""async ([source, target]) => {
              const read = await new Promise((r,j)=>{const q=indexedDB.open(source);q.onsuccess=()=>r(q.result);q.onerror=j;});
              const record = await new Promise((r,j)=>{const q=read.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j;});
              read.close(); record.identity='bob';
              const snapshot=JSON.parse(new TextDecoder().decode(record.crypto)); snapshot.identity='bob';
              record.crypto=new TextEncoder().encode(JSON.stringify(snapshot));
              const hex=b=>Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');
              const canonical=JSON.stringify(['family-mls-state-v1',record.version,record.identity,record.revision,record.cursor,record.epoch,hex(record.crypto),record.ledger.map(x=>[x.id,x.method,x.sequence,x.epoch,hex(x.input),hex(x.output)])]);
              record.checksum=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(canonical)));
              await new Promise((r,j)=>{const q=indexedDB.open(target,1);q.onupgradeneeded=()=>q.result.createObjectStore('device').add(record,'state');q.onsuccess=()=>{q.result.close();r();};q.onerror=j;});
            }""", [databases['alice'], forged_db])
            forged = page(contexts[0]); init(forged, 'bob', forged_db, reject=True)
            proof['checks']['snapshot_actor_must_match_group_credential'] = True
            # Clone only synthetic records, corrupt one field, retain and deny it.
            for corruption in ['output', 'input', 'crypto', 'id', 'checksum']:
                target = prefix + '-corrupt-' + corruption
                before = alice.evaluate("""async ([source,target,kind]) => {
                  const read=await new Promise((r,j)=>{const q=indexedDB.open(source);q.onsuccess=()=>r(q.result);q.onerror=j;});
                  const record=await new Promise((r,j)=>{const q=read.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j;});read.close();
                  const item=record.ledger.find(x=>x.id==='send1');
                  if(kind==='input'||kind==='output') item[kind][0]^=1;
                  else if(kind==='id') item.id='changed-id';
                  else record[kind][0]^=1;
                  await new Promise((r,j)=>{const q=indexedDB.open(target,1);q.onupgradeneeded=()=>q.result.createObjectStore('device').add(record,'state');q.onsuccess=()=>{q.result.close();r();};q.onerror=j;});
                  return JSON.stringify(record);
                }""", [databases['alice'],target,corruption])
                corrupt=page(contexts[0]);init(corrupt,'alice',target,reject=True)
                op(corrupt,'send1','encrypt',text,reject=True)
                after=corrupt.evaluate("""async name=>{
                  const db=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j;});
                  const value=await new Promise((r,j)=>{const q=db.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j;});db.close();return JSON.stringify(value);
                }""",target)
                assert before==after
                corrupt.close()
            proof['checks']['corrupt_cached_result_input_state_metadata_checksum_retained_denied'] = True
            before = rpc(alice, 'status')
            commit = op(alice, 'remove', 'remove')['output']
            op(alice, 'future', 'encrypt', list(b'after restart'), reject=True)
            assert rpc(alice, 'status')['operations'] == before['operations'] + ['remove']
            op(bob, 'remove', 'commit', commit)
            op(bob, 'after-remove', 'encrypt', text, reject=True)
            proof['checks']['stale_epoch_outbox_retained_but_not_released'] = True

            empty = page(contexts[0]); empty_db = prefix + '-empty'
            empty.evaluate('''name => new Promise((r,j) => {
              const q=indexedDB.open(name,1);q.onupgradeneeded=()=>q.result.createObjectStore('device');q.onsuccess=()=>{q.result.close();r();};q.onerror=j;
            })''', empty_db)
            init(empty, 'alice', empty_db, reject=True)
            proof['checks']['missing_state_does_not_regenerate_keys'] = True

            quota = page(contexts[0]); quota_db = prefix + '-quota'; init(quota, 'alice', quota_db)
            for n in range(32):
                op(quota, f'key{n}', 'key_package')
            before = state_digest(quota, quota_db)
            op(quota, 'overflow', 'key_package', reject=True)
            assert state_digest(quota, quota_db) == before
            proof['checks']['capacity_preserves_committed_state'] = True
            quota.evaluate('''name => new Promise((r,j) => {
              const q=indexedDB.open(name);q.onsuccess=()=>{const db=q.result;const t=db.transaction('device','readwrite');t.objectStore('device').put({unknown:true},'unexpected');t.oncomplete=()=>{db.close();r();};t.onabort=j;};q.onerror=j;
            })''', quota_db)
            rpc(quota, 'status', reject=True)
            quota.close(); quota = page(contexts[0]); init(quota, 'alice', quota_db, reject=True)
            assert state_digest(quota, quota_db) == before
            proof['checks']['unknown_record_preserved_and_reopen_denied'] = True
            for context in contexts:
                context.close()
        proof['passed'] = True
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5)
        (evidence / 'verification.json').write_text(json.dumps(proof, indent=2) + '\n')
        print(evidence / 'verification.json', flush=True)


if __name__ == '__main__':
    main()
