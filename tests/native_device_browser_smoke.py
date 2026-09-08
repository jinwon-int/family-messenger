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
    work = Path(tempfile.mkdtemp(prefix='native-device-browser-', dir=root / 'artifacts'))
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
    for name in ['index.html','main.js','trust-worker.js']:
        file=root/'experiments/openmls-browser/web'/name
        raw=file.read_bytes()
        if name=='main.js':raw=raw.replace(b"durable ? './durable-worker.js' : './worker.js'",b"'./trust-worker.js'")
        assets['/' if name=='index.html' else '/'+name]=raw
    assets['/untrusted-worker.js']=(root/'experiments/openmls-browser/web/worker.js').read_bytes()
    for name in ['family_mls_browser_experiment.js','family_mls_browser_experiment_bg.wasm']:
        file=args.bundle/name
        st=file.lstat();assert not file.is_symlink() and st.st_nlink==1 and st.st_size<4*1024*1024
        assets['/pkg/'+name]=file.read_bytes()
    proof['assets_sha256']={name:hashlib.sha256(raw).hexdigest() for name,raw in assets.items()}
    tamper={}
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
                if self.path.endswith('/devices') and response.status==200 and tamper.get(subject):
                    data=json.loads(response.read());data['devices'][1]['signing_key']='01'*32
                    data['devices'][1]['fingerprint']=hashlib.sha256(bytes.fromhex('01'*32)).hexdigest()
                    raw=json.dumps(data).encode();self.send_response(200)
                    self.send_header('Content-Type','application/json');self.send_header('X-Family-Actor','alice' if subject=='owner' else 'bob')
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
            browser=pw.chromium.launch();proof['browser']=browser.version
            contexts=[browser.new_context() for _ in cookies]
            pages=[]
            for ctx,cookie,actor in zip(contexts,cookies,['alice','bob']):
                ctx.add_cookies([{'name':'synthetic_edge','value':cookie,'url':url,'httpOnly':True,'sameSite':'Strict'}])
                p=ctx.new_page();p.goto(url);p.wait_for_function('() => window.ready === true');p.evaluate("spawn('device')");pages.append(p)
                assert p.evaluate('document.cookie')==''
            a,b=pages
            def rpc(p,method,arg=None,reject=False):
                r=p.evaluate('([m,a])=>call("device",m,a)',[method,arg])
                assert r['memory_bytes']<=128*1024*1024
                if reject:assert r['ok'] is False and 'result' not in r;return
                assert r['ok'] is True,(method,r)
                return r.get('result')
            for p,actor in zip(pages,['alice','bob']):rpc(p,'init',actor)
            pub=[rpc(p,'public_key') for p in pages]
            pins=[{'device_id':actor+'-first','actor':actor,'signing_key':bytes(key).hex(),'fingerprint':hashlib.sha256(bytes(key)).hexdigest(),'device_revision':1} for actor,key in zip(['alice','bob'],pub)]
            # Pins came directly from each endpoint, independently of the directory.
            # Test fixture emulates explicit fingerprint acceptance, no human UI claim.
            config['devices']=[{**pin,'subject':sub,'status':'active','acceptance':'out-of-band-fingerprint'} for pin,sub in zip(pins,['owner','family'])]
            commit(1,config['people'])
            until=time.monotonic()+5
            while time.monotonic()<until:
                if len(direct('owner','GET','/v1/rooms/family/devices')[1]['devices'])==2:break
                time.sleep(.05)
            else:raise AssertionError('device policy reload deadline')
            for p in pages:rpc(p,'pin',{'room':'family','pins':pins})
            proof['checks']['signed_room_directory_and_independent_endpoint_pins']=True
            package=rpc(b,'key_package')
            # Public material only; verification uses the same vetted-library function
            # called by invite_trusted, without initializing any page-side signer.
            def verify_package(actor,key,data):
                return a.evaluate("""async ([actor,key,data])=>{const m=await import('./pkg/family_mls_browser_experiment.js');await m.default();try{m.verify_device_package(new Uint8Array(data),actor,new Uint8Array(key));return true;}catch(_){return false;}}""",[actor,key,data])
            assert verify_package('bob',pub[1],package)
            assert not verify_package('alice',pub[1],package)
            assert not verify_package('bob',pub[0],package)
            bad=package.copy();bad[-1]^=1
            assert not verify_package('bob',pub[1],bad)
            assert not verify_package('bob',pub[1],[0]*65537)
            proof['checks']['actual_mls_package_actor_key_signature_and_bounds']=True
            rpc(a,'create');welcome=rpc(a,'invite',package);rpc(b,'join',welcome)
            cipher=rpc(a,'encrypt',list(b'synthetic trusted hello'))
            assert rpc(b,'decrypt',cipher)==list(b'synthetic trusted hello')
            proof['checks']['trusted_invite_join_and_synthetic_ciphertext']=True
            for path in ['/v1/rooms/private/devices','/v1/rooms/family/devices?actor=alice']:
                expected=403 if 'private' in path else 400
                assert b.evaluate('async path=>(await fetch(path,{headers:{"X-Family-Actor":"bob"}})).status',path)==expected
            assert b.evaluate("async()=>(await fetch('/v1/rooms/family/devices',{method:'POST'})).status")==404
            assert b.evaluate("async()=>(await fetch('/v1/rooms/family/devices',{headers:{'Cf-Access-Jwt-Assertion':'spoof'}})).status")==400
            assert b.evaluate("async()=>(await fetch('/v1/rooms/family/devices',{headers:{'X-Family-Actor':'alice'}})).status")==401
            proof['checks']['wrong_room_actor_spoof_and_http_enrollment_denied']=True
            stop();start()
            rpc(a,'check');rpc(b,'check')
            proof['checks']['native_restart_preserves_accepted_directory']=True
            # Reject substituted directory key even if its advertised hash matches.
            tamper['owner']=True
            rpc(a,'check',reject=True);tamper.clear();rpc(a,'encrypt',[1],reject=True)
            proof['checks']['directory_substitution_retires_worker_without_fallback']=True
            config['devices'][1]['status']='revoked';config['devices'][1]['device_revision']=2
            commit(2,config['people'])
            until=time.monotonic()+5
            while time.monotonic()<until:
                d=direct('owner','GET','/v1/rooms/family/devices')[1]
                if any(v['status']=='revoked' for v in d['devices']):break
                time.sleep(.05)
            else:raise AssertionError('revocation reload deadline')
            rpc(b,'check',reject=True);rpc(b,'encrypt',[1],reject=True)
            stop();start()
            assert any(v['status']=='revoked' for v in direct('owner','GET','/v1/rooms/family/devices')[1]['devices'])
            with lock:expired.add(cookies[0])
            assert a.evaluate("async()=>(await fetch('/v1/rooms/family/devices',{headers:{'X-Family-Actor':'alice'}})).status")==401
            proof['checks']['device_revocation_restart_and_account_expiry_denied']=True
            # Separate fresh synthetic auth history for an authenticated Welcome
            # whose inviter uses the right actor label with an unaccepted key.
            stop(); auth=work/'attack-auth';auth.mkdir(mode=0o700)
            with lock:expired.clear()
            for p,actor in zip(pages,['alice','bob']):
                p.evaluate("stopWorker('device');spawn('device')")
                rpc(p,'init',actor)
            pub2=[rpc(p,'public_key') for p in pages]
            pins2=[{'device_id':actor+'-attack-case','actor':actor,'signing_key':bytes(key).hex(),'fingerprint':hashlib.sha256(bytes(key)).hexdigest(),'device_revision':1} for actor,key in zip(['alice','bob'],pub2)]
            config['devices']=[{**pin,'subject':sub,'status':'active','acceptance':'out-of-band-fingerprint'} for pin,sub in zip(pins2,['owner','family'])]
            commit(0,config['people']);start()
            for p in pages:rpc(p,'pin',{'room':'family','pins':pins2})
            package2=rpc(b,'key_package')
            a.evaluate("""()=>new Promise((resolve,reject)=>{
              const w=new Worker('/untrusted-worker.js',{type:'module'});window.fake=w;
              const timer=setTimeout(()=>reject(new Error('fake boot deadline')),5000);
              w.onmessage=({data})=>{if(data.boot){clearTimeout(timer);resolve();}};
            })""")
            def fake(method,argument=None):
                return a.evaluate("""([method,argument])=>new Promise((resolve,reject)=>{
                  const timer=setTimeout(()=>reject(new Error('fake call deadline')),5000);
                  window.fake.onmessage=({data})=>{clearTimeout(timer);if(!data.ok)reject(new Error('fake rejected'));else resolve(data.result);};
                  window.fake.postMessage({id:1,method,argument});
                })""",[method,argument])
            fake('init','alice');fake('create');forged=fake('invite',package2)
            rpc(b,'join',forged,reject=True);rpc(b,'encrypt',[1],reject=True)
            proof['checks']['valid_welcome_with_unaccepted_inviter_key_rejected_and_retired']=True
            browser.close()
        proof['passed']=True
    finally:
        if proxy:proxy.shutdown();proxy.server_close()
        stop()
        (work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n')
        print(work/'verification.json',flush=True)

if __name__=='__main__':
    os.umask(0o077)
    main()
