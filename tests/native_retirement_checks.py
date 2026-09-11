"""Paired terminal custody, including an existing blocked sender outbox."""
import copy
import hashlib
import json
import os
import subprocess
import time
from password_worker_smoke import safe_bytes


def retirement_assets(root,work,assets,proof):
    cwd=root/'experiments/device-keystore';source=safe_bytes(cwd/'successor-retirement-store.js',65536)
    def build(raw,name):
        result=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=successor-retirement-store.js','--external:/pkg/*','--external:/trust-directory.js','--external:/handshake-wire.js','--external:/confirmation-wire.js','--external:/lease-wire.js','--external:/retirement-wire.js'],input=raw,cwd=cwd,check=True,capture_output=True)
        fd=os.open(work/name,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(result.stdout)
        return result.stdout
    original=build(source,'retirement-original.js')
    needle=b"await store.commit(before,after,'',live);";assert source.count(needle)==1
    source=source.replace(needle,b"let calls=0;await store.commit(before,after,self.testFault??'',()=>{if(self.testExpireAtCAS&&++calls===2)Date.now=()=>e.context.expires_at*1000+1;live();});")
    # Hash the COMPLETE previous lease record, preserving provider, old source,
    # blocked pending and receipts; strip only the new terminal metadata/version.
    source=source.replace(b'async function transaction(',b'''function retained(a,role){let view=structuredClone(a);const r=target(view,role);if(r.retirement){delete r.retirement;view.version--;if(role==='candidate')view.checksum=exchangeChecksum(view);}const raw=encode(view,role);try{return sodium.to_hex(sodium.crypto_generichash(32,raw));}finally{sodium.memzero(raw);wipe(view,role);}}
async function transaction(''')
    needle=b'original=encode(a,role);const r=target(a,role);';assert source.count(needle)==1
    source=source.replace(needle,b'original=encode(a,role);const savedRetained=retained(a,role);const r=target(a,role);')
    needle=b'return {committed:true,local_retired:true';assert source.count(needle)==1
    source=source.replace(needle,b'if(savedRetained!==retained(a,role))fail();self.testSnapshot=savedRetained;return {committed:true,local_retired:true')
    assets['/successor-retirement-store.js']=build(source,'retirement-instrumented.js');assets['/retirement-original-store.js']=original
    for name in ('retirement-wire.js','retirement-worker.js','candidate-retirement-worker.js','peer-retirement-worker.js'):assets['/'+name]=safe_bytes(root/'experiments/openmls-browser/web'/name,65536)
    assets['/retirement-original-worker.js']=assets['/retirement-worker.js']
    for role in ('candidate','peer'):
        assets['/original-'+role+'-retirement-worker.js']=assets['/'+role+'-retirement-worker.js'].replace(b'./successor-retirement-store.js',b'./retirement-original-store.js').replace(b'./retirement-worker.js',b'./retirement-original-worker.js')
    assets['/retirement-worker.js']=assets['/retirement-worker.js'].replace(b'self.onmessage=async({data})=>{',b'self.onmessage=async({data})=>{if(data?.testSetup){Object.assign(self,data.testSetup);return;}').replace(b'const kind=a.operation.kind',b'if(self.testExpired)Date.now=()=>a.intent.reservation.context.expires_at*1000+1;const kind=a.operation.kind').replace(b'result,memory_bytes:memory',b'result:{...result,test_snapshot:self.testSnapshot},memory_bytes:memory')
    proof['retirement_bundles']={'original_sha256':hashlib.sha256(original).hexdigest(),'instrumented_sha256':hashlib.sha256(assets['/successor-retirement-store.js']).hexdigest()}



def saved_state(p,name,restore=None):
    return p.evaluate("""async([name,restore])=>{const db=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});try{if(restore!==null){const state=JSON.parse(restore,(k,v)=>v&&Object.keys(v).length===1&&Array.isArray(v.__fixture_bytes)?new Uint8Array(v.__fixture_bytes):v);await new Promise((r,j)=>{const tx=db.transaction('device','readwrite');tx.objectStore('device').put(state,'state');tx.oncomplete=r;tx.onerror=j;tx.onabort=j});return null;}const state=await new Promise((r,j)=>{const q=db.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});return JSON.stringify(state,(k,v)=>v instanceof Uint8Array?{__fixture_bytes:Array.from(v)}:v);}finally{db.close();}}""",[name,restore])


def run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,source,proposal,database,candidate_actor,lease_invoke,unused_snapshots):
    peer_actor='alice' if candidate_actor=='bob' else 'bob';peer_subject='owner' if peer_actor=='alice' else 'family'
    def args(role,kind):
        i=0 if role=='peer' else 1
        return {'identity':[peer_actor,candidate_actor][i],'database':databases[0] if i==0 else database,'password':passwords[i],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)},'operation':{'kind':kind}}
    retained={}
    def invoke(p,role,kind='retire',setup=None,reject=False,arg=None):
        v=p.evaluate('''([role,arg,setup])=>new Promise(resolve=>{const w=new Worker('/'+(setup?'':'original-')+role+'-retirement-worker.js',{type:'module'});const timer=setTimeout(()=>{w.terminate();resolve({ok:false,timeout:true})},25000);w.onerror=e=>{clearTimeout(timer);resolve({ok:false,error:e.message})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'retirement',argument:arg})}else if(data.id===1){clearTimeout(timer);resolve(data);w.terminate()}}})''',[role,arg or args(role,kind),setup])
        if reject:assert not v['ok'] and 'result' not in v,v;return
        assert v['ok'],v;r=v['result'];assert r['committed'] and r['local_retired'] and v['memory_bytes']<=128*1024*1024
        if 'test_snapshot' in r:
            snapshot=r.pop('test_snapshot');assert len(snapshot)==64
            assert retained.setdefault(role,snapshot)==snapshot
        return r
    def snapshots():return [digest(a,0),digest(b,1),digest(b,1,database=database)]
    original=snapshots()
    for p,role in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            invoke(p,role,setup={'testFault':fault},reject=True);assert snapshots()==original and not hooks['posts']
        invoke(p,role,setup={'testExpireAtCAS':True},reject=True);assert snapshots()==original and not hooks['posts']
        wrong=args(role,'retire');wrong['password']='x'*48;invoke(p,role,arg=wrong,reject=True)
        invoke(p,role,'observe',reject=True);assert snapshots()==original and not hooks['posts']
    proof['checks']['retirement_local_abort_CAS_expiry_password_zero_posts']=True
    # Both roles durably retire before any request reaches the server. Lost
    # outcomes must never let an old lease worker resume the retained sender.
    hooks['drop_before']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        invoke(p,role,setup={'testObserve':True},reject=True)
        lease_invoke(p,role,{'kind':'sync'},reject=True)
    hooks['drop_before']=False;pending=snapshots();assert len(hooks['dropped'])==2 and not hooks['posts']
    crash(0);a=page(0);crash(1);b=page(1)
    for p,role in ((a,'peer'),(b,'candidate')):
        result=invoke(p,role,'observe',setup={'testObserve':True});assert not result['server_retired']
        result=invoke(p,role,setup={'testExpired':True});assert not result['server_retired']
    assert snapshots()==pending and not hooks['posts']
    proof['checks']['retirement_pending_is_terminal_across_restart_expiry_without_reposting']=True
    # Winner order differs between the two candidate-role CI variants.
    role='candidate' if candidate_actor=='bob' else 'peer';p=b if role=='candidate' else a
    def lost(method,status,raw):return (status,b'{',False) if method=='POST' else (status,raw,False)
    hooks['callback']=lost;invoke(p,role,reject=True);hooks['callback']=None
    assert snapshots()==pending and hooks['posts']==[next(q for q in hooks['dropped'] if q['role']==role)]
    restart();crash(0);a=page(0);crash(1);b=page(1)
    for p,r in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            stable=snapshots();invoke(p,r,'observe',setup={'testFault':fault},reject=True);assert snapshots()==stable
        result=invoke(p,r,'observe');assert result['server_retired']
        result=invoke(p,r,'observe',setup={'testObserve':True});assert result['server_retired']
        lease_invoke(p,r,{'kind':'sync'},reject=True)
    stable=snapshots();assert stable[1]==original[1] and len(hooks['posts'])==1
    proof['checks']['retirement_unknown_reply_single_winner_both_protected_stores_preserve_full_lease_bytes']=True
    for index,(p,role,name) in enumerate(((a,'peer',databases[0]),(b,'candidate',database))):
        saved=saved_state(p,name)
        try:
            saved_state(p,name,hooks['prelease'][index]);old=saved_state(p,name)
            invoke(p,role,'observe',reject=True);assert saved_state(p,name)==old and len(hooks['posts'])==1
        finally:saved_state(p,name,saved)
    assert snapshots()==stable
    proof['checks']['retirement_public_receipt_cannot_reconstruct_missing_private_lease']=True
    for mode in ('json','oversize','redirect','header','rollback'):
        def mutate(method,status,raw):
            if mode=='json':return status,b'{',False
            if mode=='oversize':return status,b' '*(224*1024+1),False
            if mode=='redirect':return 307,raw,False
            if mode=='header':return status,raw,True
            v=json.loads(raw);v['retirement']=None;return status,json.dumps(v).encode(),False
        hooks['callback']=mutate
        try:invoke(b,'candidate','observe',reject=True)
        finally:hooks['callback']=None
        assert snapshots()==stable and len(hooks['posts'])==1
    for p,role in ((a,'peer'),(b,'candidate')):
        assert invoke(p,role,setup={'testExpired':True})['server_retired']
        assert snapshots()==stable and len(hooks['posts'])==1
    proof['checks']['retirement_malformed_rollback_receipts_rejected_expired_observation_no_post']=True
    next(d for d in config['devices'] if d['actor']==peer_actor).update(status='revoked',device_revision=2);commit(5,config['people'])
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        if direct(peer_subject,'GET','/v1/mls/successors/replace-bob/retirement')[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('retirement current authority reload')
    for p,role in ((a,'peer'),(b,'candidate')):invoke(p,role,'observe',reject=True)
    assert snapshots()==stable
    proof['checks']['retirement_current_authority_revocation_denies_observation_retains_tombstones']=True
    proof['boundary']='Permanent target-only synthetic channel retirement; no key erasure, permanent enrollment or production cutover'
