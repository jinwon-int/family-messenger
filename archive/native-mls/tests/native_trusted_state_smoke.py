#!/usr/bin/env python3
"""Synthetic-only CF-style header injection; never a deployable auth proxy."""
import argparse
import base64
import hashlib
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zlib

from playwright.sync_api import sync_playwright, expect, Error as BrowserError


def main():
    args = argparse.ArgumentParser()
    args.add_argument('--bundle', required=True, type=Path)
    args.add_argument('--binary', required=True, type=Path)
    args.add_argument('--policy-binary', required=True, type=Path)
    args = args.parse_args()
    binary, policy = args.binary.resolve(strict=True), args.policy_binary.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    work = Path(tempfile.mkdtemp(prefix='native-trusted-state-', dir=root / 'artifacts'))
    state, auth, proposals = [work / n for n in ('state', 'auth', 'proposals')]
    for d in (state, auth, proposals):
        d.mkdir(mode=0o700)
    proof = {'synthetic_only': True, 'production_cf_gate': False, 'e2ee': False, 'checks': {},
             'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    key = proposals / 'synthetic-private.pem'
    key.write_bytes(subprocess.check_output(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048'], stderr=subprocess.DEVNULL))
    key.chmod(0o600)
    modulus = subprocess.check_output(['openssl', 'rsa', '-in', str(key), '-noout', '-modulus'], stderr=subprocess.DEVNULL).decode().strip().split('=', 1)[1]
    b64 = lambda b: base64.urlsafe_b64encode(b).decode().rstrip('=')
    config = {'version': 1, 'issuer': 'https://synthetic.cloudflareaccess.com', 'audience': 'synthetic-app',
              'keys': [{'kid': 'test-key', 'n': b64(bytes.fromhex(modulus)), 'e': 65537}],
              'people': [{'subject': 'owner', 'actor': 'alice', 'owner': True}, {'subject': 'family', 'actor': 'bob', 'owner': False}]}
    tokens = {}
    for subject in ('owner', 'family'):
        for expired in (False, True):
            now = int(time.time())
            claims = {'iss': config['issuer'], 'aud': [config['audience']], 'sub': subject, 'type': 'app',
                      'iat': now - 60, 'nbf': now - 60, 'exp': now - 1 if expired else now + 900, 'role': 'owner'}
            raw = b64(json.dumps({'alg': 'RS256', 'typ': 'JWT', 'kid': 'test-key'}).encode()) + '.' + b64(json.dumps(claims).encode())
            tokens[subject, expired] = raw + '.' + b64(subprocess.check_output(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=raw.encode()))
    def commit(revision, people):
        candidate = proposals / f'candidate-{revision}-{secrets.token_hex(6)}.json'
        candidate.write_text(json.dumps({**config, 'people': people}))
        candidate.chmod(0o600)
        r = subprocess.run([str(policy), '--synthetic-only', '--auth-state', str(auth), '--input', str(candidate), '--expected-revision', str(revision)], capture_output=True, text=True, timeout=5)
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout)['revision'] == revision + 1
    commit(0, config['people'])
    process = output = proxy = None
    address = '127.0.0.1:0'
    def start():
        nonlocal process, output, address
        log = work / 'server.log'
        output = log.open('ab')
        offset = log.stat().st_size
        process = subprocess.Popen([str(binary), '--synthetic-only', '--state', str(state), '--auth-state', str(auth), '--listen', address], stderr=output, stdout=subprocess.DEVNULL)
        until = time.monotonic() + 10
        while time.monotonic() < until:
            assert process.poll() is None, 'server exited'
            match = re.search(r'listening (127\.0\.0\.1:\d+)', log.read_bytes()[offset:].decode())
            if match:
                address = match[1]
                return
            time.sleep(.02)
        raise AssertionError('server startup timeout')
    def stop():
        if process and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        if output:
            output.close()
    def direct(subject, method, path, body=None):
        r = urllib.request.Request('http://' + address + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                   headers={'Cf-Access-Jwt-Assertion': tokens[subject, False], 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(r, timeout=5) as response:
                data = response.read()
                return response.status, json.loads(data) if data else None
        except urllib.error.HTTPError as e:
            e.close()
            return e.code, None

    # These opaque HttpOnly cookies model an already verified upstream identity.
    # There is deliberately no login, control, token-issuing or account route.
    bindings = {secrets.token_hex(16): 'owner', secrets.token_hex(16): 'family'}
    cookies = list(bindings)
    expired = set()
    lock = threading.Lock()
    requests = []
    assets={}
    for name in ['index.html','main.js','trust-worker.js','trust-directory.js','trusted-state-worker.js']:
        file=root/'experiments/openmls-browser/web'/name
        raw=file.read_bytes()
        if name=='trust-worker.js':raw=b"const testFetch=fetch;self.fetch=(url,options)=>{options?.signal?.addEventListener('abort',()=>self.postMessage({testAbortObserved:true}),{once:true});return testFetch(url,options);};\n"+raw
        if name=='main.js':raw=raw.replace(b"durable ? './durable-worker.js' : './worker.js'",b"'./trusted-state-worker.js'")
        assets['/' if name=='index.html' else '/'+name]=raw
    assets['/untrusted-worker.js']=(root/'experiments/openmls-browser/web/worker.js').read_bytes()
    for name in ['family_mls_browser_experiment.js','family_mls_browser_experiment_bg.wasm']:
        file=args.bundle/name
        st=file.lstat();assert not file.is_symlink() and st.st_nlink==1 and st.st_size<4*1024*1024
        assets['/pkg/'+name]=file.read_bytes()
    original_hashes={name:hashlib.sha256(raw).hexdigest() for name,raw in assets.items()}
    old=b"'abort-after-write', 'lost-response'"
    assert assets['/trusted-state-worker.js'].count(old)==1
    assets['/trusted-state-worker.js']=assets['/trusted-state-worker.js'].replace(old,b"'abort-after-write', 'lost-response', 'crash-before-complete'")
    old=b"            if (fault === 'abort-after-write')"
    assert assets['/trusted-state-worker.js'].count(old)==1
    assets['/trusted-state-worker.js']=assets['/trusted-state-worker.js'].replace(old,b"            if (fault === 'crash-before-complete') {self.postMessage({test_crash_boundary:true});while(true){}}\n"+old)
    old=b"    if (data.id !== id) return;"
    assert assets['/main.js'].count(old)==1
    assets['/main.js']=assets['/main.js'].replace(old,b"    if(data.test_crash_boundary)window.test_crash_boundary=true;\n"+old)
    proof['original_assets_sha256']=original_hashes
    proof['test_instrumentation']='main selects trusted state worker; test-served pending-write hold; one directory response can be held by fixture' 
    proof['assets_sha256']={name:hashlib.sha256(raw).hexdigest() for name,raw in assets.items()}
    tamper={}
    hold_next=[False];arrived=threading.Event();release=threading.Event()
    class Proxy(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            self.forward()
        def do_POST(self):
            self.forward()
        def do_PUT(self):
            self.forward()
        def do_DELETE(self):
            self.forward()
        def forward(self):
            if self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}' or not self.path.startswith('/') or self.path.startswith('//'):
                self.send_error(400)
                return
            if any(k.lower() == 'authorization' or k.lower().startswith('cf-') for k in self.headers):
                self.send_error(400)
                return
            c = SimpleCookie()
            c.load(self.headers.get('Cookie', ''))
            cookie = c.get('synthetic_edge')
            credential = cookie.value if cookie else None
            with lock:
                subject = bindings.get(credential)
                is_expired = credential in expired
                requests.append({'path': self.path, 'actor': self.headers.get('X-Family-Actor'), 'subject': subject})
            if self.command=='GET' and self.path in assets:
                raw=assets[self.path];self.send_response(200)
                self.send_header('Content-Type','application/wasm' if self.path.endswith('.wasm') else 'text/javascript' if self.path.endswith('.js') else 'text/html')
                self.send_header('Content-Length',str(len(raw)));self.send_header('Cache-Control','no-store')
                self.send_header('Content-Security-Policy',"default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
                self.end_headers();self.wfile.write(raw);return
            size = int(self.headers.get('Content-Length', '0'))
            if size < 0 or size > 8 * 1024 * 1024:
                self.send_error(413)
                return
            body = self.rfile.read(size) if size else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in ('cookie', 'connection', 'host', 'content-length', 'transfer-encoding')}
            headers['Host'] = f'127.0.0.1:{self.server.server_port}'
            if subject:
                headers['Cf-Access-Jwt-Assertion'] = tokens[subject, is_expired]
            upstream = http.client.HTTPConnection(address, timeout=40)
            try:
                upstream.request(self.command, self.path, body=body, headers=headers)
                response = upstream.getresponse()
                if self.path.endswith('/devices') and subject=='owner' and hold_next[0]:
                    hold_next[0]=False;arrived.set();release.wait(4)
                if self.path.endswith('/devices') and response.status==200 and tamper.get(subject):
                    data=json.loads(response.read())
                    if tamper[subject]=='swap':
                        data['devices'][1]['signing_key']='01'*32
                        data['devices'][1]['fingerprint']=hashlib.sha256(bytes.fromhex('01'*32)).hexdigest()
                    raw=json.dumps(data).encode();self.send_response(200)
                    self.send_header('Content-Type','application/json');self.send_header('X-Family-Actor','bob' if tamper[subject]=='header' else 'alice' if subject=='owner' else 'bob')
                    self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw);return
                self.send_response(response.status)
                for k, v in response.getheaders():
                    if k.lower() not in ('connection', 'transfer-encoding', 'server', 'date'):
                        self.send_header(k, v)
                self.end_headers()
                while True:
                    data = response.read1(32768)
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
            except (OSError, http.client.HTTPException):
                pass
            finally:
                upstream.close()
    try:
        start()
        assert direct('owner','POST','/v1/rooms',{'id':'family','members':['bob']})[0]==201
        assert direct('owner','POST','/v1/rooms',{'id':'private','members':[]})[0]==201
        proxy=ThreadingHTTPServer(('127.0.0.1',0),Proxy)
        thread=threading.Thread(target=proxy.serve_forever,daemon=True);thread.start()
        url=f'http://127.0.0.1:{proxy.server_port}'
        with sync_playwright() as pw:
            profiles=[work/'alice-profile',work/'bob-profile']
            for p in profiles:p.mkdir(mode=0o700)
            contexts=[pw.chromium.launch_persistent_context(str(p)) for p in profiles]
            proof['browser']=contexts[0].browser.version;proof['max_worker_linear_memory_bytes']=0
            databases=['family-mls-trusted-synthetic-alice','family-mls-trusted-synthetic-bob']
            def cookie(index,value=None):
                contexts[index].add_cookies([{'name':'synthetic_edge','value':value or cookies[index],'url':url,'httpOnly':True,'sameSite':'Strict'}])
            for i in range(2):cookie(i)
            def page(index):
                p=contexts[index].new_page();p.add_init_script("window.testWorkers=[];const W=Worker;window.Worker=class extends W{constructor(...args){super(...args);window.testWorkers.push(this)}};");p.goto(url);p.wait_for_function('() => window.ready === true');p.evaluate("spawn('device')");return p
            def rpc(p,method,arg=None,reject=False):
                r=p.evaluate('([m,a])=>call("device",m,a)',[method,arg])
                proof['max_worker_linear_memory_bytes']=max(proof['max_worker_linear_memory_bytes'],r['memory_bytes'])
                assert r['memory_bytes']<=128*1024*1024
                if reject:assert r['ok'] is False and 'result' not in r;return
                assert r['ok'] is True,(method,r)
                return r.get('result')
            def init(p,index,room='family',db=None,actor=None,reject=False):
                return rpc(p,'init',{'identity':actor or ['alice','bob'][index],'room':room,'database':db or databases[index]},reject)
            def op_arg(id,method,data=None,seq=0,fault=''):
                return {'id':id,'method':method,'bytes':data or [],'sequence':seq,'fault':fault}
            def op(p,id,method,data=None,seq=0,fault='',reject=False):
                return rpc(p,'operation',op_arg(id,method,data,seq,fault),reject)
            def reopen(p,index):
                p.evaluate("stopWorker('device');spawn('device')");return init(p,index)
            def crash(index):
                session=contexts[index].browser.new_browser_cdp_session()
                pid=next(int(p['id']) for p in session.send('SystemInfo.getProcessInfo')['processInfo'] if p['type']=='browser')
                command=Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                assert ('--user-data-dir='+str(profiles[index])).encode() in command
                import signal
                os.kill(pid,signal.SIGKILL)
                try:contexts[index].close()
                except BrowserError:pass
                contexts[index]=pw.chromium.launch_persistent_context(str(profiles[index]));cookie(index)
            def digest(p,db):
                return p.evaluate("""async name=>{
                  const db=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j;});
                  const record=await new Promise((r,j)=>{const q=db.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j;});db.close();
                  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(JSON.stringify(record)))));
                }""",db)
            a,b=page(0),page(1)
            initial=[init(a,0),init(b,1)];assert all(x['pins'] is None for x in initial)
            op(a,'unconfirmed','create',reject=True);assert reopen(a,0)['public_key']==initial[0]['public_key']
            pins=[{'device_id':actor+'-first','actor':actor,'signing_key':bytes(x['public_key']).hex(),'fingerprint':hashlib.sha256(bytes(x['public_key'])).hexdigest(),'device_revision':1} for actor,x in zip(['alice','bob'],initial)]
            config['devices']=[{**p,'subject':sub,'status':'active','acceptance':'out-of-band-fingerprint'} for p,sub in zip(pins,['owner','family'])]
            commit(1,config['people'])
            def await_directory(test):
                until=time.monotonic()+5
                while time.monotonic()<until:
                    status,d=direct('owner','GET','/v1/rooms/family/devices')
                    assert status in (200,401,403)
                    if status==200 and test(d):return
                    time.sleep(.05)
                raise AssertionError('directory reload deadline')
            await_directory(lambda d:len(d['devices'])==2)
            before=digest(a,databases[0]);rpc(a,'pin',{'pins':pins,'fault':'abort-after-write'},reject=True)
            assert digest(a,databases[0])==before;assert reopen(a,0)['pins'] is None
            for p in [a,b]:assert rpc(p,'pin',{'pins':pins,'fault':''})['pins']==pins
            assert rpc(a,'pin',{'pins':pins,'fault':''})['revision']==2
            proof['checks']['explicit_pin_atomicity_and_unconfirmed_crypto_denial']=True
            package=op(b,'kp','key_package')['output'];op(a,'create','create')
            welcome=op(a,'invite','invite',package)['output']
            before=digest(b,databases[1]);bad=welcome.copy();bad[-1]^=1
            op(b,'join','join',bad,reject=True);assert digest(b,databases[1])==before
            reopen(b,1);op(b,'join','join',welcome)
            assert rpc(a,'status')['group_id']==rpc(b,'status')['group_id']
            message=list(b'synthetic durable trusted text')
            cipher=op(a,'send','encrypt',message)['output'];before=digest(b,databases[1])
            bad=cipher.copy();bad[-1]^=1;op(b,'receive','decrypt',bad,1,reject=True)
            assert digest(b,databases[1])==before;reopen(b,1)
            op(b,'receive','decrypt',cipher,1,'abort-before-write',True)
            assert digest(b,databases[1])==before;reopen(b,1)
            assert op(b,'receive','decrypt',cipher,1)['output']==message
            proof['checks']['trusted_group_tamper_and_abort_preserve_complete_state']=True
            observer=page(0);init(observer,0)
            lost=op_arg('lost','encrypt',list(b'lost trusted response'),fault='lost-response')
            a.evaluate('arg=>{window.pending=call("device","operation",arg).catch(()=>null)}',lost)
            for _ in range(50):
                if 'lost' in rpc(observer,'status')['operations']:break
            else:raise AssertionError('lost response not committed')
            before=digest(observer,databases[0]);crash(0)
            a=page(0);restored=init(a,0);assert restored['pins']==pins and restored['public_key']==initial[0]['public_key']
            recovered=op(a,'lost','encrypt',list(b'lost trusted response'));assert recovered['replay']
            assert op(a,'lost','encrypt',list(b'lost trusted response'))['output']==recovered['output']
            assert digest(a,databases[0])==before
            assert op(b,'receive2','decrypt',recovered['output'],2)['output']==list(b'lost trusted response')
            proof['checks']['browser_crash_retains_pins_keys_and_exact_ciphertext_retry']=True
            crash(1);b=page(1);restored=init(b,1)
            assert restored['pins']==pins and restored['public_key']==initial[1]['public_key'] and restored['cursor']==2
            op(b,'replayed','decrypt',recovered['output'],3,reject=True);reopen(b,1)
            proof['checks']['receiver_browser_restart_retains_trust_and_replay_state']=True
            observer=page(0);init(observer,0)
            hold_next[0]=True;arg=op_arg('network-race','encrypt',list(b'network await race'))
            a.evaluate('arg=>{window.pending=call("device","operation",arg)}',arg)
            assert arrived.wait(2)
            raced=op(observer,'network-race','encrypt',list(b'network await race'))
            release.set();late=a.evaluate('window.pending')
            assert late['ok'] and late['result']['replay'] and not raced['replay'] and late['result']['output']==raced['output'], {'late_ok':late['ok'],'late_replay':late.get('result',{}).get('replay'),'raced_replay':raced['replay']}
            assert op(b,'receive3','decrypt',raced['output'],3)['output']==list(b'network await race')
            proof['checks']['network_wait_holds_no_idb_lock_and_transaction_rechecks_latest_state']=True
            before=digest(a,databases[0]);pending=op_arg('inflight','encrypt',list(b'trusted in flight'),fault='crash-before-complete')
            a.evaluate('arg=>{window.pending=call("device","operation",arg).catch(()=>null)}',pending)
            a.wait_for_function('() => window.test_crash_boundary === true',timeout=5000)
            crash(0);a=page(0);assert init(a,0)['pins']==pins
            assert digest(a,databases[0])==before
            retry=op(a,'inflight','encrypt',list(b'trusted in flight'));assert not retry['replay']
            assert op(b,'receive4','decrypt',retry['output'],4)['output']==list(b'trusted in flight')
            proof['checks']['inflight_browser_crash_retains_atomic_trust_crypto_and_outbox']=True
            malformed=page(0);init(malformed,0);before=digest(a,databases[0])
            malformed.evaluate('window.testWorkers.at(-1).postMessage(null)');rpc(malformed,'status',reject=True)
            assert digest(a,databases[0])==before;assert reopen(malformed,0)['pins']==pins
            proof['checks']['malformed_command_retires_worker_without_mutating_durable_state']=True
            fresh=page(0);init(fresh,0,db=databases[0]+'-missing',reject=True)
            proof['checks']['registered_device_never_silently_regenerates_keys']=True
            wrong=page(0);before=digest(a,databases[0]);init(wrong,0,room='private',reject=True)
            assert digest(a,databases[0])==before
            cookie(0,cookies[1]);wrong2=page(0);init(wrong2,0,actor='bob',reject=True)
            assert digest(wrong2,databases[0])==before;cookie(0)
            proof['checks']['valid_account_cannot_rebind_stored_actor_or_room']=True
            changed=[dict(p) for p in pins];changed[1]['device_id']='changed'
            rpc(a,'pin',{'pins':changed,'fault':''},reject=True);assert digest(a,databases[0])==before;reopen(a,0)
            proof['checks']['accepted_pins_cannot_be_replaced']=True
            # Preserve a cloned corrupt synthetic record; never alter the good DB.
            corrupt_db=databases[0]+'-corrupt'
            a.evaluate("""async([source,target])=>{
              const db=await new Promise((r,j)=>{const q=indexedDB.open(source);q.onsuccess=()=>r(q.result);q.onerror=j;});
              const record=await new Promise((r,j)=>{const q=db.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j;});db.close();record.pins[1].device_id='corrupted';
              await new Promise((r,j)=>{const q=indexedDB.open(target,1);q.onupgradeneeded=()=>q.result.createObjectStore('device').add(record,'state');q.onsuccess=()=>{q.result.close();r();};q.onerror=j;});
            }""",[databases[0],corrupt_db])
            before_bad=digest(a,corrupt_db);corrupt=page(0);init(corrupt,0,db=corrupt_db,reject=True)
            assert digest(corrupt,corrupt_db)==before_bad
            proof['checks']['corrupt_trust_state_retained_and_denied']=True
            stop();start();assert rpc(a,'status')['pins']==pins
            config['devices'][1]['status']='revoked';config['devices'][1]['device_revision']=2;commit(2,config['people'])
            await_directory(lambda d:any(x['status']=='revoked' for x in d['devices']))
            before=digest(a,databases[0]);op(a,'lost','encrypt',list(b'lost trusted response'),reject=True)
            assert digest(a,databases[0])==before;reopen_a=page(0);init(reopen_a,0,reject=True)
            rpc(b,'status',reject=True);stop();start();again=page(0);init(again,0,reject=True)
            proof['checks']['revocation_blocks_cached_output_and_restart_without_state_rewrite']=True
            for c in contexts:c.close()
        proof['passed']=True
    finally:
        release.set()
        if proxy:proxy.shutdown();proxy.server_close()
        stop();(work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(work/'verification.json',flush=True)

if __name__=='__main__':
    os.umask(0o077)
    main()
