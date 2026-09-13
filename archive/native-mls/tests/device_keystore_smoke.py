#!/usr/bin/env python3
"""Disposable virtual-authenticator feasibility, never real passkeys or MLS state."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import stat
import tempfile
import threading
import time
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parents[1]
CSP="default-src 'none'; script-src 'self'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"

def main():
    p=argparse.ArgumentParser();p.add_argument('--synthetic-only',action='store_true');p.add_argument('--uv-recovery-probe',action='store_true');args=p.parse_args()
    assert args.synthetic_only, 'explicit synthetic acknowledgement required'
    artifacts=ROOT/'artifacts';artifacts.mkdir(mode=0o700,exist_ok=True)
    assert artifacts.is_dir() and not artifacts.is_symlink() and artifacts.stat().st_uid==os.geteuid()
    out=Path(tempfile.mkdtemp(prefix='device-keystore-',dir=artifacts));out.chmod(0o700)
    sources={'/probe.js':ROOT/'experiments/device-keystore/bundle/probe.js','/worker.js':ROOT/'experiments/device-keystore/worker.js'}
    assets={'/':b'<!doctype html><meta charset="utf-8"><title>Synthetic key capability only</title><script type="module" src="/probe.js"></script>'}
    for route,path in sources.items():
        assert not any(parent.is_symlink() for parent in path.parents)
        s=path.lstat();assert s.st_uid==os.geteuid() and stat.S_ISREG(s.st_mode) and s.st_nlink==1 and s.st_size<1024*1024 and not s.st_mode&0o022
        assets[route]=path.read_bytes()
    pinned=json.loads((ROOT/'experiments/device-keystore/inventory.json').read_text())['bundle']['sha256']
    assert hashlib.sha256(assets['/probe.js']).hexdigest()==pinned, 'candidate bundle differs from recorded build'
    proof={'synthetic_only':True,'human_key_protection':False,'native_integration':False,'virtual_authenticator_only':True,'uv_recovery_probe':args.uv_recovery_probe,'checks':{},'asset_sha256':{k:hashlib.sha256(v).hexdigest() for k,v in assets.items()}}
    class Server(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_GET(self):
            expected=f'localhost:{self.server.server_port}'
            if self.headers.get('Host')!=expected or self.path not in assets or self.headers.get('Origin') not in (None,'http://'+expected):self.send_error(403);return
            data=assets[self.path];self.send_response(200);self.send_header('Content-Type','text/html' if self.path=='/' else 'text/javascript');self.send_header('Content-Length',str(len(data)));self.send_header('Content-Security-Policy',CSP);self.send_header('X-Content-Type-Options','nosniff');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
    server=ThreadingHTTPServer(('127.0.0.1',0),Server);threading.Thread(target=server.serve_forever,daemon=True).start()
    start=time.monotonic()
    try:
        with sync_playwright() as pw:
            browser=pw.chromium.launch();contexts=[]
            def client(prf=True):
                context=browser.new_context();contexts.append(context);page=context.new_page();cdp=context.new_cdp_session(page)
                cdp.send('WebAuthn.enable')
                auth=cdp.send('WebAuthn.addVirtualAuthenticator',{'options':{'protocol':'ctap2','ctap2Version':'ctap2_1','transport':'internal','hasResidentKey':True,'hasUserVerification':True,'hasPrf':prf,'isUserVerified':True,'automaticPresenceSimulation':True}})['authenticatorId']
                page.goto(f'http://localhost:{server.server_port}')
                # No wait_for_function string eval under the actual restrictive CSP.
                for _ in range(100):
                    if page.evaluate('Boolean(window.probe)'):break
                    page.wait_for_timeout(20)
                assert page.evaluate('Boolean(window.probe)')
                return page,cdp,auth
            def run(page,expr):return page.evaluate('async()=>await ('+expr+')')
            def denied(page,expr):
                return page.evaluate('async()=>{try{await ('+expr+');return false}catch{return true}}')
            a,cdp,auth=client();b,_,_=client();c,_,_=client(False)
            proof['browser']=browser.version
            assert run(a,'probe.create()') and run(b,'probe.create()')
            assert run(a,'probe.encrypt()')['bytes']<8192 and run(a,'probe.roundtrip()')
            original=run(a,'probe.exportCipher()');assert len(original)>2048
            proof['checks']['real_library_virtual_prf_encrypt_decrypt']=True
            assert run(a,'probe.encrypt()');second=run(a,'probe.exportCipher()');assert original!=second
            proof['checks']['fresh_ciphertext_for_same_generated_bytes']=True
            assert denied(b,'probe.supplied('+json.dumps(second)+')')
            proof['checks']['other_virtual_credential_cannot_decrypt']=True
            bad=second.copy();bad[-1]^=1
            assert denied(a,'probe.supplied('+json.dumps(bad)+')')
            assert denied(a,'probe.supplied('+json.dumps(second[:-1])+')')
            assert run(a,'probe.supplied('+json.dumps(second)+')')
            proof['checks']['tamper_truncation_rejected_original_still_readable']=True
            assert run(a,'probe.saved()');a.reload()
            for _ in range(100):
                if a.evaluate('Boolean(window.probe)'):break
                a.wait_for_timeout(20)
            assert run(a,'probe.restored()')
            proof['checks']['ciphertext_and_credential_hint_reload_without_private_key_export']=True
            # Valid old whole-file replacement is deliberately accepted: this
            # library alone cannot provide a monotonic application-state witness.
            assert run(a,'probe.supplied('+json.dumps(original)+')')
            proof['checks']['valid_old_file_still_decrypts_no_antirollback_claim']=True
            assert denied(a,'probe.wrongRP()')
            proof['checks']['unrelated_rp_id_rejected']=True
            assert denied(c,'probe.create()')
            proof['checks']['no_prf_authenticator_rejected_without_fallback']=True
            capability=run(a,'probe.workerCapability()');assert capability=={'credentialsAvailable':False,'secureContext':True}
            proof['checks']['worker_credentials_api_unavailable_blocker']=True
            if args.uv_recovery_probe:
                cdp.send('WebAuthn.setUserVerified',{'authenticatorId':auth,'isUserVerified':False})
                outcome=run(a,"Promise.race([probe.roundtrip().then(()=> 'released',()=> 'denied'),new Promise(resolve=>setTimeout(()=>resolve('pending'),800))])")
                assert outcome in ('denied','pending')
                a.reload()  # Cancel the unavailable WebAuthn request; no reset or key generation.
                cdp.send('WebAuthn.setUserVerified',{'authenticatorId':auth,'isUserVerified':True})
                for _ in range(100):
                    if a.evaluate('Boolean(window.probe)'):break
                    a.wait_for_timeout(20)
                assert run(a,'probe.restored()')
                proof['checks']['unverified_authenticator_no_release_then_same_ciphertext_reopens']=True
                cdp.send('WebAuthn.clearCredentials',{'authenticatorId':auth})
                outcome=run(a,"Promise.race([probe.roundtrip().then(()=> 'released',()=> 'denied'),new Promise(resolve=>setTimeout(()=>resolve('pending'),800))])")
                assert outcome in ('denied','pending')
                a.reload()  # Retain ciphertext; no automatic credential replacement.
                proof['checks']['missing_authenticator_key_no_release_no_reenrollment']=True
            proof['timing_seconds']=round(time.monotonic()-start,3)
            proof['passed']=True
            for context in contexts:context.close()
            browser.close()
    finally:
        server.shutdown();server.server_close()
        path=out/'verification.json';path.write_text(json.dumps(proof,indent=2)+'\n');path.chmod(0o600);print(path)

if __name__=='__main__':main()
