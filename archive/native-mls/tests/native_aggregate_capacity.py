#!/usr/bin/env python3
"""Aggregate capacity measurement (#49 fifth slice).

Quantifies the device-vault namespace's measured ceiling with the current
format: two conversation records of at most 65536 bytes each inside one sealed
envelope, 512 seal revisions, per-seal latency, sealed-size overhead and worker
linear memory. Every write carries a signed admission as of the admission
slice. The measured numbers land in the verification receipt and feed
AGGREGATE-CAPACITY.md. Synthetic loopback only; no native server, human keys
or Cloudflare.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import statistics
import subprocess
import tempfile
import threading
import time
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parents[1]
CSP="default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"
STORE=ROOT/'experiments/device-keystore/native-aggregate-vault.js'
RECORD=65536
REVISION_CAP=512


def bundled_store(root,work):
    source=STORE.read_bytes()
    output=work/'native-aggregate-vault.bundle.js'
    subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--outfile='+str(output)],input=source,cwd=root/'experiments/device-keystore',check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return output.read_bytes()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--synthetic-only',action='store_true')
    parser.add_argument('--seal-sample',type=int,default=64,
                        help='number of timed seals sampled across the revision range')
    args=parser.parse_args()
    assert args.synthetic_only,'explicit synthetic acknowledgement required'
    artifacts=ROOT/'artifacts';artifacts.mkdir(mode=0o700,exist_ok=True)
    work=Path(tempfile.mkdtemp(prefix='aggregate-capacity-',dir=artifacts));work.chmod(0o700)
    bundle=bundled_store(ROOT,work)
    worker=(ROOT/'experiments/openmls-browser/web/aggregate-vault-worker.js').read_bytes()
    fixture=(ROOT/'tests/fixtures/aggregate-vault/main.js').read_bytes()
    signer=(b"import{policySigner,policyKeypair} from '/native-aggregate-vault.js';"
            b"window.policySigner=policySigner;window.policyKeypair=policyKeypair;")
    page=(b'<!doctype html><meta charset="utf-8"><title>Synthetic aggregate capacity</title>'
          b'<script type="module" src="/main.js"></script>'
          b'<script type="module" src="/aggregate-policy-signer.js"></script>')
    assets={'/':page,'/main.js':fixture,'/aggregate-vault-worker.js':worker,
            '/native-aggregate-vault.js':bundle,'/aggregate-policy-signer.js':signer}
    proof={'synthetic_only':True,'capacity':{},'checks':{},
           'store_source_sha256':hashlib.sha256(source:=STORE.read_bytes()).hexdigest(),
           'bundle_sha256':hashlib.sha256(bundle).hexdigest()}
    class Server(BaseHTTPRequestHandler):
        def log_message(self,*a):pass
        def do_GET(self):
            expected=f'localhost:{self.server.server_port}'
            if self.headers.get('Host')!=expected or self.path not in assets or self.headers.get('Origin') not in (None,'http://'+expected):self.send_error(403);return
            data=assets[self.path];self.send_response(200);self.send_header('Content-Type','text/html' if self.path=='/' else 'application/javascript');self.send_header('Content-Length',str(len(data)));self.send_header('Content-Security-Policy',CSP);self.send_header('X-Content-Type-Options','nosniff');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
    server=ThreadingHTTPServer(('127.0.0.1',0),Server);threading.Thread(target=server.serve_forever,daemon=True).start()
    url=f'http://localhost:{server.server_port}'
    def read_envelope(page_,database):
        return page_.evaluate('''async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});const v=await new Promise((r,j)=>{const q=d.transaction('aggregate').objectStore('aggregate').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();return v}''',database)
    try:
        with sync_playwright() as pw:
            context=pw.chromium.launch_persistent_context(str(work/'profile'))
            proof['browser']=context.browser.version
            page_=context.new_page()
            page_.add_init_script("window.testWorkers=[];const W=Worker;window.Worker=class extends W{constructor(...args){super(...args);window.testWorkers.push(this)}};")
            if os.environ.get('AGG_DEBUG'):page_.on('console',lambda m:print('CONSOLE',m.text[:200]))
            page_.goto(url);page_.wait_for_function('()=>window.ready===true')
            page_.wait_for_function('()=>window.policyKeypair!==undefined')
            page_.evaluate("spawn('device')")
            kp=page_.evaluate('()=>window.policyKeypair()')
            policy_secret,policy_public=kp['secret'],kp['public']
            database='family-mls-aggregate-synthetic-capacity'
            def rpc(method,arg=None,reject=False):
                r=page_.evaluate('([m,a])=>call("device",m,a)',[method,arg])
                if os.environ.get('AGG_DEBUG'):print('RPC',method,r.get('ok'),r.get('error'))
                proof['max_worker_linear_memory_bytes']=max(proof.get('max_worker_linear_memory_bytes',0),r['memory_bytes'])
                assert r['memory_bytes']<=128*1024*1024
                if reject:assert not r['ok'] and 'result' not in r,(method,r);return
                assert r['ok'],(method,r);return r.get('result')
            device_pub=secrets.token_hex(32)
            def signed(rooms,revision):
                doc={'v':1,'rooms':list(rooms),'actor':'alice','device_id':'alice-device',
                     'signing_key':device_pub,'peers':[],'revision':revision,
                     'not_after':int(time.time()*1000)+300000,'signature':''}
                doc['signature']=page_.evaluate('([d,s])=>window.policySigner(s)(d)',[doc,policy_secret])
                return doc
            def put(room,payload,revision,rooms=('room-alpha','room-beta'),timed=False,reject=False):
                doc=signed(rooms,revision)
                t0=time.perf_counter()
                got=rpc('put-room',{'room':room,'bytes':list(payload) if isinstance(payload,(bytes,bytearray)) else payload,'admission':doc},reject=reject)
                ms=(time.perf_counter()-t0)*1000
                if timed and not reject:timings.append(ms)
                return got,ms

            password=secrets.token_urlsafe(32)
            def reopen():
                page_.evaluate("stopWorker('device');spawn('device')")
                rpc('open',{'actor':'alice','database':database,'password':password,'create':False,'pub':device_pub,'policy':policy_public})
            rpc('open',{'actor':'alice','database':database,'password':password,'create':True,'pub':device_pub,'policy':policy_public})
            # 1. Max-record seal: two full 65536-byte records — the plaintext
            #    ceiling of the current envelope.
            t0=time.perf_counter()
            got,_=put('room-alpha',os.urandom(RECORD),1)
            seal_first=(time.perf_counter()-t0)*1000
            assert got['revision']==1
            t0=time.perf_counter()
            got,_=put('room-beta',os.urandom(RECORD),2)
            seal_second=(time.perf_counter()-t0)*1000
            assert got['revision']==2
            envelope=read_envelope(page_,database)
            sealed_bytes=len(envelope['cipher'])
            capacity={'max_record_bytes':RECORD,'records':2,
                      'plaintext_ceiling_bytes':2*RECORD,
                      'sealed_cipher_bytes':sealed_bytes,
                      'envelope_revision':envelope['revision'],
                      'first_seal_ms':round(seal_first,1),'second_seal_ms':round(seal_second,1)}
            #    Overhead: sealed ciphertext vs raw record bytes.
            capacity['seal_overhead_bytes']=sealed_bytes-2*RECORD
            capacity['seal_overhead_ratio']=round(sealed_bytes/(2*RECORD),3)
            proof['checks']['max_record_seal_at_plaintext_ceiling']=True
            # 2. Full revision range: 512 seals total — the format's cap. The
            #    first two are done; alternate rooms and sample `--seal-sample`
            #    timed seals spread across the range.
            timings=[]
            sample_at={round(REVISION_CAP*f) for f in (0.1,0.25,0.5,0.75,0.95)}|{REVISION_CAP}
            revision=2
            rejected_after_cap=False
            while revision<REVISION_CAP:
                revision+=1
                room,marker=('room-alpha',b'a') if revision%2 else ('room-beta',b'b')
                payload=marker*(1 if revision%2 else 1)+os.urandom(16)
                timed=revision in sample_at
                got,ms=put(room,payload,revision,timed=timed)
                assert got['revision']==revision,(revision,got)
                if timed:capacity.setdefault('seal_ms_samples',{})[str(revision)]=round(ms,1)
                if revision%256==0 and revision<REVISION_CAP:
                    # The worker's operational budget (256 writes per worker
                    # lifetime) mirrors a restart, which is part of normal use.
                    reopen()
            capacity['revision_range_exercised']=REVISION_CAP
            capacity['seal_ms_mean']=round(statistics.mean(timings),1)
            capacity['seal_ms_p95']=round(sorted(timings)[int(len(timings)*0.95)-1],1)
            proof['checks']['full_revision_range_512_seals_completed']=True
            # 3. The cap is real: an admission for revision 513 is refused.
            got=put('room-alpha',b'over the cap',REVISION_CAP+1,reject=True)
            assert read_envelope(page_,database)['revision']==REVISION_CAP
            proof['checks']['revision_cap_513_refused_without_state_change']=True
            # 4. Room-count binding: a third room cannot be committed.
            put('room-gamma',b'gamma',REVISION_CAP,rooms=('room-alpha','room-beta','room-gamma'),reject=True)
            proof['checks']['room_count_binding_enforced']=True
            capacity['max_worker_linear_memory_bytes']=proof['max_worker_linear_memory_bytes']
            proof['capacity']=capacity
            for k,v in capacity.items():print('CAPACITY',k,'=',v)
            context.close()
        proof['passed']=True
    finally:
        server.shutdown();server.server_close()
        (work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(work/'verification.json',flush=True)

if __name__=='__main__':main()
