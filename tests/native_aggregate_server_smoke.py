#!/usr/bin/env python3
"""Aggregate custody against the REAL admission service (#49 fourth slice).

The Go server (family-dev) issues Ed25519-signed aggregate admissions through
`/v1/aggregate/admission` behind the same CF-Access-JWT grant as every other
endpoint, and serves the pinned policy public key through
`/v1/aggregate/policy-key`. The worker re-receives the fresh admission from
the server over same-origin fetch, outside IndexedDB, exactly the way a real
client would. Still synthetic loopback data: no human keys, no Cloudflare, no
production CF gate.
"""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parents[1]
CSP="default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"


def b64(b):
    return base64.urlsafe_b64encode(b).decode().rstrip('=')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True, type=Path,
                        help='identity-context WASM bundle (MLS signer binding)')
    parser.add_argument('--aggregate-store', required=True, type=Path)
    parser.add_argument('--binary', required=True, type=Path, help='family-dev binary')
    parser.add_argument('--policy-binary', required=True, type=Path, help='family-policy binary')
    args = parser.parse_args()
    binary, policy = args.binary.resolve(strict=True), args.policy_binary.resolve(strict=True)
    os.umask(0o077)
    work = Path(tempfile.mkdtemp(prefix='native-aggregate-server-', dir=ROOT / 'artifacts'))
    state, auth, proposals = [work / n for n in ('state', 'auth', 'proposals')]
    for d in (state, auth, proposals):
        d.mkdir(mode=0o700)
    store_bundle = args.aggregate_store.resolve(strict=True)

    # Provision the auth state the same way the device-browser harness does:
    # an RSA policy key, two people (owner=alice, family=bob), and each actor's
    # active device binding. The device signing keys are synthetic; the store
    # pins them as its signer key and the server echoes them into admissions.
    key = proposals / 'synthetic-private.pem'
    key.write_bytes(subprocess.check_output(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048'], stderr=subprocess.DEVNULL))
    key.chmod(0o600)
    modulus = subprocess.check_output(['openssl', 'rsa', '-in', str(key), '-noout', '-modulus'], stderr=subprocess.DEVNULL).decode().strip().split('=', 1)[1]
    device_keys = {actor: secrets.token_hex(32) for actor in ('alice', 'bob')}
    devices = []
    for actor, subject in (('alice', 'owner'), ('bob', 'family')):
        dev_key = device_keys[actor]
        devices.append({'device_id': actor + '-first', 'actor': actor, 'subject': subject,
                        'signing_key': dev_key, 'fingerprint': hashlib.sha256(bytes.fromhex(dev_key)).hexdigest(),
                        'status': 'active', 'device_revision': 1, 'acceptance': 'out-of-band-fingerprint'})
    config = {'version': 1, 'issuer': 'https://synthetic.cloudflareaccess.com', 'audience': 'synthetic-app',
              'keys': [{'kid': 'test-key', 'n': b64(bytes.fromhex(modulus)), 'e': 65537}],
              'people': [{'subject': 'owner', 'actor': 'alice', 'owner': True},
                         {'subject': 'family', 'actor': 'bob', 'owner': False}],
              'devices': devices}
    tokens = {}
    for subject in ('owner', 'family'):
        now = int(time.time())
        claims = {'iss': config['issuer'], 'aud': [config['audience']], 'sub': subject, 'type': 'app',
                  'iat': now - 60, 'nbf': now - 60, 'exp': now + 900}
        raw = b64(json.dumps({'alg': 'RS256', 'typ': 'JWT', 'kid': 'test-key'}).encode()) + '.' + b64(json.dumps(claims).encode())
        sig = subprocess.check_output(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=raw.encode())
        tokens[subject] = raw + '.' + b64(sig)
    candidate = proposals / 'candidate-0.json'
    candidate.write_text(json.dumps(config))
    candidate.chmod(0o600)
    r = subprocess.run([str(policy), '--synthetic-only', '--auth-state', str(auth), '--input', str(candidate), '--expected-revision', '0'], capture_output=True, text=True, timeout=5)
    assert r.returncode == 0, r.stderr

    process = output = None
    address = '127.0.0.1:0'
    log = work / 'server.log'
    def start_server():
        nonlocal process, output, address
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
            time.sleep(0.02)
        raise AssertionError('server startup timeout')
    def stop_server():
        if process and process.poll() is None:
            process.kill(); process.wait(timeout=5)
        if output:
            output.close()
    start_server()
    def direct(subject, method, path):
        r = urllib.request.Request('http://' + address + path, method=method,
                                   headers={'Cf-Access-Jwt-Assertion': tokens[subject]})
        try:
            with urllib.request.urlopen(r, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as e:
            e.close(); return e.code, None

    # The actor's committed room: one synthetic family room with both members.
    rooms_body = json.dumps({'id': 'family', 'members': ['bob']}).encode()
    req = urllib.request.Request('http://' + address + '/v1/rooms', method='POST', data=rooms_body,
                                 headers={'Cf-Access-Jwt-Assertion': tokens['owner'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=5) as response:
        assert response.status == 201
    status, key_doc = direct('owner', 'GET', '/v1/aggregate/policy-key')
    assert status == 200 and len(key_doc['public']) == 64, key_doc
    policy_public = key_doc['public']

    proof = {'synthetic_only': True, 'native_server': True, 'production_cf_gate': False, 'human_keys': False,
             'checks': {}, 'policy_public_sha256': hashlib.sha256(policy_public.encode()).hexdigest(),
             'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}

    signer = args.aggregate_store.parent / 'aggregate-policy-signer.js'
    signer.write_bytes(b"import{policySigner,policyKeypair} from '/native-aggregate-vault.js';"
                       b"window.policySigner=policySigner;window.policyKeypair=policyKeypair;")
    worker = (ROOT / 'experiments/openmls-browser/web/aggregate-vault-worker.js').read_bytes()
    fixture = (ROOT / 'tests/fixtures/aggregate-vault/main.js').read_bytes()
    fixture = fixture.replace(b"  if (data.id !== id) return;",
                              b"  if(data.test_crash_boundary)window.test_crash_boundary=true;\n" + b"  if (data.id !== id) return;")
    page = (b'<!doctype html><meta charset="utf-8"><title>Synthetic aggregate custody</title>'
            b'<script type="module" src="/main.js"></script>'
            b'<script type="module" src="/aggregate-policy-signer.js"></script>')
    assets = {'/': page, '/main.js': fixture, '/aggregate-vault-worker.js': worker,
              '/aggregate-policy-signer.js': signer.read_bytes(), '/native-aggregate-vault.js': store_bundle.read_bytes()}

    class Server(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            if self.path.startswith('/v1/aggregate/'):
                r = urllib.request.Request('http://' + address + self.path)
                jwt = self.headers.get('Cf-Access-Jwt-Assertion')
                if jwt:
                    r.add_header('Cf-Access-Jwt-Assertion', jwt)
                try:
                    with urllib.request.urlopen(r, timeout=5) as upstream:
                        data, code = upstream.read(), upstream.status
                except urllib.error.HTTPError as e:
                    data, code = e.read(), e.code
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers(); self.wfile.write(data)
                return
            if self.path not in assets:
                self.send_error(403); return
            data = assets[self.path]; self.send_response(200)
            self.send_header('Content-Type', 'text/html' if self.path == '/' else 'application/javascript')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Content-Security-Policy', CSP)
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers(); self.wfile.write(data)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://localhost:{server.server_port}'

    try:
        with sync_playwright() as pw:
            profiles = [work / 'alice-profile', work / 'bob-profile']
            for profile in profiles: profile.mkdir(mode=0o700)
            contexts = [pw.chromium.launch_persistent_context(str(profile)) for profile in profiles]
            proof['browser'] = contexts[0].browser.version
            def page(i):
                page_ = contexts[i].new_page()
                page_.goto(url); page_.wait_for_function('()=>window.ready===true')
                page_.wait_for_function('()=>window.policyKeypair!==undefined')
                page_.evaluate("spawn('device')")
                return page_
            def rpc(p_, method, arg=None, reject=False):
                r = p_.evaluate('([m,a])=>call("device",m,a)', [method, arg])
                assert r['memory_bytes'] <= 128 * 1024 * 1024
                if reject:
                    assert not r['ok'] and 'result' not in r, (method, r); return
                assert r['ok'], (method, r); return r.get('result')
            def reopen(p_, create=False):
                p_.evaluate("stopWorker('device');spawn('device')")
                rpc(p_, 'open', open_args(0, database, create))
            token = {'Cf-Access-Jwt-Assertion': tokens['owner']}
            passwords = {}
            def password_for(database):
                return passwords.setdefault(database, secrets.token_urlsafe(32))
            def open_args(i, database, create):
                return {'actor': ['alice', 'bob'][i], 'database': database, 'password': password_for(database),
                        'create': create, 'pub': device_keys[['alice', 'bob'][i]], 'policy': policy_public}
            database = 'family-mls-aggregate-synthetic-server'

            # The pinned policy key comes from the server's own endpoint; the
            # worker fetches every admission itself over same-origin fetch.
            a = page(0)
            rpc(a, 'open', open_args(0, database, create=True))
            got = rpc(a, 'put-room', {'room': 'family', 'bytes': list(b'server-signed aggregate alpha'),
                                      'admissionUrl': '/v1/aggregate/admission?revision=1', 'token': tokens['owner']})
            assert got['revision'] == 1, got
            assert got['rooms'] == ['family'] and got['pins'] == [{'actor': 'bob', 'signing_key': device_keys['bob']}]
            proof['checks']['server_signed_admission_seals_aggregate_with_committed_pins'] = True

            # A second write re-receives a FRESH admission for revision 2 from
            # the server; the deterministic bucket keeps the fresh re-read
            # consistent.
            got = rpc(a, 'put-room', {'room': 'family', 'bytes': list(b'server-signed aggregate beta'),
                                      'admissionUrl': '/v1/aggregate/admission?revision=2', 'token': tokens['owner']})
            assert got['revision'] == 2
            proof['checks']['server_issues_next_revision_for_second_write'] = True

            # The server refuses an unauthenticated admission fetch; the worker
            # relays that as a refusal and stays retired-safe.
            a.evaluate("stopWorker('device');spawn('device')")
            rpc(a, 'open', open_args(0, database, create=False))
            got = rpc(a, 'put-room', {'room': 'family', 'bytes': [1],
                                      'admissionUrl': '/v1/aggregate/admission?revision=3', 'token': json.dumps({})}, reject=True)
            reopen(a)
            proof['checks']['unauthenticated_admission_fetch_denied'] = True

            # A document signed by a DIFFERENT policy key is refused: the page
            # re-signs the server's own body with a foreign key.
            status, doc = direct('owner', 'GET', '/v1/aggregate/admission?revision=3')
            assert status == 200
            other = contexts[0].new_page()
            other.goto(url); other.wait_for_function('()=>window.policyKeypair!==undefined')
            kp = other.evaluate('()=>window.policyKeypair()')
            doc2 = dict(doc); doc2['signature'] = other.evaluate('([d,s])=>window.policySigner(s)(d)', [doc, kp['secret']])
            other.close()
            got = rpc(a, 'put-room', {'room': 'family', 'bytes': [3], 'admission': doc2}, reject=True)
            reopen(a)
            proof['checks']['foreign_policy_signature_denied'] = True

            # The MLS signer binding (#51) is still enforced on top of the
            # admission contract: the admission carries the registered device
            # signing key, and the store was opened with exactly that key.
            got = rpc(a, 'put-room', {'room': 'family', 'bytes': [7],
                                      'admissionUrl': '/v1/aggregate/admission?revision=3', 'token': tokens['owner']})
            assert got['revision'] == 3
            proof['checks']['honest_server_admission_advances_under_device_key'] = True

            for context in contexts: context.close()
        proof['passed'] = True
    finally:
        server.shutdown(); server.server_close()
        stop_server()
        (work / 'verification.json').write_text(json.dumps(proof, indent=2) + '\n')
        print(work / 'verification.json', flush=True)

if __name__ == '__main__':
    main()
