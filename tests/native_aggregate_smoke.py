#!/usr/bin/env python3
"""Aggregate custody container qualification (#49): one sealed record, one strict CAS.

Synthetic generated conversation records only. No MLS provider binding, signed
admission, peer pins, human keys, Cloudflare or native server take part. Real
Chromium browser processes are SIGKILLed at commit boundaries to prove the
absence of torn state; every refusal must leave the committed record unchanged.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import tempfile
import threading
import time
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parents[1]
CSP="default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"
STORE=ROOT/'experiments/device-keystore/native-aggregate-vault.js'


def bundled_store(root,work):
    """Bundle the store twice: untouched original and instrumented proof build."""
    source=STORE.read_bytes()
    needle=b"if(after)s.put(after,'state');if(fault==='abort-after-write')"
    assert source.count(needle)==1
    instrumented=source.replace(needle,b"if(after)s.put(after,'state');if(fault==='crash-before-complete'){self.postMessage({test_crash_boundary:true});while(true){}}if(fault==='abort-after-write')")
    needle=b"await this.commit(before,after,fault,live);live();"
    assert instrumented.count(needle)==1
    instrumented=instrumented.replace(needle,needle+b"if(fault==='crash-after-commit'){self.postMessage({test_crash_boundary:true});while(true){}}")
    needle=b"const fresh=await admit();live();"
    assert instrumented.count(needle)==1
    instrumented=instrumented.replace(needle,b"if(after&&self.testHoldAggregateCAS){self.testHoldAggregateCAS=false;self.postMessage({test_aggregate_cas:true});await new Promise(resolve=>{self.testAggregateCASRelease=resolve;});}"+needle)
    needle=b"await this.lock('family-native-aggregate-kdf',async live=>{"
    assert instrumented.count(needle)==1
    instrumented=instrumented.replace(needle,b"self.postMessage({test_kdf_waiting:true});"+needle+b"self.postMessage({test_kdf_entered:true});if(self.testHoldAggregateKDF){self.testHoldAggregateKDF=false;await new Promise(resolve=>{self.testAggregateKDFRelease=resolve;});}")
    def build(name,raw):
        path=work/f'native-aggregate-vault-{name}.js';path.write_bytes(raw)
        output=work/f'native-aggregate-vault-{name}.bundle.js'
        subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=native-aggregate-vault.js','--outfile='+str(output)],input=raw,cwd=root/'experiments/device-keystore',check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        return output.read_bytes()
    numbered=instrumented
    if os.environ.get('AGG_DEBUG'):
        numbered=numbered.replace(b"const fail=()=>{throw Error('aggregate vault rejected')}",b"const fail=m=>{throw Error(m??'aggregate vault rejected')}")
        parts=numbered.split(b'fail()')
        numbered=b'fail("f0")'.join(parts[:1])+b''.join(b'fail("f%d")'%i+part for i,part in enumerate(parts[1:]))
    return build('original',source),build('instrumented',instrumented),build('numbered',numbered) if os.environ.get('AGG_DEBUG') else build('numbered',instrumented)


def main():
    p=argparse.ArgumentParser();p.add_argument('--synthetic-only',action='store_true');args=p.parse_args()
    assert args.synthetic_only,'explicit synthetic acknowledgement required'
    artifacts=ROOT/'artifacts';artifacts.mkdir(mode=0o700,exist_ok=True)
    work=Path(tempfile.mkdtemp(prefix='native-aggregate-',dir=artifacts));work.chmod(0o700)
    original,instrumented,served_store=bundled_store(ROOT,work)
    fixture=(ROOT/'tests/fixtures/aggregate-vault/main.js').read_bytes()
    worker=(ROOT/'experiments/openmls-browser/web/aggregate-vault-worker.js').read_bytes()
    page=b'<!doctype html><meta charset="utf-8"><title>Synthetic aggregate custody</title><script type="module" src="/main.js"></script>'
    needle=b"  if (data.id !== id) return;"
    assert fixture.count(needle)==1
    fixture=fixture.replace(needle,b"  if(data.test_crash_boundary)window.test_crash_boundary=true;if(data.test_aggregate_cas)window.test_aggregate_cas=true;\n"+needle)
    if os.environ.get('AGG_DEBUG'):
        worker=worker.replace(b".catch(()=>{retire();self.postMessage({id,ok:false,error:'refused',memory_bytes:0});});",
            b".catch(e=>{retire();self.postMessage({id,ok:false,error:String(e&&e.message||'refused'),memory_bytes:0});});")
    assets={'/':page,'/main.js':fixture,'/aggregate-vault-worker.js':worker,'/native-aggregate-vault.js':served_store}
    proof={'synthetic_only':True,'mls_provider_binding':False,'signed_admission':False,'native_server':False,
           'human_keys':False,'checks':{},
           'store_source_sha256':hashlib.sha256(source:=STORE.read_bytes()).hexdigest(),
           'original_bundle_sha256':hashlib.sha256(original).hexdigest(),
           'instrumented_bundle_sha256':hashlib.sha256(instrumented).hexdigest()}
    class Server(BaseHTTPRequestHandler):
        def log_message(self,*args_):pass
        def do_GET(self):
            expected=f'localhost:{self.server.server_port}'
            if self.headers.get('Host')!=expected or self.path not in assets or self.headers.get('Origin') not in (None,'http://'+expected):self.send_error(403);return
            data=assets[self.path];self.send_response(200);self.send_header('Content-Type','text/html' if self.path=='/' else 'application/javascript');self.send_header('Content-Length',str(len(data)));self.send_header('Content-Security-Policy',CSP);self.send_header('X-Content-Type-Options','nosniff');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
    server=ThreadingHTTPServer(('127.0.0.1',0),Server);threading.Thread(target=server.serve_forever,daemon=True).start()
    url=f'http://localhost:{server.server_port}'
    def read_record(page_,database,store='aggregate'):
        return page_.evaluate('''async ([name,store])=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});const v=await new Promise((r,j)=>{const q=d.transaction(store).objectStore(store).get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();return v}''',[database,store])
    def digest(page_,database,store='aggregate'):
        return page_.evaluate('''async ([name,store])=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});const v=await new Promise((r,j)=>{const q=d.transaction(store).objectStore(store).get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(JSON.stringify(v)))))}''',[database,store])
    try:
        with sync_playwright() as pw:
            profiles=[work/'alice-profile',work/'bob-profile']
            for profile in profiles:profile.mkdir(mode=0o700)
            contexts=[pw.chromium.launch_persistent_context(str(profile)) for profile in profiles]
            proof['browser']=contexts[0].browser.version;proof['max_worker_linear_memory_bytes']=0
            databases=['family-mls-aggregate-synthetic-alice','family-mls-aggregate-synthetic-bob']
            passwords=[secrets.token_urlsafe(32) for _ in range(2)]
            pubs=[secrets.token_hex(32) for _ in range(2)]
            def page(i):
                page_=contexts[i].new_page()
                page_.add_init_script("window.testWorkers=[];const W=Worker;window.Worker=class extends W{constructor(...args){super(...args);window.testWorkers.push(this)}};")
                page_.goto(url);page_.wait_for_function('()=>window.ready===true')
                page_.evaluate("spawn('device')")
                return page_
            def rpc(p_,method,arg=None,reject=False):
                r=p_.evaluate('([m,a])=>call("device",m,a)',[method,arg])
                proof['max_worker_linear_memory_bytes']=max(proof['max_worker_linear_memory_bytes'],r['memory_bytes'])
                assert r['memory_bytes']<=128*1024*1024
                if reject:assert not r['ok'] and 'result' not in r;return
                assert r['ok'],(method,r);return r.get('result')
            def open_args(i,database=None,create=False):
                return {'actor':['alice','bob'][i],'database':database or databases[i],'password':passwords[i],'create':create,'pub':pubs[i]}
            def reopen(p_,i,database=None):
                p_.evaluate("stopWorker('device');spawn('device')");rpc(p_,'open',open_args(i,database))
            def crash(i):
                session=contexts[i].browser.new_browser_cdp_session();pid=next(int(x['id']) for x in session.send('SystemInfo.getProcessInfo')['processInfo'] if x['type']=='browser')
                assert ('--user-data-dir='+str(profiles[i])).encode() in Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                os.kill(pid,signal.SIGKILL)
                try:contexts[i].close()
                except Exception:pass
                contexts[i]=pw.chromium.launch_persistent_context(str(profiles[i]))
            # Namespace creation seals on the first record; the envelope exposes
            # only sealed fields, never the record plaintext.
            a=page(0)
            rpc(a,'open',open_args(0,create=True))
            got=rpc(a,'put-room',{'room':'room-alpha','bytes':list(b'synthetic aggregate alpha')})
            assert got['revision']==1 and got['rooms']==[{'room':'room-alpha','bytes':25,'checksum':got['rooms'][0]['checksum']}]
            got=rpc(a,'put-room',{'room':'room-beta','bytes':list(b'synthetic aggregate beta')})
            assert got['revision']==2 and [x['room'] for x in got['rooms']]==['room-alpha','room-beta']
            envelope=read_record(a,databases[0])
            assert sorted(envelope)==['actor','capsule','cipher','header','revision','v','vault']
            assert 'records' not in envelope and envelope['v']==1 and len(envelope['header'])==24 and envelope['revision']==2
            proof['checks']['aggregate_envelope_exposes_only_sealed_fields']=True
            # An unchanged candidate is an exact retry: no re-seal, same bytes.
            sealed=digest(a,databases[0])
            got=rpc(a,'put-room',{'room':'room-beta','bytes':list(b'synthetic aggregate beta')})
            assert got['revision']==2 and digest(a,databases[0])==sealed
            proof['checks']['unchanged_candidate_exact_retry_without_reseal']=True
            got=rpc(a,'put-room',{'room':'room-beta','bytes':list(b'synthetic aggregate beta v2')})
            assert got['revision']==3;sealed=digest(a,databases[0])
            # Budget and shape refusals never mutate the committed record.
            rpc(a,'put-room',{'room':'room-gamma','bytes':[0]*65537},reject=True);reopen(a,0)
            rpc(a,'put-room',{'room':'room-gamma','bytes':[1]},reject=True);reopen(a,0)
            rpc(a,'put-room',{'room':'Room-Alpha','bytes':[1]},reject=True);reopen(a,0)
            rpc(a,'put-room',{'room':'room-alpha','bytes':[]},reject=True);reopen(a,0)
            assert digest(a,databases[0])==sealed
            proof['checks']['room_budget_shape_and_id_denials_never_mutate']=True
            # A directory-listed actor may not initialize another namespace.
            third=databases[0]+'-registered'
            a.evaluate("stopWorker('device');spawn('device')")
            rpc(a,'open',{'actor':'carol','database':third,'password':passwords[0],'create':True,'pub':pubs[0]})
            rpc(a,'put-room',{'room':'room-x','bytes':[1],'directory':{'devices':[{'actor':'carol'}]}},reject=True)
            assert read_record(a,third)['v']==0
            reopen(a,0)
            proof['checks']['registered_actor_namespace_init_denied']=True
            # Second device: isolated namespace, independent revisions.
            b=page(1);rpc(b,'open',open_args(1,create=True))
            got=rpc(b,'put-room',{'room':'room-bob','bytes':list(b'synthetic bob record')})
            assert got['revision']==1 and digest(b,databases[1])!=digest(a,databases[0])
            proof['checks']['per_device_namespaces_do_not_mix']=True
            # Two tabs of one device write through one serialized lock.
            tab=page(0);rpc(tab,'open',open_args(0))
            a.evaluate('arg=>{window.pending=call("device","put-room",arg)}',{'room':'room-alpha','bytes':list(b'synthetic tab-a variant')})
            tab.evaluate('arg=>{window.pending=call("device","put-room",arg)}',{'room':'room-beta','bytes':list(b'synthetic tab-b variant')})
            assert a.evaluate('()=>window.pending')['ok'] and tab.evaluate('()=>window.pending')['ok']
            assert digest(a,databases[0])==digest(tab,databases[0])
            assert rpc(tab,'put-room',{'room':'room-alpha','bytes':[7]})['revision']==6
            proof['checks']['cross_tab_writes_serialize_and_converge']=True
            reopen(a,0)
            # A concurrent external write wins; the staged candidate is discarded.
            # The bump is a synthetic conflicting writer: the exact pre-hold record
            # is restored afterwards, as the conflicting write itself is not a
            # valid sealed state (its revision field no longer matches the AAD).
            pre_hold=digest(a,databases[0]);revision_before_hold=read_record(a,databases[0])['revision']
            a.evaluate('''async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});window.savedAggregate=await new Promise((r,j)=>{const q=d.transaction('aggregate').objectStore('aggregate').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close()}''',databases[0])
            rpc(a,'test-aggregate-hold-cas')
            a.evaluate('arg=>{window.pending=call("device","put-room",arg).catch(()=>({ok:false}))}',{'room':'room-alpha','bytes':list(b'synthetic lost candidate')})
            a.wait_for_function('()=>window.test_aggregate_cas===true',timeout=5000)
            a.evaluate('''async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});await new Promise((r,j)=>{const t=d.transaction('aggregate','readwrite'),s=t.objectStore('aggregate'),q=s.get('state');q.onsuccess=()=>{const v=q.result;v.revision++;s.put(v,'state')};t.oncomplete=r;t.onabort=j});d.close()}''',databases[0])
            a.evaluate('window.testWorkers.at(-1).postMessage({test_aggregate_release:"cas"})')
            assert not a.evaluate('()=>window.pending')['ok']
            assert read_record(a,databases[0])['revision']==revision_before_hold+1
            a.evaluate('''async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});await new Promise((r,j)=>{const t=d.transaction('aggregate','readwrite');t.objectStore('aggregate').put(window.savedAggregate,'state');t.oncomplete=r;t.onabort=j});d.close()}''',databases[0])
            assert digest(a,databases[0])==pre_hold
            reopen(a,0)
            proof['checks']['strict_cas_preserves_concurrent_external_write']=True
            # Same-database corruption is denied at unlock, state preserved.
            before_corruption=digest(a,databases[0])
            for key in ('cipher','capsule'):
                a.evaluate('''async ([name,key])=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});window.savedAggregate=await new Promise((r,j)=>{const q=d.transaction('aggregate').objectStore('aggregate').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close()}''',[databases[0],key])
                a.evaluate('''async ([name,key])=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});await new Promise((r,j)=>{const t=d.transaction('aggregate','readwrite'),s=t.objectStore('aggregate'),q=s.get('state');q.onsuccess=()=>{const v=q.result;v[key][v[key].length-1]^=1;s.put(v,'state')};t.oncomplete=r;t.onabort=j});d.close()}''',[databases[0],key])
                rpc(a,'put-room',{'room':'room-alpha','bytes':[1]},reject=True)
                a.evaluate('''async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});await new Promise((r,j)=>{const t=d.transaction('aggregate','readwrite');t.objectStore('aggregate').put(window.savedAggregate,'state');t.oncomplete=r;t.onabort=j});d.close()}''',databases[0])
                reopen(a,0)
            assert digest(a,databases[0])==before_corruption
            proof['checks']['same_namespace_capsule_and_cipher_corruption_denied']=True
            # A record cloned under another database name is refused by binding.
            a.evaluate("stopWorker('device');spawn('device')")
            swapped=databases[0]+'-swapped'
            a.evaluate('''async ([source,target])=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(source);q.onsuccess=()=>r(q.result);q.onerror=j});const rec=await new Promise((r,j)=>{const q=d.transaction('aggregate').objectStore('aggregate').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();await new Promise((r,j)=>{const q=indexedDB.open(target,1);q.onupgradeneeded=()=>q.result.createObjectStore('aggregate').add(rec,'state');q.onsuccess=()=>{q.result.close();r()};q.onerror=j})}''',[databases[0],swapped])
            rpc(a,'open',{'actor':'alice','database':swapped,'password':passwords[0],'create':False,'pub':pubs[0]})
            before_swap=digest(a,swapped)
            rpc(a,'put-room',{'room':'room-alpha','bytes':[1]},reject=True)
            assert digest(a,swapped)==before_swap;reopen(a,0)
            proof['checks']['record_swapped_across_database_names_denied']=True
            # SIGKILL between the write and the commit event: old or new, never torn.
            before=digest(a,databases[0]);revision_before=read_record(a,databases[0])['revision']
            a.evaluate('arg=>{window.pending=call("device","put-room",arg).catch(()=>({ok:false}))}',{'room':'room-beta','bytes':list(b'synthetic crashed variant'),'fault':'crash-before-complete'})
            try:
                a.wait_for_function('()=>window.test_crash_boundary===true',timeout=5000)
            except Exception:
                print('DBG pending:',a.evaluate('async()=>window.pending&&(window.pending.then?await window.pending:window.pending)'))
                print('DBG boundary:',a.evaluate('Boolean(window.test_crash_boundary)'))
                print('DBG workers:',a.evaluate('window.testWorkers.length'))
                raise
            crash(0);a=page(0);reopen(a,0)
            revision_after=read_record(a,databases[0])['revision']
            assert revision_after in (revision_before,revision_before+1)
            got=rpc(a,'put-room',{'room':'room-beta','bytes':list(b'synthetic crashed variant')})
            assert got['revision']==revision_before+1
            proof['checks']['browser_sigkill_at_commit_boundary_never_tears_state']=True
            # A committed result whose reply was lost retries exactly once, in place.
            before=digest(a,databases[0]);revision_before=read_record(a,databases[0])['revision']
            a.evaluate('arg=>{window.pending=call("device","put-room",arg).catch(()=>({ok:false}))}',{'room':'room-alpha','bytes':list(b'synthetic lost reply variant'),'fault':'crash-after-commit'})
            a.wait_for_function('()=>window.test_crash_boundary===true',timeout=5000)
            crash(0);a=page(0);reopen(a,0)
            committed=digest(a,databases[0])
            assert committed!=before and read_record(a,databases[0])['revision']==revision_before+1
            got=rpc(a,'put-room',{'room':'room-alpha','bytes':list(b'synthetic lost reply variant')})
            assert got['revision']==revision_before+1 and digest(a,databases[0])==committed
            proof['checks']['lost_reply_after_commit_exact_retry_without_double_advance']=True
            # The old single-room profile namespace is foreign and untouched.
            sentinel='family-mls-vault-synthetic-preserve'
            a.evaluate('''async name=>{await new Promise((r,j)=>{const q=indexedDB.open(name,1);q.onupgradeneeded=()=>q.result.createObjectStore('device').add({sentinel:'family-single-room-profile',blob:[1,2,3]},'state');q.onsuccess=()=>{q.result.close();r()};q.onerror=j})}''',sentinel)
            before=digest(a,sentinel,store='device')
            rpc(a,'put-room',{'room':'room-alpha','bytes':list(b'synthetic unrelated work')})
            rpc(a,'put-room',{'room':'room-alpha','bytes':[9]});reopen(a,0)
            rpc(a,'put-room',{'room':'room-alpha','bytes':[10]})
            assert digest(a,sentinel,store='device')==before
            proof['checks']['foreign_single_room_profile_untouched']=True
            for context in contexts:context.close()
        proof['passed']=True
    finally:
        server.shutdown();server.server_close()
        (work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(work/'verification.json',flush=True)

if __name__=='__main__':main()
