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
    args.add_argument('--history-ui', action='store_true')
    args.add_argument('--history', action='store_true')
    args.add_argument('--vault-ui', action='store_true')
    args.add_argument('--vault', action='store_true')
    args.add_argument('--aggregate-ui', action='store_true')
    args.add_argument('--aggregate', action='store_true')
    args.add_argument('--aggregate-history', action='store_true')
    args.add_argument('--aggregate-history-ui', action='store_true')
    args.add_argument('--aggregate-history-embedded', action='store_true')
    args.add_argument('--exchange-candidate', choices=['alice','bob'], default='bob')
    args.add_argument('--lease', action='store_true')
    args.add_argument('--retirement', action='store_true')
    args.add_argument('--enrollment', action='store_true')
    args.add_argument('--closure', action='store_true')
    args.add_argument('--successor-ui', action='store_true')
    args.add_argument('--successor-handoff', action='store_true')
    args.add_argument('--successor-embedded', action='store_true')
    args.add_argument('--confirmation', action='store_true')
    args.add_argument('--exchange', action='store_true')
    args.add_argument('--custody-order', choices=['candidate','peer','concurrent'])
    args.add_argument('--candidate-ceremony', action='store_true')
    args.add_argument('--candidate', action='store_true')
    args.add_argument('--candidate-original', action='store_true')
    args.add_argument('--successor-peer-original', action='store_true')
    args.add_argument('--successor-peer', action='store_true')
    args.add_argument('--preparation', action='store_true')
    args.add_argument('--embedded', action='store_true')
    args.add_argument('--ui', action='store_true')
    args.add_argument('--controls', action='store_true')
    args.add_argument('--bundle', required=True, type=Path)
    args.add_argument('--binary', required=True, type=Path)
    args.add_argument('--policy-binary', required=True, type=Path)
    args = args.parse_args()
    assert not (args.aggregate_history and args.aggregate_history_ui)
    assert not args.lease or args.confirmation
    assert not args.successor_ui or args.closure
    assert not args.successor_handoff or args.successor_ui
    assert not args.successor_embedded or args.successor_handoff
    assert not args.closure or args.enrollment
    assert not args.retirement or args.lease
    assert not args.enrollment or (args.lease and not args.retirement)
    assert not args.confirmation or args.exchange
    assert not args.exchange or args.custody_order
    assert not args.successor_peer_original or args.successor_peer
    assert not args.candidate_ceremony or (args.candidate and args.candidate_original and not args.successor_embedded)
    assert not args.candidate_original or args.candidate
    assert not args.candidate or not args.successor_peer
    assert not args.custody_order or not (args.candidate or args.successor_peer)
    aggregate_history=args.aggregate_history or args.aggregate_history_ui
    history_proof=args.history or args.history_ui
    assert not history_proof or (args.vault_ui and (not args.embedded or (args.history_ui and not args.history)))
    assert not args.aggregate_history_embedded or (args.aggregate_ui and args.embedded and not aggregate_history and not history_proof)
    aggregate_ui = args.aggregate_ui
    vault_ui = args.vault_ui or aggregate_ui
    vault = args.vault
    preparation = args.preparation or aggregate_ui
    assert not preparation or not args.aggregate
    aggregate = args.aggregate or preparation or aggregate_history or args.successor_peer or args.candidate or args.custody_order
    assert not (args.successor_peer or args.candidate or args.custody_order) or not (preparation or aggregate_history or args.aggregate or args.embedded)
    assert not aggregate_history or not (args.aggregate or preparation or history_proof or args.embedded)
    control_proof = args.controls
    ui_proof = args.ui or vault_ui
    embedded = args.embedded
    assert not vault_ui or not (vault or control_proof)
    assert not vault or not (ui_proof or embedded)
    assert not embedded or ui_proof
    assert not (control_proof and ui_proof)
    assert not aggregate or not (vault or history_proof or (ui_proof and not aggregate_ui) or (embedded and not aggregate_ui) or control_proof)
    binary, policy = args.binary.resolve(strict=True), args.policy_binary.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    work = Path(tempfile.mkdtemp(prefix='native-custody-' if args.custody_order else 'native-candidate-' if args.candidate else 'native-successor-peer-' if args.successor_peer else 'native-aggregate-history-ui-' if args.aggregate_history_ui else 'native-aggregate-history-' if aggregate_history else 'native-aggregate-ui-' if aggregate_ui else 'native-preparation-' if preparation else 'native-aggregate-' if aggregate else 'native-history-' if history_proof else 'native-vault-ui-' if vault_ui else 'native-vault-control-' if vault and control_proof else 'native-vault-browser-' if vault else 'native-embedded-ui-' if embedded else 'native-chat-ui-' if ui_proof else 'native-control-browser-' if control_proof else 'native-encrypted-browser-', dir=root / 'artifacts'))
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
        r = subprocess.run([str(policy), '--synthetic-only', '--auth-state', str(auth), '--input', str(candidate), '--expected-revision', str(revision)]+(['--activation-policy'] if config['version']==3 else ['--successor-policy'] if config['version']==2 else []), capture_output=True, text=True, timeout=5)
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
        process = subprocess.Popen([str(binary), '--synthetic-only', '--state', str(state), '--auth-state', str(auth), '--listen', address]+(['--synthetic-aggregate-history-ui' if args.aggregate_history_embedded else '--synthetic-aggregate-ui' if aggregate_ui else '--synthetic-history-ui' if args.history_ui else '--synthetic-vault-ui' if vault_ui else '--synthetic-mls-ui'] if embedded else ['--synthetic-successor-ui'] if args.successor_embedded else ['--synthetic-candidate-ui'] if args.candidate_ceremony else []), stderr=output, stdout=subprocess.DEVNULL)
        until = time.monotonic() + 10
        while time.monotonic() < until:
            assert process.poll() is None, 'server exited'
            match = re.search(r'listening (127\.0\.0\.1:\d+)', log.read_bytes()[offset:].decode())
            if match:
                if args.aggregate_history_embedded:
                    label=log.read_bytes()[offset:].decode()
                    assert 'two-room history /aggregate-history/ and custody /aggregate/' in label and 'UI /encrypted/' not in label, 'wrong selected UI startup label'
                    proof['checks']['compiled_aggregate_history_startup_and_restart_label_matches_selected_routes']=True
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
    def direct(subject, method, path, body=None, *, device=None):
        r = urllib.request.Request('http://' + address + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                   headers={'Cf-Access-Jwt-Assertion': tokens[subject, False], 'Content-Type': 'application/json','X-Family-Device':device if device is not None else ('alice' if subject=='owner' else 'bob')+'-first'})
        try:
            with urllib.request.urlopen(r, timeout=5) as response:
                data = response.read()
                return response.status, json.loads(data) if data else None
        except urllib.error.HTTPError as e:
            e.close()
            return e.code, None

    cookies=[secrets.token_hex(16),secrets.token_hex(16)]
    bindings=dict(zip(cookies,['owner','family']))
    assets={}
    for name in (['chat.html','chat.js','chat.css','native-worker.js','trust-directory.js'] if ui_proof else ['native.html','main.js','native-worker.js','trust-directory.js']):
        raw=(root/'experiments/openmls-browser/web'/name).read_bytes()
        if name=='main.js':
            old=b"durable ? './durable-worker.js' : './worker.js'"
            assert raw.count(old)==1;raw=raw.replace(old,b"'./native-worker.js'")
        assets['/' if name in ('native.html','chat.html') else '/'+name]=raw
    for name in ['family_mls_browser_experiment.js','family_mls_browser_experiment_bg.wasm']:
        p=args.bundle/name;st=p.lstat();assert not p.is_symlink() and st.st_nlink==1 and st.st_size<4*1024*1024
        assets['/pkg/'+name]=p.read_bytes()
    if vault_ui and not aggregate_ui:
        assets['/']=(root/'experiments/openmls-browser/web/vault-chat.html').read_bytes()
        for name in ['vault-chat.js','vault-native-worker.js']:
            assets['/'+name]=(root/'experiments/openmls-browser/web'/name).read_bytes()
        from password_worker_smoke import safe_bytes
        assets['/native-vault-store.js']=safe_bytes(root/'experiments/device-keystore/bundle/native-vault-store.js',1024*1024)
    if embedded and vault_ui:
        # Expected bytes are independent source inputs. Proxy only forwards;
        # every manifest route is also requested before any identity revocation.
        manifest_path=root/('server/internal/chat/aggregate_history_bundle.json' if args.aggregate_history_embedded else 'server/internal/chat/aggregate_bundle.json' if aggregate_ui else 'server/internal/chat/history_bundle.json' if args.history_ui else 'server/internal/chat/vault_bundle.json')
        pin = json.loads(manifest_path.read_text())
        assets = {}
        for e in pin['files']:
            source = args.bundle/e['source'][7:] if e['source'].startswith('bundle:') else root/e['source']
            raw = source.read_bytes()
            assert len(raw)==e['bytes'] and hashlib.sha256(raw).hexdigest()==e['sha256']
            assets[e['url']] = raw
        proof['manifest_sha256']=hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if history_proof and not embedded:
        from password_worker_smoke import safe_bytes
        inventory=json.loads(safe_bytes(root/'experiments/device-keystore/history-inventory.json',65536))
        for name in ('history-worker.js','history-export-worker.js'):
            raw=safe_bytes(root/'experiments/device-keystore/bundle'/name,1024*1024)
            assert len(raw)==inventory['bundles'][name]['bytes'] and hashlib.sha256(raw).hexdigest()==inventory['bundles'][name]['sha256']
            assets['/'+name]=raw
        assets['/history-client.js']=safe_bytes(root/'experiments/device-keystore/history-client.js',65536)
        if args.history_ui:
            for name in ('history.html','history.css','history-ui.js'):
                assets['/history/' if name=='history.html' else '/'+name]=safe_bytes(root/'experiments/device-keystore'/name,65536)
        assets['/history-forge-worker.js']=safe_bytes(root/'artifacts/history-forge-worker.js',1024*1024)
    if vault:
        from native_vault_checks import vault_assets
        vault_original=vault_assets(root,work,assets)
    if aggregate and not embedded:
        from native_aggregate_checks import aggregate_assets
        aggregate_original=aggregate_assets(root,work,assets)
    if args.custody_order:
        from native_custody_checks import custody_assets
        custody_assets(root,work,assets,proof)
        if args.exchange:
            from native_exchange_checks import exchange_assets
            exchange_assets(root,work,assets,proof)
            if args.confirmation:
                from native_confirmation_checks import confirmation_assets
                confirmation_assets(root,work,assets,proof)
                if args.lease:
                    from native_lease_checks import lease_assets
                    lease_assets(root,work,assets,proof)
                    if args.enrollment:
                        from native_enrollment_checks import enrollment_assets
                        enrollment_assets(root,work,assets,proof)
                    if args.closure:
                        from native_closure_checks import closure_assets
                        closure_assets(root,work,assets,proof)
                        if args.successor_ui:
                            from native_successor_ui_checks import ui_assets
                            ui_assets(root,assets,proof)
                            if args.successor_handoff:
                                from native_successor_handoff_checks import handoff_assets
                                handoff_assets(root,assets,proof)
                    if args.retirement:
                        from native_retirement_checks import retirement_assets
                        retirement_assets(root,work,assets,proof)
    if args.candidate:
        from native_candidate_checks import candidate_assets
        candidate_assets(root,work,assets,proof,args.candidate_original)
    if args.successor_peer:
        from native_successor_peer_checks import successor_assets
        successor_assets(root,work,assets,proof,args.successor_peer_original)
    if preparation and not embedded:
        assets['/prepared-fork-worker.js']=(root/'experiments/openmls-browser/web/prepared-fork-worker.js').read_bytes()
        assets['/main.js']=assets['/main.js'].replace(b'./aggregate-fork-worker.js',b'./prepared-fork-worker.js')
    if aggregate_history:
        from native_aggregate_history_checks import history_assets
        history_assets(root,work,assets,proof)
        if args.aggregate_history_ui:
            from password_worker_smoke import safe_bytes
            for name in ('aggregate-history.html','aggregate-history.css','aggregate-history-ui.js'):
                assets['/aggregate-history/' if name.endswith('.html') else '/'+name]=safe_bytes(root/'experiments/device-keystore'/name,65536)
            assets.pop('/aggregate-history-forge-worker.js',None)
            proof['aggregate_history_ui_packaging']='isolated synthetic fixture-served original UI/workers; native signed API; not compiled Go assets'
    if aggregate_ui and not embedded:
        for name in ('aggregate-chat.html','aggregate-chat.js'):
            assets['/' if name.endswith('.html') else '/'+name]=(root/'experiments/openmls-browser/web'/name).read_bytes()
        assets['/aggregate-store.js']=aggregate_original
        for route in ('/main.js','/chat.js','/vault-chat.js','/vault-native-worker.js','/native-vault-store.js','/aggregate-fork-worker.js'):
            assets.pop(route,None)
    proof['original_assets_sha256']={name:hashlib.sha256(raw).hexdigest() for name,raw in assets.items()}
    if vault:proof['original_assets_sha256']['/native-vault-store.js']=hashlib.sha256(vault_original).hexdigest()
    if aggregate and not embedded:proof['original_assets_sha256']['/aggregate-store.js']=hashlib.sha256(aggregate_original).hexdigest()
    if not ui_proof:
        raw=assets['/native-worker.js'];at=raw.index(b" if(method==='prepare'){")
        first,last=raw[:at],raw[at:]
        needle=b"['','abort-before-write','abort-after-write']"
        assert last.count(needle)==1;last=last.replace(needle,b"['','abort-before-write','abort-after-write','crash-before-complete','forged-inner']")
        needle=b"const f=frame(arg.id,own(current).device_id,identity,current.group,arg.media_type,data);"
        assert last.count(needle)==1;last=last.replace(needle,needle+b"if(arg.fault==='forged-inner')f.sender_actor='bob';")
        raw=first+last;needle=b"s.put(r,'state');if(fault==='abort-after-write')"
        assert raw.count(needle)==1;raw=raw.replace(needle,b"s.put(r,'state');if(fault==='crash-before-complete'){self.postMessage({test_crash_boundary:true});while(true){}}if(fault==='abort-after-write')")
        if control_proof:
            raw=raw.replace(b'let db,identity,room,retired=false;',b'let db,identity,room,retired=false;let testHoldSync=false;')
            needle=b'async function dispatch(method,arg){'
            assert raw.count(needle)==1;raw=raw.replace(needle,needle+b"if(method==='test-hold-sync'){testHoldSync=true;return null;}")
            needle=b'return status(r);});\n}\nasync function dispatch'
            assert raw.count(needle)==1;raw=raw.replace(needle,b"return status(r);},testHoldSync?'crash-before-complete':'');\n}\nasync function dispatch")
        if vault:
            needle=b'async function dispatch(method,arg){'
            raw=raw.replace(b'self.onmessage=({data})=>{',b'self.onmessage=({data})=>{if(data?.test_vault_release){if(data.test_vault_release===\"cas\")self.testVaultCASRelease?.();else self.testVaultKDFRelease?.();return;}')
            raw=raw.replace(needle,needle+b"if(method==='test-vault-hold-cas'){self.testHoldVaultCAS=true;return null;}if(method==='test-vault-hold-kdf'){self.testHoldVaultKDF=true;return null;}if(method==='test-vault-digest'){const r=await snapshot();return hash(arg==='crypto'?hex(r.crypto):requestShape(r.pending.request));}")
        if aggregate:
            raw=raw.replace(b'self.onmessage=({data})=>{',b'self.onmessage=({data})=>{if(data?.test_aggregate_release){self.testAggregateRelease?.();return;}')
            needle=b'async function dispatch(method,arg){'
            raw=raw.replace(needle,needle+b"if(method==='test-aggregate-hold'){self.testAggregateHold=true;return null;}if(method==='test-aggregate-digest'){await snapshot();return self.testAggregateInspection;}if(method==='test-aggregate-forge'){self.testAggregateForge=arg;return null;}if(method==='test-aggregate-quota-proof'){return self.testAggregateQuotaIndividuallyValid===true;}")
        assets['/native-worker.js']=raw
        needle=b"    if (data.id !== id) return;";assert assets['/main.js'].count(needle)==1
        assets['/main.js']=assets['/main.js'].replace(needle,b"    if(data.test_crash_boundary)window.test_crash_boundary=true;\n"+needle)
    if vault:assets['/main.js']=assets['/main.js'].replace(b'    if (data.id !== id) return;',b'    if(data.test_vault_cas)window.test_vault_cas=true;if(data.test_kdf_waiting)window.test_kdf_waiting=true;if(data.test_kdf_entered)window.test_kdf_entered=true;\n    if (data.id !== id) return;')
    if aggregate and not aggregate_ui:assets['/main.js']=assets['/main.js'].replace(b'    if (data.id !== id) return;',b'    if(data.test_aggregate_cas)window.test_aggregate_cas=true;\n    if (data.id !== id) return;')
    successor_compiled={}
    if args.successor_embedded:
        from native_successor_asset_checks import compiled_assets
        successor_compiled=compiled_assets(root,args.bundle,assets,proof)
    candidate_hooks={'fault':False,'posts':0}
    if args.candidate_ceremony:
        from native_candidate_ceremony_checks import compiled_assets
        successor_compiled=compiled_assets(root,args.bundle,assets,proof,work)
    proof['assets_sha256']={name:hashlib.sha256(raw).hexdigest() for name,raw in assets.items()}
    proof['test_instrumentation']='UI assets unmodified; disposable page tracks Blob URLs and drops one prepare before worker admission; generated proxy responses may be held/altered' if ui_proof else 'main selects native worker; served-only pending-write hold and deliberately forged inner sender fixture; proxy may hold/alter generated responses'
    if vault:proof['test_instrumentation']+='; encrypted driver held CAS/KDF/write, private-worker digests only, disposable lock-aware caller; original versus instrumented hashes recorded'
    if aggregate and not aggregate_ui:proof['test_instrumentation']+='; aggregate held CAS and base pending-write SIGKILL hook; whole native record digests only; separate original/instrumented driver hashes'
    hold_next=[False];arrived=threading.Event();release=threading.Event();tamper=[None];previous_cipher=[None];previous_commit=[None]
    lease_hooks={"callback":None,"posts":[],"channel_callback":None,"channel_posts":[]}
    confirmation_hooks={"callback":None,"posts":[]}
    exchange_hooks={"callback":None,"posts":[]}
    if args.enrollment:lease_hooks["enrollment"]={"callback":None,"posts":[],"channel_callback":None,"channel_posts":[]}
    if args.successor_ui:lease_hooks["enrollment"].update(ui_enabled=True,ui_asset_map=assets,ui_handoff=args.successor_handoff,ui_embedded=args.successor_embedded)
    if args.closure:lease_hooks["enrollment"]["closure"]={"callback":None,"posts":[]}
    if args.retirement:lease_hooks["retirement"]={"callback":None,"posts":[]}
    if args.lease:confirmation_hooks["lease"]=lease_hooks
    if args.confirmation:exchange_hooks["confirmation"]=confirmation_hooks
    custody_hooks={"callback":None,"posts":[]}
    if args.enrollment:custody_hooks["intent_ttl"]=480
    class Proxy(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_GET(self):self.forward()
        def do_POST(self):self.forward()
        def forward(self):
            if self.headers.get('Host')!=f'127.0.0.1:{self.server.server_port}' or not self.path.startswith('/') or self.path.startswith('//') or any(k.lower()=='authorization' or k.lower().startswith('cf-') for k in self.headers):self.send_error(400);return
            cookie=SimpleCookie();cookie.load(self.headers.get('Cookie',''));v=cookie.get('synthetic_edge');subject=bindings.get(v.value if v else None)
            successor_fault=(args.candidate_ceremony and candidate_hooks['fault'] and self.path=='/candidate-worker.js') or args.successor_embedded and lease_hooks['enrollment'].get('ui_fault_active') and self.path in ('/candidate-lifecycle-worker.js','/peer-lifecycle-worker.js')
            if not embedded and self.command=='GET' and self.path in assets and (self.path not in successor_compiled or successor_fault):
                raw=assets[self.path];self.send_response(200);self.send_header('Content-Type','application/wasm' if self.path.endswith('.wasm') else 'text/javascript' if self.path.endswith('.js') else 'text/css' if self.path.endswith('.css') else 'text/html');self.send_header('Content-Length',str(len(raw)));self.send_header('Cache-Control','no-store');self.send_header('Content-Security-Policy',"default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'");self.end_headers();self.wfile.write(raw);return
            size=int(self.headers.get('Content-Length','0'))
            if size<0 or size>98304:self.send_error(413);return
            body=self.rfile.read(size) if size else None
            headers={k:v for k,v in self.headers.items() if k.lower() not in ('cookie','connection','host','content-length','transfer-encoding')}
            headers['Host']=f'127.0.0.1:{self.server.server_port}'
            if args.candidate_ceremony and self.command=='POST':candidate_hooks['posts']+=1
            if subject:headers['Cf-Access-Jwt-Assertion']=tokens[subject,False]
            if args.closure and self.command=='POST' and self.path.endswith('/closure') and lease_hooks['enrollment']['closure'].get('drop_before'):
                lease_hooks['enrollment']['closure'].setdefault('dropped',[]).append(json.loads(body));self.close_connection=True;return
            if args.enrollment and self.command=='POST' and self.path.endswith('/'+(lease_hooks['enrollment'].get('drop_before') or 'unused')):
                lease_hooks['enrollment'].setdefault('dropped',[]).append(json.loads(body));self.close_connection=True;return
            if args.retirement and self.command=='POST' and self.path.endswith('/retirement') and lease_hooks['retirement'].get('drop_before'):
                lease_hooks['retirement'].setdefault('dropped',[]).append(json.loads(body));self.close_connection=True;return
            if args.lease and self.command=='POST' and self.path.endswith('/'+(lease_hooks.get('drop_before') or 'unused')):
                lease_hooks.setdefault('dropped',[]).append(json.loads(body));self.close_connection=True;return
            if args.confirmation and self.command=='POST' and self.path.endswith('/confirmation') and confirmation_hooks.get('drop_before'):
                confirmation_hooks.setdefault('dropped',[]).append(json.loads(body));self.close_connection=True;return
            if args.exchange and self.command=='POST' and self.path.endswith('/handshake') and exchange_hooks.get('drop_before'):
                exchange_hooks.setdefault('dropped',[]).append(json.loads(body));self.close_connection=True;return
            upstream=http.client.HTTPConnection(address,timeout=10)
            try:
                upstream.request(self.command,self.path,body=body,headers=headers);response=upstream.getresponse();raw=response.read()
                if self.command=='GET' and self.path in successor_compiled and response.status==200:
                    assert raw==successor_compiled[self.path],'compiled successor bytes differ'
                    assert response.getheader('X-Content-Type-Options')=='nosniff'
                    assert response.getheader('Cache-Control')=='no-store'
                    assert "frame-ancestors 'none'" in response.getheader('Content-Security-Policy','')
                    proof.setdefault('candidate_native_served_sha256' if args.candidate_ceremony else 'successor_native_served_sha256',{})[self.path]=hashlib.sha256(raw).hexdigest()
                if embedded and self.command=='GET':
                    asset_path='/' if self.path=='/encrypted/' and not vault_ui else self.path
                    if asset_path in assets and response.status==200:
                        actual=hashlib.sha256(raw).hexdigest()
                        assert actual==hashlib.sha256(assets[asset_path]).hexdigest(),'compiled asset mismatch'
                        proof.setdefault('native_served_assets_sha256',{})[asset_path]=actual
                if self.command=='POST' and (self.path.endswith('/log') or (preparation and self.path.endswith('/preparation'))) and response.status<300 and hold_next[0]:
                    hold_next[0]=False;arrived.set();release.wait(5)
                if self.command=='GET' and '/log?' in self.path and tamper[0] and response.status==200:
                    data=json.loads(raw)
                    for event in data:
                        q=event['request']
                        if q['kind']=='commit' and tamper[0].startswith('control-'):
                            kind=tamper[0][8:]
                            if kind=='cipher':
                                b=bytearray(base64.b64decode(q['payload']));b[-1]^=1;q['payload']=base64.b64encode(b).decode()
                            elif kind=='id':q['client_id']='update-substituted'
                            elif kind=='replay':q['payload']=previous_commit[0]
                            elif kind=='group':q['group_id']='ff'*32
                            elif kind=='device':q['device_id']='bob-first'
                            elif kind=='target':q['target_device']='alice-first'
                            event['sha256']=hashlib.sha256(json.dumps(q,separators=(',',':')).encode()).hexdigest()
                        if q['kind']=='application':
                            if tamper[0]=='cipher':
                                b=bytearray(base64.b64decode(q['payload']));b[-1]^=1;q['payload']=base64.b64encode(b).decode()
                            elif tamper[0]=='replay':q['payload']=previous_cipher[0]
                            elif tamper[0]=='id':q['client_id']='app-substituted'
                            elif tamper[0]=='room':q['group_id']='ff'*32
                            elif tamper[0]=='device':q['device_id']='bob-first'
                            event['sha256']=hashlib.sha256(json.dumps(q,separators=(',',':')).encode()).hexdigest()
                    raw=json.dumps(data).encode()
                if self.command=='GET' and self.path.endswith('/status') and tamper[0]=='binding' and response.status==200:
                    data=json.loads(raw);data['group_id']='aa'*32;raw=json.dumps(data).encode()
                context_bad_header=False
                if aggregate and self.command=='GET' and isinstance(tamper[0],dict) and self.path==tamper[0]['path'] and response.status==200:
                    hook=tamper[0];hook['seen']+=1;mode=hook['context'];data=json.loads(raw)
                    if mode=='invalid-json':raw=b'{'
                    elif mode=='oversize':raw=b' '*4097
                    elif mode=='wrong-header':context_bad_header=True
                    elif mode=='advance':
                        if hook['seen']==1:hook['after_first']()
                    else:
                        if mode=='wrong-room':data['room']='substituted'
                        elif mode=='wrong-key':data['pins'][1]['signing_key']='ff'*32
                        elif mode=='duplicate-pin':data['pins'][1]=data['pins'][0]
                        elif mode=='wrong-phase':data['phase']='ready'
                        elif mode=='wrong-group':data['group_id']='cd'*32
                        else:raise AssertionError('unknown generated context mutation')
                        raw=json.dumps(data).encode()
                status=response.status
                if args.closure and self.path.endswith('/closure'):
                    hook=lease_hooks['enrollment']['closure']
                    if self.command=='POST':hook['posts'].append(json.loads(body))
                    if hook['callback']:status,raw,context_bad_header=hook['callback'](self.command,status,raw)
                if args.enrollment and (self.path.endswith('/enrollment') or self.path.endswith('/enrolled-channel')):
                    hook=lease_hooks['enrollment'];prefix='channel_' if self.path.endswith('/enrolled-channel') else ''
                    if self.command=='POST':hook[prefix+'posts'].append(json.loads(body))
                    if hook[prefix+'callback']:status,raw,context_bad_header=hook[prefix+'callback'](self.command,status,raw)
                if args.retirement and self.path.endswith('/retirement'):
                    hook=lease_hooks['retirement']
                    if self.command=='POST':hook['posts'].append(json.loads(body))
                    if hook['callback']:status,raw,context_bad_header=hook['callback'](self.command,status,raw)
                if args.lease and (self.path.endswith('/lease') or self.path.endswith('/channel')):
                    prefix='channel_' if self.path.endswith('/channel') else ''
                    if self.command=='POST':lease_hooks[prefix+'posts'].append(json.loads(body))
                    if lease_hooks[prefix+'callback']:status,raw,context_bad_header=lease_hooks[prefix+'callback'](self.command,status,raw)
                if args.confirmation and self.path.endswith('/confirmation'):
                    if self.command=='POST':confirmation_hooks['posts'].append(json.loads(body))
                    if confirmation_hooks['callback']:
                        status,raw,context_bad_header=confirmation_hooks['callback'](self.command,status,raw)
                if args.exchange and self.path.endswith('/handshake'):
                    if self.command=='POST':exchange_hooks['posts'].append(json.loads(body))
                    if exchange_hooks['callback']:
                        status,raw,context_bad_header=exchange_hooks['callback'](self.command,status,raw)
                if args.custody_order and self.path.endswith('/custody'):
                    if self.command=='POST':custody_hooks['posts'].append(json.loads(body))
                    if custody_hooks['callback']:
                        status,raw,context_bad_header=custody_hooks['callback'](self.command,status,raw)
                self.send_response(status)
                if status==307:self.send_header('Location','/v1/session')
                for k,v in response.getheaders():
                    if context_bad_header and k.lower()=='x-family-actor':v='invalid'
                    if k.lower() not in ('connection','transfer-encoding','server','date','content-length'):self.send_header(k,v)
                self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
            except (OSError,http.client.HTTPException):pass
            finally:upstream.close()
    try:
        start();assert direct('owner','POST','/v1/mls/reservations',{'room':'family','peer_actor':'bob'})[0]==201
        proxy=ThreadingHTTPServer(('127.0.0.1',0),Proxy);threading.Thread(target=proxy.serve_forever,daemon=True).start();url=f'http://127.0.0.1:{proxy.server_port}'
        if args.successor_embedded:
            from native_successor_asset_checks import route_checks
            route_checks(proxy.server_port,cookies,successor_compiled,proof)
        if args.candidate_ceremony:
            from native_candidate_ceremony_checks import route_checks
            route_checks(proxy.server_port,cookies,successor_compiled,proof)
        if embedded and vault_ui:
            for path in assets:
                for principal, expected in ((None,401),(cookies[0],200)):
                    headers={'Cookie':'synthetic_edge='+principal} if principal else {}
                    connection=http.client.HTTPConnection('127.0.0.1',proxy.server_port,timeout=10)
                    connection.request('GET',path,headers=headers)
                    response=connection.getresponse();raw=response.read();connection.close()
                    assert response.status==expected,(path,response.status)
                    if expected==200:assert raw==assets[path]
            proof['checks']['all_'+str(len(assets))+'_native_routes_require_signed_admission']=True
        if ui_proof:
            from native_chat_ui_checks import run_ui
            run_ui(work,url,cookies,config,commit,direct,proof,hold_next,arrived,release,tamper,page_url=url+('/aggregate/' if aggregate_ui else '/vault/' if vault_ui else '/encrypted/') if embedded else url,restart=(lambda:(stop(),start())) if embedded else None,vault=vault_ui,history=history_proof,history_ui=args.history_ui,history_embedded=embedded and args.history_ui,aggregate=aggregate_ui,aggregate_history_embedded=args.aggregate_history_embedded)
            if embedded:
                proof['ui_packaging']='compiled native Go server assets; proxy only injects generated assertions'
                proof['native_embedded_ui']=True
                assert set(proof['native_served_assets_sha256'])==set(assets)
                proof['checks']['all_ui_worker_wasm_bytes_verified_from_native_server']=True
            proof['passed']=True
            return
        with sync_playwright() as pw:
            profiles=[work/'alice-profile',work/'bob-profile']
            for p in profiles:p.mkdir(mode=0o700)
            contexts=[pw.chromium.launch_persistent_context(str(p)) for p in profiles]
            proof['browser']=contexts[0].browser.version;proof['max_worker_linear_memory_bytes']=0
            databases=[('family-mls-device-vault-synthetic-' if aggregate else 'family-mls-vault-synthetic-' if vault else 'family-mls-native-control-synthetic-')+x for x in ['alice','bob']]
            initialized=set();vault_passwords=[secrets.token_urlsafe(32),secrets.token_urlsafe(32)]
            def cookie(i,value=None):contexts[i].add_cookies([{'name':'synthetic_edge','value':value or cookies[i],'url':url,'httpOnly':True,'sameSite':'Strict'}])
            for i in range(2):cookie(i)
            def page(i):
                p=contexts[i].new_page();p.add_init_script("window.testWorkers=[];const W=Worker;window.Worker=class extends W{constructor(...args){super(...args);window.testWorkers.push(this)}};");p.goto(url);p.wait_for_function('()=>window.ready===true');p.evaluate("spawn('device')");return p
            def rpc(p,method,arg=None,reject=False):
                r=p.evaluate('([m,a])=>call("device",m,a)',[method,arg]);proof['max_worker_linear_memory_bytes']=max(proof['max_worker_linear_memory_bytes'],r['memory_bytes']);assert r['memory_bytes']<=128*1024*1024
                if reject:assert not r['ok'] and 'result' not in r;return
                assert r['ok'],(method,r);return r['result']
            def init(p,i,database=None,identity=None,selected_room='family',reject=False):
                selected=database or databases[i]
                arg={'identity':identity or ['alice','bob'][i],'room':selected_room,'database':selected}
                if vault or aggregate:arg.update(password=vault_passwords[i],create=selected not in initialized)
                result=rpc(p,'init',arg,reject)
                if not reject:initialized.add(selected)
                return result
            def reopen(p,i):p.evaluate("stopWorker('device');spawn('device')");return init(p,i)
            def crash(i):
                session=contexts[i].browser.new_browser_cdp_session();pid=next(int(p['id']) for p in session.send('SystemInfo.getProcessInfo')['processInfo'] if p['type']=='browser');assert ('--user-data-dir='+str(profiles[i])).encode() in Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                import signal
                os.kill(pid,signal.SIGKILL)
                try:contexts[i].close()
                except BrowserError:pass
                contexts[i]=pw.chromium.launch_persistent_context(str(profiles[i]));cookie(i)
            def digest(p,i,part='all',database=None):
                if vault and part!='all':return rpc(p,'test-vault-digest',part)
                return p.evaluate("""async ([name,part])=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});const s=await new Promise((r,j)=>{const q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(JSON.stringify(part==='crypto'?s.crypto:part==='pending'?s.pending.request:s)))))}""",[database or databases[i],part])
            def prepare(p,id,data,kind='text',fault='',reject=False):return rpc(p,'prepare',{'id':id,'bytes':list(data),'media_type':kind,'fault':fault},reject)
            a,b=page(0),page(1);initial=[init(a,0),init(b,1)]
            pins=[{'device_id':actor+'-first','actor':actor,'signing_key':bytes(x['public_key']).hex(),'fingerprint':hashlib.sha256(bytes(x['public_key'])).hexdigest(),'device_revision':1} for actor,x in zip(['alice','bob'],initial)]
            config['devices']=[{**p,'subject':sub,'status':'active','acceptance':'out-of-band-fingerprint'} for p,sub in zip(pins,['owner','family'])];commit(1,config['people'])
            until=time.monotonic()+5
            while time.monotonic()<until:
                code,d=direct('owner','GET','/v1/rooms/family/devices')
                if code==200 and len(d['devices'])==2:break
                time.sleep(.05)
            else:raise AssertionError('directory reload')
            for p in (a,b):rpc(p,'pin',{'pins':pins,'fault':''})
            rpc(a,'create');rpc(a,'bind');rpc(b,'attach')
            # Reject malformed no-payload commands before any directory/network or
            # durable mutation; each failure retires its worker.
            for method in ('sync','status','create','bind','attach','advance','flush'):
                before=digest(b,1)
                rpc(b,method,{'unexpected':'synthetic malformed payload'},reject=True)
                assert digest(b,1)==before
                rpc(b,'status',reject=True)
                reopen(b,1)
            proof['checks']['malformed_arguments_deny_without_mutation_and_retire']=True
            rpc(b,'advance');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync')
            rpc(a,'advance');rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
            rpc(b,'advance');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync')
            assert rpc(a,'status')['phase']==rpc(b,'status')['phase']=='ready'
            proof['checks']['native_keypackage_welcome_ack_actual_library_group']=True
            if args.custody_order:
                from native_custody_checks import run
                run(a,b,databases,rpc,prepare,proof,page,vault_passwords,pins,direct,config,commit,crash,digest,tamper,lambda:(stop(),start()),custody_hooks,args.custody_order,exchange_hooks if args.exchange else None,args.exchange_candidate)
                for c in contexts:c.close()
                proof['passed']=True
                return
            if args.candidate_ceremony:
                from native_candidate_ceremony_checks import run
                run(a,b,databases,rpc,prepare,proof,page,vault_passwords,pins,direct,config,commit,crash,digest,tamper,lambda:(stop(),start()),candidate_hooks,args.exchange_candidate)
                for c in contexts:c.close()
                proof['passed']=True
                return
            if args.candidate:
                from native_candidate_checks import run
                run(a,b,databases,rpc,prepare,proof,page,vault_passwords,pins,direct,config,commit,crash,digest,tamper,lambda:(stop(),start()),args.candidate_original)
                for c in contexts:c.close()
                proof['passed']=True
                return
            if args.successor_peer:
                from native_successor_peer_checks import run
                run(a,b,databases,rpc,init,reopen,prepare,proof,page,vault_passwords,pins,direct,config,commit,crash,digest,tamper,lambda:(stop(),start()),args.successor_peer_original)
                for c in contexts:c.close()
                proof['passed']=True
                return
            if preparation:
                from native_preparation_checks import run
                run(a,b,databases,rpc,init,reopen,prepare,proof,page,vault_passwords,pins,direct,config,commit,crash,digest,hold_next,arrived,release,tamper,lambda:(stop(),start()))
                for c in contexts:c.close()
                proof['passed']=True
                return
            if aggregate:
                from native_aggregate_checks import aggregate_checks
                aggregate_checks(a,b,databases,rpc,init,reopen,prepare,proof,page,vault_passwords,pins,direct,config,commit,crash,digest,hold_next,arrived,release,tamper,history='ui' if args.aggregate_history_ui else args.aggregate_history)
                if args.aggregate_history_ui:
                    routes=['/aggregate-history/','/aggregate-history.css','/aggregate-history-ui.js','/aggregate-history-client.js','/aggregate-history-worker.js','/aggregate-history-export-worker.js']
                    observed={}
                    for route in routes:
                        with urllib.request.urlopen(url+route,timeout=5) as response:raw=response.read(1024*1024)
                        observed[route]=hashlib.sha256(raw).hexdigest()
                        assert observed[route]==proof['original_assets_sha256'][route]==proof['assets_sha256'][route]
                    assert '/aggregate-history-forge-worker.js' not in assets
                    proof['aggregate_history_ui_fixture_served_sha256']=observed
                    proof['checks']['aggregate_history_ui_original_six_fixture_response_hashes_verified_no_forger']=True
                for context in contexts:context.close()
                proof['passed']=True
                return
            if control_proof:
                def update(p,id,fault='',reject=False):return rpc(p,'update',{'id':id,'fault':fault},reject)
                before=digest(a,0);rpc(a,'update',{'id':'update-bad','extra':True},reject=True);assert digest(a,0)==before;reopen(a,0)
                before=digest(b,1);update(b,'update-peer',reject=True);assert digest(b,1)==before;reopen(b,1)
                before=digest(a,0);update(a,'update-first',fault='abort-after-write',reject=True);assert digest(a,0)==before;reopen(a,0)
                proof['checks']['control_malformed_wrong_creator_and_aborted_candidate_denied']=True
                # Two tabs stage one immutable commit, retaining the old epoch.
                tab=page(0);init(tab,0)
                a.evaluate('()=>{window.pending=call("device","update",{id:"update-first",fault:""})}')
                update(tab,'update-first');assert a.evaluate('window.pending')['ok']
                before_pending=digest(a,0,'pending');assert rpc(a,'status')['epoch']==1
                prepare(b,'app-before-update',b'synthetic old epoch while pending');rpc(b,'flush');rpc(b,'sync')
                got=rpc(a,'sync');assert got['epoch']==1 and got['pending']['client_id']=='update-first'
                assert base64.b64decode(got['messages'][-1]['payload'])==b'synthetic old epoch while pending' and digest(a,0,'pending')==before_pending
                proof['checks']['pending_commit_persists_old_epoch_and_accepts_preceding_peer_application']=True
                prepare(b,'app-before-echo',b'synthetic old epoch before own echo');rpc(b,'flush');rpc(b,'sync')
                first=rpc(a,'flush');assert rpc(tab,'flush')['seq']==first['seq']
                assert rpc(a,'status')['epoch']==1
                got=rpc(a,'sync');assert got['epoch']==2 and got['phase']=='ack' and got['pending'] is None
                assert base64.b64decode(got['messages'][-1]['payload'])==b'synthetic old epoch before own echo'
                before=digest(a,0);rpc(tab,'sync');rpc(a,'sync');assert digest(a,0)==before
                proof['checks']['ordered_self_echo_merges_after_old_traffic_once_across_tabs']=True
                before=digest(b,1)
                for kind in ('cipher','id','group','device','target'):
                    tamper[0]='control-'+kind;rpc(b,'sync',reject=True);assert digest(b,1)==before;tamper[0]=None;reopen(b,1)
                proof['checks']['authenticated_control_aad_cipher_and_outer_identity_deny_without_state_loss']=True
                before=digest(b,1);rpc(b,'test-hold-sync')
                b.evaluate('()=>{window.pending=call("device","sync",null).catch(()=>null)}');b.wait_for_function('()=>window.test_crash_boundary===true',timeout=5000)
                crash(1);b=page(1);init(b,1);assert digest(b,1)==before
                proof['checks']['browser_crash_during_peer_control_merge_retains_full_old_state']=True
                got=rpc(b,'sync');assert got['epoch']==2 and got['phase']=='ack'
                before=digest(b,1);crash(1);b=page(1);init(b,1);assert digest(b,1)==before
                before=digest(a,0);prepare(a,'app-before-ack',b'premature',reject=True);assert digest(a,0)==before;reopen(a,0)
                rpc(b,'advance');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync')
                assert rpc(a,'status')['phase']==rpc(b,'status')['phase']=='ready'
                proof['checks']['peer_control_merge_restart_and_ack_barrier']=True
                previous_commit[0]=next(e['request']['payload'] for e in direct('owner','GET','/v1/mls/rooms/family/log?after=0')[1] if e['request']['kind']=='commit')
                before=digest(a,0);update(a,'update-first');assert digest(a,0)==before
                # A new update's lost response followed by actual browser SIGKILL
                # must load its pending provider and retry the exact native bytes.
                update(a,'update-second');before_pending=digest(a,0,'pending');before_crypto=digest(a,0,'crypto')
                hold_next[0]=True;arrived.clear();release.clear()
                a.evaluate('()=>{window.pending=call("device","flush",null).catch(()=>null)}');assert arrived.wait(3)
                crash(0);release.set();a=page(0);got=init(a,0)
                assert got['epoch']==2 and got['pending']['client_id']=='update-second'
                assert digest(a,0,'pending')==before_pending and digest(a,0,'crypto')==before_crypto
                rpc(a,'flush');rpc(a,'sync');assert rpc(a,'status')['epoch']==3
                proof['checks']['control_lost_reply_browser_restart_exact_pending_commit_retry']=True
                before=digest(b,1);tamper[0]='control-replay';rpc(b,'sync',reject=True);assert digest(b,1)==before;tamper[0]=None;reopen(b,1)
                rpc(b,'sync');rpc(b,'advance');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync')
                proof['checks']['prior_epoch_commit_replay_denied_original_then_applies']=True
                before=digest(a,0);update(a,'update-second');assert digest(a,0)==before
                assert rpc(a,'status')['epoch']==rpc(b,'status')['epoch']==3
                prepare(a,'app-new-epoch',b'synthetic new epoch');rpc(a,'flush');rpc(a,'sync');got=rpc(b,'sync')
                assert base64.b64decode(got['messages'][-1]['payload'])==b'synthetic new epoch'
                proof['checks']['repeated_updates_and_new_epoch_application_delivery']=True
                arrived.clear();release.clear()
            message='synthetic native encrypted text / 한글'.encode();prepare(a,'app-text',message);rpc(a,'flush');rpc(a,'sync');got=rpc(b,'sync');assert base64.b64decode(got['messages'][-1]['payload'])==message
            previous_cipher[0]=next(e['request']['payload'] for e in direct('owner','GET','/v1/mls/rooms/family/log?after=0')[1] if e['request']['kind']=='application')
            file=bytes(range(256))*8;prepare(b,'app-file',file,'file');rpc(b,'flush');rpc(b,'sync');got=rpc(a,'sync');assert base64.b64decode(got['messages'][-1]['payload'])==file and got['messages'][-1]['media_type']=='file'
            assert direct('owner','GET','/v1/rooms/family/messages')[0]==403
            import sqlite3
            with sqlite3.connect(f'file:{state}/messages.sqlite?mode=ro',uri=True) as connection:
                stored=b''.join(row[0] for row in connection.execute('SELECT request FROM mls_events'))
                assert message not in stored and base64.b64encode(message) not in stored
                assert connection.execute('SELECT count(*) FROM messages').fetchone()[0]==0
            proof['checks']['two_browsers_text_and_file_native_ciphertext_only']=True
            before=digest(a,0);prepare(a,'app-abort',b'synthetic abort',fault='abort-after-write',reject=True);assert digest(a,0)==before;reopen(a,0)
            prepare(a,'app-lost',b'synthetic lost response');hold_next[0]=True
            a.evaluate('()=>{window.pending=call("device","flush",null).catch(()=>null)}');assert arrived.wait(3)
            crash(0);release.set();a=page(0);restored=init(a,0);assert restored['public_key']==initial[0]['public_key'] and restored['pins']==pins and restored['pending']['client_id']=='app-lost'
            before=digest(a,0);rpc(a,'flush');assert digest(a,0)==before;rpc(a,'sync');got=rpc(b,'sync');assert base64.b64decode(got['messages'][-1]['payload'])==b'synthetic lost response'
            proof['checks']['atomic_outbox_and_browser_crash_lost_native_reply']=True
            before=digest(b,1);crash(1);b=page(1);init(b,1);assert digest(b,1)==before;rpc(b,'sync');assert digest(b,1)==before
            proof['checks']['receiver_restart_no_duplicate_decrypt_or_display']=True
            prepare(a,'app-tamper',b'synthetic tamper target');rpc(a,'flush');rpc(a,'sync')
            before=digest(b,1)
            for kind in ['cipher','replay','id','room','device']:
                tamper[0]=kind;rpc(b,'sync',reject=True);assert digest(b,1)==before;tamper[0]=None;reopen(b,1)
            got=rpc(b,'sync');assert base64.b64decode(got['messages'][-1]['payload'])==b'synthetic tamper target'
            proof['checks']['tamper_outer_id_group_device_rejected_without_ratchet_loss']=True
            # Two tabs stage and reconcile one immutable application operation.
            observer=page(0);init(observer,0)
            turn_args={'id':'app-tabs','bytes':list(b'synthetic two tabs'),'media_type':'text','fault':''}
            a.evaluate('arg=>{window.pending=call("device","prepare",arg)}',turn_args)
            rpc(observer,'prepare',turn_args);assert a.evaluate('window.pending')['ok']
            first=rpc(a,'flush');second=rpc(observer,'flush');assert first['seq']==second['seq']
            rpc(a,'sync');count=len(rpc(observer,'sync')['messages']);assert len(rpc(a,'sync')['messages'])==count
            got=rpc(b,'sync');assert base64.b64decode(got['messages'][-1]['payload'])==b'synthetic two tabs'
            proof['checks']['two_tabs_exact_native_ciphertext_and_self_echo_once']=True
            before=digest(a,0);tamper[0]='binding';prepare(a,'app-binding',b'bad binding',reject=True);assert digest(a,0)==before;tamper[0]=None;reopen(a,0)
            proof['checks']['changed_native_binding_denied_before_crypto_mutation']=True
            before=digest(a,0);turn_args={'id':'app-inflight','bytes':list(b'synthetic transaction hold'),'media_type':'text','fault':'crash-before-complete'}
            a.evaluate('arg=>{window.pending=call("device","prepare",arg).catch(()=>null)}',turn_args);a.wait_for_function('()=>window.test_crash_boundary===true',timeout=5000)
            crash(0);a=page(0);init(a,0);assert digest(a,0)==before
            prepare(a,'app-inflight',b'synthetic transaction hold');rpc(a,'flush');rpc(a,'sync');got=rpc(b,'sync');assert base64.b64decode(got['messages'][-1]['payload'])==b'synthetic transaction hold'
            proof['checks']['inflight_browser_crash_retains_complete_crypto_and_native_outbox']=True
            # Copy only inside the private disposable profile, then corrupt the copy.
            corrupt_db=databases[0]+'-corrupt'
            a.evaluate("""async([source,target])=>{const db=await new Promise((r,j)=>{const q=indexedDB.open(source);q.onsuccess=()=>r(q.result);q.onerror=j});const record=await new Promise((r,j)=>{const q=db.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});db.close();record.cursor++;await new Promise((r,j)=>{const q=indexedDB.open(target,1);q.onupgradeneeded=()=>q.result.createObjectStore('device').add(record,'state');q.onsuccess=()=>{q.result.close();r()};q.onerror=j})}""",[databases[0],corrupt_db])
            if vault:initialized.add(corrupt_db)
            before_bad=digest(a,0,database=corrupt_db);corrupt=page(0);init(corrupt,0,database=corrupt_db,reject=True);assert digest(a,0,database=corrupt_db)==before_bad
            proof['checks']['corrupt_native_cursor_retained_and_denied']=True
            before=digest(a,0);wrong=page(0);cookie(0,cookies[1]);init(wrong,0,identity='bob',reject=True);assert digest(wrong,0)==before;cookie(0)
            assert direct('owner','POST','/v1/mls/reservations',{'room':'private','peer_actor':'bob'})[0]==201
            wrong_room=page(0);init(wrong_room,0,selected_room='private',reject=True);assert digest(wrong_room,0)==before
            fresh=page(0);init(fresh,0,database=databases[0]+'-missing',reject=True)
            proof['checks']['account_binding_and_missing_registered_keys_fail_closed']=True
            malformed=page(0);init(malformed,0);before=digest(a,0)
            malformed.evaluate('window.testWorkers.at(-1).postMessage(null)');rpc(malformed,'status',reject=True);assert digest(a,0)==before
            proof['checks']['malformed_command_retires_worker_with_bounded_failure_reply']=True
            if vault:
                from native_vault_checks import vault_checks
                vault_checks(a,b,databases,rpc,reopen,prepare,proof,page,vault_passwords)
            # A valid encryption from Alice with a forged inner sender label still fails.
            prepare(a,'app-forged',b'synthetic wrong inner sender',fault='forged-inner');rpc(a,'flush');rpc(a,'sync')
            before=digest(b,1);rpc(b,'sync',reject=True);assert digest(b,1)==before;reopen(b,1)
            proof['checks']['valid_mls_ciphertext_cannot_substitute_inner_sender']=True
            # A later unsupported control freezes the client. An unaccepted old
            # pending application is retained/retired, never re-encrypted.
            prepare(b,'app-stale',b'synthetic stale pending')
            before_crypto=digest(b,1,'crypto');before_pending=digest(b,1,'pending')
            room_status=direct('owner','GET','/v1/mls/rooms/family/status')[1]
            q={'client_id':'opaque-update','device_id':'alice-first','group_id':room_status['group_id'],'kind':'commit','expected_revision':room_status['revision'],'epoch':room_status['epoch'],'target_device':'bob-first','payload':base64.b64encode(b'synthetic opaque future control').decode()}
            if control_proof:
                update(a,'update-stale-peer');rpc(a,'flush');rpc(a,'sync')
                assert rpc(a,'status')['epoch']==4
            else:assert direct('owner','POST','/v1/mls/rooms/family/log',q)[0]==201
            rpc(b,'flush',reject=True);reopen(b,1);assert rpc(b,'status')['pending']=={'client_id':'app-stale','retired':True}
            assert digest(b,1,'crypto')==before_crypto and digest(b,1,'pending')==before_pending
            prepare(b,'app-stale',b'synthetic stale pending',reject=True);reopen(b,1)
            proof['checks']['unaccepted_stale_pending_retained_and_retired']=True
            stop();start();assert rpc(a,'status')['pins']==pins
            config['devices'][1]['status']='revoked';config['devices'][1]['device_revision']=2;commit(2,config['people'])
            until=time.monotonic()+5
            while time.monotonic()<until:
                code,d=direct('owner','GET','/v1/rooms/family/devices')
                if code==200 and any(p['status']=='revoked' for p in d['devices']):break
                time.sleep(.05)
            else:raise AssertionError('revocation reload')
            before=digest(a,0);rpc(a,'sync',reject=True);assert digest(a,0)==before
            new=page(0);init(new,0,reject=True);rpc(b,'status',reject=True)
            proof['checks']['durable_revocation_blocks_cache_and_reopen']=True
            for c in contexts:c.close()
        proof['native_encrypted_roundtrip']=True
        proof['passed']=True
    finally:
        release.set()
        if proxy:proxy.shutdown();proxy.server_close()
        stop();(work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(work/'verification.json',flush=True)

if __name__=='__main__':main()
