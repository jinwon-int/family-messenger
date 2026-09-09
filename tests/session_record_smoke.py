#!/usr/bin/env python3
"""Generated symmetric record/root custody proof; no native profiles or humans."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import stat
import tempfile
import threading
import time
from password_worker_smoke import safe_bytes

ROOT=Path(__file__).resolve().parents[1]
CSP="default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--synthetic-only',action='store_true');args=parser.parse_args()
    assert args.synthetic_only,'generated-data acknowledgement required'
    from playwright.sync_api import sync_playwright
    artifacts=ROOT/'artifacts'
    for p in [artifacts,*artifacts.parents]:
        s=p.lstat();assert stat.S_ISDIR(s.st_mode) and not s.st_mode&0o022
    out=Path(tempfile.mkdtemp(prefix='session-record-',dir=artifacts));out.chmod(0o700)
    assets={'/':b'<!doctype html><meta charset="utf-8"><title>Synthetic session only</title><script type="module" src="/session-page.js"></script>'}
    for name,subdir in [('session-page.js',''),('session-worker.js','bundle')]:
        assets['/'+name]=safe_bytes(ROOT/'experiments/device-keystore'/subdir/name,2*1024*1024)
    inventory=json.loads(safe_bytes(ROOT/'experiments/device-keystore/session-inventory.json',65536))
    assert hashlib.sha256(assets['/session-worker.js']).hexdigest()==inventory['bundle']['sha256']
    proof={'synthetic_only':True,'native_integration':False,'human_key_protection':False,'checks':{},'asset_sha256':{k:hashlib.sha256(v).hexdigest() for k,v in assets.items()}}
    class Server(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_GET(self):
            host=f'localhost:{self.server.server_port}'
            if self.path not in assets or self.headers.get('Host')!=host or self.headers.get('Origin') not in (None,'http://'+host):self.send_error(403);return
            data=assets[self.path];self.send_response(200)
            for k,v in [('Content-Type','text/html; charset=utf-8' if self.path=='/' else 'text/javascript; charset=utf-8'),('Content-Length',str(len(data))),('Content-Security-Policy',CSP),('X-Content-Type-Options','nosniff'),('Cache-Control','no-store')]:self.send_header(k,v)
            self.end_headers();self.wfile.write(data)
    server=ThreadingHTTPServer(('127.0.0.1',0),Server);threading.Thread(target=server.serve_forever,daemon=True).start()
    password=secrets.token_urlsafe(32);begin=time.monotonic()
    try:
        with sync_playwright() as pw:
            browser=pw.chromium.launch();context=browser.new_context()
            def page():
                p=context.new_page();p.goto(f'http://localhost:{server.server_port}')
                for _ in range(100):
                    if p.evaluate('Boolean(window.sessionProbe)'):return p
                    p.wait_for_timeout(20)
                raise AssertionError('bootstrap')
            def start(p):
                r=p.evaluate('() => sessionProbe.start()');assert r.get('wasm') and r['heap']<=128*1024*1024,r
                return r
            def call(p,op,**args):return p.evaluate('x => sessionProbe.command(x)',{'op':op,**args})
            def seal(p,tag='FINAL',id='record-a',revision=1):return call(p,'seal',id=id,revision=revision,fixture_tag=tag)
            def read(p,record,id='record-a',revision=1):return call(p,'read',id=id,revision=revision,record=record)
            a=page();b=page();start(a);root=call(a,'create',password=password)
            assert set(root)=={'type','capsule','vault','ms','kdf'} and root['kdf']
            cipher=seal(a);assert not cipher['kdf'];record=cipher['record']
            opened=read(a,record);assert opened['matched'] and not opened['kdf'] and set(opened)=={'type','matched','ms','kdf'}
            status=call(a,'status');assert status['version']=='1.0.22' and status['heap']<=128*1024*1024
            proof['browser']=browser.version;proof['wasm_heap_bytes']=status['heap']
            proof['timings_ms']={'root_create':root['ms'],'first_seal':cipher['ms'],'first_read':opened['ms']}
            proof['checks']['actual_wasm_worker_root_capsule_and_authenticated_record']=True
            newer=seal(a)['record'];assert newer['header']!=record['header'] and newer['ciphertext']!=record['ciphertext']
            assert read(a,record)['matched']
            proof['checks']['fresh_headers_old_valid_record_still_readable_no_rollback_claim']=True
            times=[]
            for _ in range(8):
                c=seal(a);r=read(a,c['record']);assert r['matched'] and not c['kdf'] and not r['kdf'];times.append([c['ms'],r['ms']])
            proof['record_timings_ms']=times
            proof['checks']['unlocked_records_do_not_repeat_password_kdf']=True
            def reopen(p=None,root_value=root):
                if p is None: p=a
                start(p);r=call(p,'unlock',password=password,capsule=root_value['capsule'],vault=root_value['vault']);assert r.get('opened'),r
                return r
            proof['timings_ms']['root_unlock']=reopen()['ms']
            bad=call(a,'unlock',password=password,capsule=root['capsule'],vault=root['vault']);assert bad['denied']
            assert a.evaluate('sessionProbe.active()') is None
            proof['checks']['wrong_phase_retires_session']=True
            for id,rev in [('other-record',1),('record-a',2)]:
                reopen();assert read(a,record,id,rev)['denied'];assert a.evaluate('sessionProbe.active()') is None
            proof['checks']['independently_expected_id_revision_authenticated']=True
            for tag in ['MESSAGE','PUSH','REKEY']:
                reopen();partial=seal(a,tag)['record'];assert read(a,partial)['denied']
            proof['checks']['valid_nonfinal_tags_rejected']=True
            for which in ['header','ciphertext']:
                corrupt={k:v.copy() for k,v in record.items()};corrupt[which][-1]^=1
                reopen();assert read(a,corrupt)['denied']
            proof['checks']['header_and_payload_tamper_retires']=True
            for c in [record['ciphertext'][:-1],record['ciphertext']+[0],record['ciphertext']+newer['ciphertext']]:
                reopen();assert read(a,{'header':record['header'],'ciphertext':c})['denied']
            proof['checks']['truncated_appended_concatenated_records_denied']=True
            start(b);other=call(b,'create',password=password)
            assert read(b,record)['denied']
            start(a);assert call(a,'unlock',password=password,capsule=root['capsule'],vault=other['vault'])['denied']
            proof['checks']['wrong_root_key_and_expected_vault_denied']=True
            start(a);wrong=call(a,'unlock',password=secrets.token_urlsafe(32),capsule=root['capsule'],vault=root['vault']);assert wrong['denied']
            start(a);wire=bytes(root['capsule']);assert b' 18\n' in wire[:200]
            expensive=list(wire.replace(b' 18\n',b' 20\n',1))
            denied=call(a,'unlock',password=password,capsule=expensive,vault=root['vault']);assert denied=={'denied':True,'kdf':False}
            proof['checks']['capsule_password_and_work_admission_fail_closed']=True
            # Retirement must cancel a genuine in-flight KDF, not merely a timer.
            start(a)
            a.evaluate('x=>{window.pending=sessionProbe.command(x)}',{'op':'unlock','password':password,'capsule':root['capsule'],'vault':root['vault']})
            for _ in range(1000):
                if a.evaluate('sessionProbe.active()?.kdf === true'):break
                a.wait_for_timeout(2)
            assert a.evaluate('sessionProbe.active()?.kdf === true')
            b.evaluate('sessionProbe.lock()')
            assert a.evaluate('()=>window.pending')=={'denied':True,'locked':True,'kdf':True}
            assert a.evaluate('sessionProbe.active()') is None
            proof['checks']['cross_tab_lock_during_kdf_has_no_late_session']=True
            reopen()
            # The unlock counts as command1. Exactly32 commands allowed.
            for i in range(2,33):assert call(a,'status')['commands']==i
            assert a.evaluate('sessionProbe.active()') is None
            assert a.evaluate('async()=>{try{await sessionProbe.command({op: "status"});return false}catch{return true}}')
            proof['checks']['command_budget_retires_root_session']=True
            browser.close();browser=pw.chromium.launch();context=browser.new_context();a=page()
            reopen();assert read(a,record)['matched']
            proof['checks']['actual_browser_restart_reopens_retained_capsule_record']=True
            browser.close();proof['passed']=True
    finally:
        server.shutdown();server.server_close();proof['timing_seconds']=round(time.monotonic()-begin,3)
        path=out/'verification.json';path.write_text(json.dumps(proof,indent=2)+'\n');path.chmod(0o600);print(path)

if __name__=='__main__':main()
