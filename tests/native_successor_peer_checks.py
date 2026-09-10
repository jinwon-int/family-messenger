"""Actual generated native pair -> retired peer -> restricted encrypted custody.

Original bundle and served-only instrumentation have distinct recorded hashes.
No candidate activation, human migration, or compiled product asset claim.
"""
import copy
import hashlib
import json
import os
import subprocess
import time
from password_worker_smoke import safe_bytes


def successor_assets(root, work, assets, proof, original_only=False):
    cwd = root / 'experiments/device-keystore'
    source = safe_bytes(cwd / 'successor-peer-store.js', 65536)
    def build(raw, name):
        result = subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify',
            '--sourcefile=successor-peer-store.js','--external:/pkg/*','--external:/trust-directory.js'],input=raw,cwd=cwd,check=True,capture_output=True)
        fd=os.open(work/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(result.stdout);f.flush();os.fsync(f.fileno())
        return result.stdout
    original=build(source,'successor-peer-original.js')
    # Test-only worker-private source checksum; never expose provider bytes.
    source=source.replace(b'{fresh,publicKey}',b'{fresh,publicKey,checksum as testChecksum}')
    needle=b'if(validatePeer(a,this.identity,expected)!==this.root.pub)fail();candidate=encode(a);'
    assert source.count(needle)==1
    source=source.replace(needle,b"if(self.testExtraTarget){const target=a.rooms[1],snapshot=JSON.parse(dec.decode(target.crypto));snapshot.entries.push([[253,252,251],[1]]);target.crypto=enc.encode(JSON.stringify(snapshot));target.checksum=testChecksum(target);}"+needle)

    needle=b'candidate=encode(a);this.maxSerialized=candidate.length;'
    assert source.count(needle)==1
    source=source.replace(needle,needle+b"self.testSourceDigest=sodium.to_hex(sodium.crypto_generichash(32,enc.encode(JSON.stringify({...a.rooms[0],crypto:b64(a.rooms[0].crypto)}))));")
    needle=b"await this.commit(before,after,'',live);"
    assert source.count(needle)==1
    source=source.replace(needle,b"if(self.testHold){self.postMessage({test_successor_boundary:true});await new Promise(r=>self.testRelease=r);}await this.commit(before,after,self.testFault??'',live);")
    source=source.replace(b"this.root.seen=(after??before).revision;",b"this.root.seen=(after??before).revision;if(self.testLostReply){self.postMessage({test_successor_boundary:true});await new Promise(()=>{});}")
    # Hold an actual pending IDB transaction for owned-browser SIGKILL.
    source=source.replace(b'export class SuccessorPeerStore extends AggregateStore {',b'''export class SuccessorPeerStore extends AggregateStore {
 commit(before,after,fault,live){if(!self.testCrash)return super.commit(before,after,fault,live);return new Promise(()=>{const t=this.db.transaction('device','readwrite',{durability:'strict'}),s=t.objectStore('device');this.transactions.add(t);const q=s.get('state');q.onsuccess=()=>{live();if(!this.equal(before,q.result)){t.abort();return;}s.put(after,'state');self.postMessage({test_successor_boundary:true});while(true){}};});}
''')
    assets['/successor-peer-store.js']=build(source,'successor-peer-instrumented.js')
    worker=safe_bytes(root/'experiments/openmls-browser/web/successor-peer-worker.js',65536)
    worker=worker.replace(b"self.onmessage=async({data})=>{",b"self.onmessage=async({data})=>{if(data?.testRelease){self.testRelease?.();return;}if(data?.testSetup){Object.assign(self,data.testSetup);return;}")
    worker=worker.replace(b'self.postMessage({id,ok:true,result,memory_bytes:memory});',b'self.postMessage({id,ok:true,result:{...result,test_source_digest:self.testSourceDigest},memory_bytes:memory});')
    worker=worker.replace(b'}catch(_){close();self.postMessage({id,ok:false,memory_bytes:0});',b'}catch(error){close();self.postMessage({id,ok:false,memory_bytes:0,test_error:String(error?.stack)});')
    assets['/successor-peer-worker.js']=worker
    assets['/main.js']=assets['/main.js'].replace(b"name==='fork'?'./aggregate-fork-worker.js'",b"name==='fork'?'./successor-peer-worker.js'")
    assets['/main.js']=assets['/main.js'].replace(b"||method==='fork'",b"||method==='fork'||method==='successor'")
    assets['/main.js']=assets['/main.js'].replace(b'    if (data.id !== id) return;',b'    if(data.test_successor_boundary)window.test_successor_boundary=true;\n    if (data.id !== id) return;')
    if original_only:
        assets['/successor-peer-store.js']=original
        assets['/successor-peer-worker.js']=safe_bytes(root/'experiments/openmls-browser/web/successor-peer-worker.js',65536)
    proof['successor_original_only']=original_only
    proof['successor_bundles']={'original_sha256':hashlib.sha256(original).hexdigest(),'served_instrumented_sha256':hashlib.sha256(assets['/successor-peer-store.js']).hexdigest(),'bytes':len(original)}


def run(a,b,databases,rpc,init,reopen,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,tamper,restart,original_only=False):
    group=rpc(a,'status')['group_id']
    prepare(a,'app-history',b'generated prior history');rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
    prepare(b,'app-small-file',bytes(range(256))*32,'file');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync')
    rpc(a,'update',{'id':'update-retained','fault':''})
    source=rpc(a,'test-aggregate-digest')[0]
    assert source['pending']=='update-retained'
    a.evaluate("stopWorker('device')");b.evaluate("stopWorker('device')")
    before=digest(a,0);bob_before=digest(b,1)
    now=int(time.time());old=config['devices'][1];public=bytes([19])*32
    config['version']=2
    admin={'subject':'owner','actor':'alice'}
    config['successors']={'administrators':[admin],'intents':[]};commit(2,config['people'])
    intent={'intent_id':'replace-bob','action':'replace','actor':'bob','subject':'family','predecessor':old['device_id'],'predecessor_key':old['signing_key'],'predecessor_revision':1,
        'candidate':'bob-candidate','signing_key':public.hex(),'fingerprint':hashlib.sha256(public).hexdigest(),'package_sha256':hashlib.sha256(b'generated unactivated candidate package reference').hexdigest(),
        'previous_room':'family','previous_group':group,'next_room':'successor-room','administrator':admin,'acceptance':'out-of-band-fingerprint',
        'base_revision':3,'created_at':now-1,'expires_at':now+850,'status':'candidate','decided_at':0,'decision_revision':0}
    config['successors']['intents']=[intent];commit(3,config['people'])
    intent.update(status='accepted',decided_at=int(time.time()),decision_revision=5);old.update(status='revoked',device_revision=2);commit(4,config['people'])
    path='/v1/mls/successors/replace-bob/reservation'
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        code,c=direct('owner','GET','/v1/mls/successors/replace-bob/context')
        if code==200:break
        time.sleep(.05)
    else:raise AssertionError('accepted context reload')
    q={'reservation_id':'shared-peer-test','context_sha256':hashlib.sha256(json.dumps(c,separators=(',',':')).encode()).hexdigest()}
    code,expected=direct('owner','POST',path,q);assert code==201,(code,expected)
    assert expected['context']['peer']['signing_key']==pins[0]['signing_key']
    assert direct('owner','GET','/v1/mls/rooms/family/log')[0]==403
    proof['checks']['real_pair_text_8192file_pending_rekey_retirement_and_inactive_reservation']=True

    def argument(value=None,password=None,identity='alice',database=None):
        return {'identity':identity,'database':database or databases[0],'password':password or passwords[0],
                'intent':{'accepted':True,'reservation':copy.deepcopy(expected if value is None else value)}}
    def start(p,arg=None,setup=None):
        p.evaluate("async()=>{stopWorker('fork');window.test_successor_boundary=false;await spawn('fork')}")
        if setup:p.evaluate('s=>window.testWorkers.at(-1).postMessage({testSetup:s})',setup)
        p.evaluate('arg=>{window.successorResult=call("fork","successor",arg)}',arg or argument())
    def finish(p,reject=False):
        r=p.evaluate('window.successorResult')
        if reject:assert not r['ok'] and 'result' not in r;return r
        assert r['ok'],r
        proof['max_worker_linear_memory_bytes']=max(proof['max_worker_linear_memory_bytes'],r['memory_bytes'])
        return r['result']
    def call(p,arg=None,reject=False,setup=None):start(p,arg,setup);return finish(p,reject)
    # Independently expected pins are not populated from the response in product
    # code. Here the generated fixture owns all source and proposed public values.
    for field,value in [('reservation_id','other-id'),('phase','ready')]:
        bad=copy.deepcopy(expected);bad[field]=value;call(a,argument(bad),True)
    for field,value in [('target_room','wrong-room'),('source_group','ad'*32),('intent_id','wrong-intent'),('package_sha256','aa'*32)]:
        bad=copy.deepcopy(expected);bad['context'][field]=value;call(a,argument(bad),True)
    call(a,argument(identity='bob'),True)
    bad=argument();bad['intent']['accepted']=False;call(a,bad,True)
    call(a,argument(password='W'*48),True)
    call(a,argument(database='family-mls-device-vault-synthetic-missing'),True)
    assert digest(a,0)==before
    proof['checks']['wrong_identity_missing_state_password_intent_pins_and_acceptance_deny_unchanged']=True
    for mode in ('invalid-json','oversize','wrong-header','wrong-phase'):
        hook={'context':mode,'path':path,'seen':0};tamper[0]=hook
        try:denied=call(a,reject=True)
        finally:tamper[0]=None
        assert hook['seen']==1 and digest(a,0)==before,(mode,hook['seen'],denied)
    proof['checks']['bounded_fresh_signed_reservation_no_directory_fallback']=True
    if original_only:
        result=call(a);assert result['committed'] and bytes(result['public_key']).hex()==pins[0]['signing_key']
        stable=digest(a,0);assert stable!=before and digest(b,1)==bob_before
        crash(0);a=page(0);restart();assert call(a)==result and digest(a,0)==stable
        assert direct('owner','GET','/v1/mls/rooms/successor-room/log')[0]==403
        proof['checks']['uninstrumented_original_bundle_first_transition_restart_exact_retry_inactive']=True
        proof['boundary']='Original unchanged worker and bundle, synthetic peer custody only; not candidate private-key possession or delivery'
        return
    call(a,reject=True,setup={'testExtraTarget':True});assert digest(a,0)==before
    proof['checks']['target_requires_exact_library_signer_only_snapshot_not_empty_group_label']=True
    start(a,setup={'testHold':True});a.wait_for_function('()=>window.test_successor_boundary===true',timeout=15000)
    a.evaluate("stopWorker('fork')");finish(a,True);assert digest(a,0)==before
    # A retired caller cannot publish a late staged result or commit.
    a.evaluate('()=>{try{window.testWorkers.at(-1).postMessage({testRelease:true})}catch{}}')
    assert digest(a,0)==before
    proof['checks']['lock_retires_held_candidate_no_late_output_or_write']=True
    start(a,setup={'testHold':True});a.wait_for_function('()=>window.test_successor_boundary===true',timeout=15000)
    a.evaluate("""async n=>{const q=indexedDB.open(n);await new Promise(r=>q.onsuccess=r);const d=q.result;await new Promise(r=>{const t=d.transaction('device','readwrite');t.objectStore('device').put('generated conflict','test-conflict');t.oncomplete=r});d.close()}""",databases[0])
    a.evaluate('()=>window.testWorkers.at(-1).postMessage({testRelease:true})');finish(a,True)
    assert digest(a,0)==before
    retained=a.evaluate("""async n=>{const q=indexedDB.open(n);await new Promise(r=>q.onsuccess=r);const d=q.result;const value=await new Promise(r=>{const q=d.transaction('device').objectStore('device').get('test-conflict');q.onsuccess=()=>r(q.result)});d.close();return value}""",databases[0])
    assert retained=='generated conflict'
    # Test fixture only: remove exactly its own injected key to continue probes.
    a.evaluate("""async n=>{const q=indexedDB.open(n);await new Promise(r=>q.onsuccess=r);const d=q.result;await new Promise(r=>{const t=d.transaction('device','readwrite');t.objectStore('device').delete('test-conflict');t.oncomplete=r});d.close()}""",databases[0])
    proof['checks']['late_idb_conflict_retained_candidate_discarded_before_output']=True
    for fault in ('abort-before-write','abort-after-write'):
        call(a,reject=True,setup={'testFault':fault});assert digest(a,0)==before
    proof['checks']['aborted_candidate_never_changes_source_or_releases_success']=True
    start(a,setup={'testCrash':True});a.wait_for_function('()=>window.test_successor_boundary===true',timeout=15000)
    crash(0);a=page(0);assert digest(a,0)==before
    proof['checks']['owned_browser_sigkill_pending_idb_transaction_preserves_exact_prior_cipher']=True
    # One committed result is deliberately not returned; retry after actual
    # browser death must reconcile the exact encrypted state, without another seal.
    start(a,setup={'testLostReply':True});a.wait_for_function('()=>window.test_successor_boundary===true',timeout=15000)
    committed=digest(a,0);assert committed!=before
    crash(0);a=page(0);result=call(a);assert digest(a,0)==committed
    assert result['phase']=='inactive-peer-custody' and bytes(result['public_key']).hex()==pins[0]['signing_key']
    assert result['test_source_digest']==source['digest'] and digest(b,1)==bob_before
    assert call(a)==result and digest(a,0)==committed
    proof['checks']['lost_reply_sigkill_exact_retry_same_signer_full_old_record_pending_unchanged']=True
    # Two callers serialize on the same device; both observe one committed slot.
    tab=page(0);start(a);start(tab);assert finish(a)==finish(tab)==result
    assert digest(a,0)==committed
    restart();assert call(a)==result and digest(a,0)==committed
    proof['checks']['cross_tab_and_server_restart_exact_committed_retry_no_second_write']=True
    # Older v1 driver is deliberately unable to reinterpret this explicitly
    # selected v2 state. The revoked old-room guard also remains intact.
    init(a,0,reject=True);assert digest(a,0)==committed
    assert direct('owner','GET','/v1/mls/rooms/successor-room/log')[0]==403
    assert direct('owner','POST','/v1/mls/rooms',{'room':'successor-room','group_id':'ba'*32,'device_id':'alice-first','peer_device':'bob-candidate'})[0]==403
    proof['checks']['no_old_native_resume_target_delivery_or_candidate_activation']=True
    # Corruption is retained; never recover by generating new keys or rewriting.
    tab.evaluate('''async n=>{const q=indexedDB.open(n);await new Promise(r=>q.onsuccess=r);const d=q.result;await new Promise(r=>{const t=d.transaction('device','readwrite'),s=t.objectStore('device'),g=s.get('state');g.onsuccess=()=>{g.result.cipher[0]^=1;s.put(g.result,'state')};t.oncomplete=r});d.close()}''',databases[0])
    corrupt=digest(a,0);call(a,reject=True);assert digest(a,0)==corrupt
    proof['checks']['corrupt_cipher_retained_no_regeneration_or_plaintext_fallback']=True
    config['devices'][0].update(status='revoked',device_revision=2);commit(5,config['people'])
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        if direct('owner','GET',path)[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('peer revocation reload')
    call(a,reject=True);assert digest(a,0)==corrupt
    proof['checks']['revoked_peer_denied_before_unlock_no_state_reset']=True
    proof['boundary']='Intact peer only, original generated pair with synthetic candidate PUBLIC declaration; no candidate private custody, new group, activation, product UI or human recovery'
