"""Generated signed native pair and isolated candidate proposal custody.

Extra lifecycle hooks are served-only fixtures, with original hashes recorded.
"""
import copy
import hashlib
import json
import os
import subprocess
import time
from password_worker_smoke import safe_bytes


def candidate_assets(root, work, assets, proof, original_only=False):
    cwd=root/'experiments/device-keystore'
    source=safe_bytes(cwd/'candidate-store.js',65536)
    def build(raw,name):
        r=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=candidate-store.js','--external:/pkg/*','--external:/trust-directory.js'],input=raw,cwd=cwd,check=True,capture_output=True)
        assert len(r.stdout)<1024*1024
        fd=os.open(work/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(r.stdout);f.flush();os.fsync(f.fileno())
        return r.stdout
    original=build(source,'candidate-original.js')
    # Fixtures only: prove retained private package consumes its exact Welcome.
    source=source.replace(b'staged_init,staged_apply,',b'staged_init,staged_trusted_apply,staged_epoch,staged_apply,',1)
    source=source.replace(b'privateRecord=r;',b'''privateRecord=r;
   if(self.testContinuity){
    const peer=r.identity==='bob'?'alice':'bob',p=staged_init(peer),key=staged_public_key(p,peer),pub=staged_public_key(r.crypto,r.identity);let a,w,j;
    try{a=staged_trusted_apply(p,peer,'create',new Uint8Array(),r.identity,pub);w=staged_trusted_apply(a.state(),peer,'invite',unhex(r.package),r.identity,pub);j=staged_trusted_apply(r.crypto,r.identity,'join',w.output(),peer,key);
     if(hex(staged_public_key(j.state(),r.identity))!==hex(pub)||hex(staged_group_id(j.state(),r.identity))!==hex(staged_group_id(w.state(),peer))||staged_epoch(j.state(),r.identity)!=='1')fail();self.testContinuityPassed=true;
    }finally{p.fill(0);a?.free();w?.free();j?.free();}
   }''',1)
    source=source.replace(b'export class CandidateStore extends NativeVaultStore {',b'''export class CandidateStore extends NativeVaultStore {
 async commit(before,after,fault,live){
  if(self.testHold){self.postMessage({test_candidate_boundary:true});await new Promise(r=>self.testRelease=r);}
  if(self.testCrash)return new Promise(()=>{const t=this.db.transaction('device','readwrite',{durability:'strict'}),s=t.objectStore('device');this.transactions.add(t);const q=s.get('state');q.onsuccess=()=>{live();if(!this.equal(before,q.result)){t.abort();return;}s.put(after,'state');self.postMessage({test_candidate_boundary:true});while(true){}};});
  await super.commit(before,after,self.testFault??fault,live);
  if(self.testLostReply){self.postMessage({test_candidate_boundary:true});await new Promise(()=>{});}
 }
''')
    assets['/candidate-store.js']=original if original_only else build(source,'candidate-instrumented.js')
    worker=safe_bytes(root/'experiments/openmls-browser/web/candidate-worker.js',65536)
    if not original_only:
        worker=worker.replace(b'self.onmessage=async({data})=>{',b'self.onmessage=async({data})=>{if(data?.testRelease){self.testRelease?.();return;}if(data?.testSetup){Object.assign(self,data.testSetup);return;}')
        worker=worker.replace(b'result,memory_bytes:memory',b'result:{...result,test_continuity:self.testContinuityPassed===true},memory_bytes:memory')
    assets['/candidate-worker.js']=worker
    assets['/main.js']=assets['/main.js'].replace(b"name==='fork'?'./aggregate-fork-worker.js'",b"name==='fork'?'./candidate-worker.js'")
    assets['/main.js']=assets['/main.js'].replace(b"||method==='fork'",b"||method==='fork'||(name==='fork'&&(method==='proposal'||method==='bind'))")
    assets['/main.js']=assets['/main.js'].replace(b'    if (data.id !== id) return;',b'    if(data.test_candidate_boundary)window.test_candidate_boundary=true;\n    if (data.id !== id) return;')
    proof['candidate_original_only']=original_only
    proof['candidate_bundles']={'original_sha256':hashlib.sha256(original).hexdigest(),'served_sha256':hashlib.sha256(assets['/candidate-store.js']).hexdigest(),'bytes':len(original)}


def run(a,b,databases,rpc,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,tamper,restart,original_only=False):
    group=rpc(a,'status')['group_id']
    prepare(a,'app-prior-text',b'generated old conversation');rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
    prepare(b,'app-prior-file',bytes(range(256))*32,'file');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync')
    rpc(a,'update',{'id':'update-old-pending','fault':''})
    a.evaluate("stopWorker('device')");b.evaluate("stopWorker('device')")
    source=[digest(a,0),digest(b,1)]
    database='family-mls-candidate-synthetic-bob-proposal'
    def argument(create=False,identity='bob',db=None):return {'identity':identity,'database':db or database,'password':passwords[1],'create':create}
    def start(p,method,arg,setup=None):
        p.evaluate("async()=>{stopWorker('fork');window.test_candidate_boundary=false;await spawn('fork')}")
        if setup:p.evaluate('s=>window.testWorkers.at(-1).postMessage({testSetup:s})',setup)
        p.evaluate('([m,arg])=>{window.candidateResult=call("fork",m,arg)}',[method,arg])
    def finish(p,reject=False):
        r=p.evaluate('window.candidateResult')
        if reject:assert not r['ok'] and 'result' not in r;return r
        assert r['ok'],r
        proof['max_worker_linear_memory_bytes']=max(proof['max_worker_linear_memory_bytes'],r['memory_bytes'])
        return r['result']
    def call(p,method,arg,setup=None,reject=False):start(p,method,arg,setup);return finish(p,reject)
    def state():return digest(b,1,database=database)
    call(a,'proposal',argument(True),reject=True)
    call(b,'proposal',argument(False,db=database+'-missing'),reject=True)
    for arg in ({**argument(True),'create':'true'},{**argument(True),'identity':'charlie'},{**argument(True),'password':'short'},{**argument(True),'candidate_id':'already-enrolled'}):
        call(b,'proposal',arg,reject=True)
    proof['checks']['proposal_has_no_enrolled_id_override_and_strict_bounded_arguments']=True
    proposal=call(b,'proposal',argument(True))
    assert proposal['phase']=='unassigned-proposal' and proposal['reservation_id'] is None
    assert hashlib.sha256(bytes.fromhex(proposal['package'])).hexdigest()==proposal['package_sha256']
    before=state();call(b,'proposal',argument(True),reject=True);assert state()==before
    assert call(b,'proposal',argument())==proposal and state()==before
    crash(1);b=page(1);assert call(b,'proposal',argument())==proposal and state()==before
    proof['checks']['actual_signed_proposal_commit_package_hash_restart_exact_retry_no_regeneration']=True
    # No plaintext provider/signer or password in the durable outer record.
    shape=b.evaluate("""async name=>{const d=await new Promise(r=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result)});const s=await new Promise(r=>{const q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result)});d.close();return {keys:Object.keys(s).sort(),cipher:s.cipher.length,capsule:s.capsule.length}}""",database)
    assert shape['keys']==sorted(['v','identity','room','vault','revision','capsule','header','cipher']) and shape['cipher']>1000 and shape['capsule']<8192
    proof['checks']['encrypted_outer_only_public_result_no_private_provider_page_output']=True
    if not original_only:
        result=call(b,'proposal',argument(),{'testContinuity':True});assert result['test_continuity'] and state()==before
        proof['checks']['saved_actual_package_provider_consumes_exact_welcome_after_browser_restart_without_persisting_group']=True
    now=int(time.time());old=config['devices'][1];config['version']=2;admin={'subject':'owner','actor':'alice'}
    config['successors']={'administrators':[admin],'intents':[]};commit(2,config['people'])
    intent={'intent_id':'replace-bob','action':'replace','actor':'bob','subject':'family','predecessor':old['device_id'],'predecessor_key':old['signing_key'],'predecessor_revision':1,
            'candidate':'bob-candidate','signing_key':proposal['public_key'],'fingerprint':hashlib.sha256(bytes.fromhex(proposal['public_key'])).hexdigest(),'package_sha256':proposal['package_sha256'],
            'previous_room':'family','previous_group':group,'next_room':'successor-room','administrator':admin,'acceptance':'out-of-band-fingerprint','base_revision':3,'created_at':now-1,'expires_at':now+850,'status':'candidate','decided_at':0,'decision_revision':0}
    config['successors']['intents']=[intent];commit(3,config['people'])
    intent.update(status='accepted',decided_at=int(time.time()),decision_revision=5);old.update(status='revoked',device_revision=2);commit(4,config['people'])
    path='/v1/mls/successors/replace-bob/reservation'
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        code,c=direct('owner','GET','/v1/mls/successors/replace-bob/context')
        if code==200:break
        time.sleep(.05)
    else:raise AssertionError('accepted context reload')
    code,expected=direct('owner','POST',path,{'reservation_id':'candidate-reservation','context_sha256':hashlib.sha256(json.dumps(c,separators=(',',':')).encode()).hexdigest()});assert code==201
    def binding(value=None,db=None):return {'identity':'bob','database':db or database,'password':passwords[1],'intent':{'accepted':True,'reservation':copy.deepcopy(expected if value is None else value)}}
    call(b,'bind',binding(db=database+'-missing'),reject=True)
    wrong=binding();wrong['password']='w'*48;call(b,'bind',wrong,reject=True)
    for field,value in [('target_room','wrong-room'),('package_sha256','ad'*32),('expires_at',1)]:
        bad=copy.deepcopy(expected);bad['context'][field]=value;call(b,'bind',binding(bad),reject=True)
    call(a,'bind',binding(),reject=True);assert state()==before
    other=database+'-different-key'
    other_proposal=call(b,'proposal',argument(True,db=other))
    assert other_proposal['public_key']!=proposal['public_key']
    call(b,'bind',binding(db=other),reject=True)
    proof['checks']['independent_candidate_actor_key_package_reservation_required_missing_state_never_created']=True
    for mode in ('invalid-json','oversize','wrong-phase'):
        hook={'context':mode,'path':path,'seen':0};tamper[0]=hook
        try:call(b,'bind',binding(),reject=True)
        finally:tamper[0]=None
        assert hook['seen']==1 and state()==before
    proof['checks']['bounded_signed_candidate_admission_no_directory_or_fixture_fallback']=True
    if not original_only:
        start(b,'bind',binding(),{'testHold':True});b.wait_for_function('()=>window.test_candidate_boundary===true',timeout=15000)
        b.evaluate("stopWorker('fork')");finish(b,True);assert state()==before
        proof['checks']['lock_retires_before_commit_no_late_success']=True
        start(b,'bind',binding(),{'testHold':True});b.wait_for_function('()=>window.test_candidate_boundary===true',timeout=15000)
        b.evaluate("""async name=>{const d=await new Promise(r=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result)});await new Promise(r=>{const t=d.transaction('device','readwrite');t.objectStore('device').put('generated-conflict','test-conflict');t.oncomplete=r});d.close()}""",database)
        b.evaluate('()=>window.testWorkers.at(-1).postMessage({testRelease:true})');finish(b,True)
        assert state()==before
        retained=b.evaluate("""async name=>{const d=await new Promise(r=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result)});const v=await new Promise(r=>{const q=d.transaction('device').objectStore('device').get('test-conflict');q.onsuccess=()=>r(q.result)});d.close();return v}""",database)
        assert retained=='generated-conflict'
        # Test fixture removes only the additional key it introduced, not state.
        b.evaluate("""async name=>{const d=await new Promise(r=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result)});await new Promise(r=>{const t=d.transaction('device','readwrite');t.objectStore('device').delete('test-conflict');t.oncomplete=r});d.close()}""",database)
        proof['checks']['late_idb_unknown_key_conflict_retained_no_candidate_commit']=True
        for fault in ('abort-before-write','abort-after-write'):
            call(b,'bind',binding(),{'testFault':fault},True);assert state()==before
        proof['checks']['transaction_abort_preserves_exact_proposal']=True
        start(b,'bind',binding(),{'testCrash':True});b.wait_for_function('()=>window.test_candidate_boundary===true',timeout=15000)
        crash(1);b=page(1);assert state()==before
        proof['checks']['actual_browser_sigkill_pending_transaction_retains_unbound_proposal']=True
        start(b,'bind',binding(),{'testLostReply':True});b.wait_for_function('()=>window.test_candidate_boundary===true',timeout=15000)
        committed=state();assert committed!=before;crash(1);b=page(1)
    result=call(b,'bind',binding());stable=state();assert stable!=before
    assert result['phase']=='inactive-candidate-custody' and all(result[k]==proposal[k] for k in ('public_key','package','package_sha256'))
    crash(1);b=page(1);restart();assert call(b,'bind',binding())==result and state()==stable
    tab=page(1);start(b,'bind',binding());start(tab,'bind',binding());assert finish(b)==finish(tab)==result and state()==stable
    call(b,'proposal',argument(),reject=True);assert state()==stable
    assert [digest(a,0),digest(b,1)]==source
    assert direct('owner','GET','/v1/mls/rooms/family/log')[0]==403 and direct('owner','GET','/v1/mls/rooms/successor-room/log')[0]==403
    proof['checks']['bound_exact_retry_cross_tab_restart_same_package_old_source_pending_unchanged_delivery_denied']=True
    if not original_only:
        # Generated encrypted corruption is retained. No recreation on bind.
        b.evaluate("""async name=>{const d=await new Promise(r=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result)});await new Promise(r=>{const t=d.transaction('device','readwrite'),s=t.objectStore('device'),q=s.get('state');q.onsuccess=()=>{const x=q.result;x.cipher[0]^=1;s.put(x,'state')};t.oncomplete=r});d.close()}""",database)
        corrupt=state();call(b,'bind',binding(),reject=True);assert state()==corrupt
        proof['checks']['corrupt_cipher_denied_retained_no_reset']=True
    # Fresh peer revocation denies even the candidate's exact accepted result.
    config['devices'][0].update(status='revoked',device_revision=2);commit(5,config['people']);time.sleep(1.2)
    assert b.evaluate("async path=>(await fetch(path,{headers:{'X-Family-Actor':'bob','X-Family-Device':'bob-candidate'}})).status",path)==403
    hook={'context':'wrong-phase','path':path,'seen':0};tamper[0]=hook
    try:call(b,'bind',binding(),reject=True)
    finally:tamper[0]=None
    proof['checks']['current_peer_revocation_denies_candidate_no_membership_activation']=True
    proof['boundary']='Synthetic inactive candidate private proposal/custody; no declarations, activation, native successor delivery, human recovery, or compiled UI'
