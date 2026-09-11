"""Synthetic persistent participant closure with real protected browser custody."""
import copy
import hashlib
import json
import os
import subprocess
import time
from password_worker_smoke import safe_bytes
from native_retirement_checks import saved_state


def closure_assets(root,work,assets,proof):
    cwd=root/'experiments/device-keystore';source=safe_bytes(cwd/'successor-closure-store.js',65536)
    def build(raw,name):
        result=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=successor-closure-store.js','--external:/pkg/*','--external:/trust-directory.js','--external:/handshake-wire.js','--external:/confirmation-wire.js','--external:/lease-wire.js','--external:/enrollment-wire.js','--external:/closure-wire.js'],input=raw,cwd=cwd,check=True,capture_output=True)
        fd=os.open(work/name,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(result.stdout)
        return result.stdout
    original=build(source,'closure-original.js')
    needle=b"await store.commit(before,after,'',live);";assert source.count(needle)==1
    source=source.replace(needle,b"await store.commit(before,after,self.testFault??'',live);")
    source=source.replace(b'async function transaction(',b'''function retained(a,role){const v=structuredClone(a),r=target(v,role);if(r.closure){delete r.closure;v.version--;if(role==='candidate')v.checksum=exchangeChecksum(v);}const raw=enrollmentEncode(v,role);try{return sodium.to_hex(sodium.crypto_generichash(32,raw));}finally{sodium.memzero(raw);r.enrollment.crypto.fill(0);wipe(v,role);}}
async function transaction(''')
    needle=b'original=enrollmentEncode(a,role);const r=target(a,role);';assert source.count(needle)==1
    source=source.replace(needle,b'original=enrollmentEncode(a,role);const snapshot=retained(a,role);self.testSnapshot=snapshot;const r=target(a,role);')
    needle=b'return {committed:true,local_closed:true';assert source.count(needle)==1
    source=source.replace(needle,b'if(snapshot!==retained(a,role))fail();self.testSnapshot=snapshot;return {committed:true,local_closed:true')
    assets['/successor-closure-store.js']=build(source,'closure-instrumented.js');assets['/closure-original-store.js']=original
    for name in ('closure-wire.js','closure-worker.js','candidate-closure-worker.js','peer-closure-worker.js'):assets['/'+name]=safe_bytes(root/'experiments/openmls-browser/web'/name,65536)
    assets['/closure-original-worker.js']=assets['/closure-worker.js']
    for role in ('candidate','peer'):
        assets['/original-'+role+'-closure-worker.js']=assets['/'+role+'-closure-worker.js'].replace(b'./successor-closure-store.js',b'./closure-original-store.js').replace(b'./closure-worker.js',b'./closure-original-worker.js')
    assets['/closure-worker.js']=assets['/closure-worker.js'].replace(b'self.onmessage=async({data})=>{',b'self.onmessage=async({data})=>{if(data?.testSetup){Object.assign(self,data.testSetup);return;}').replace(b'result,memory_bytes:memory',b'result:{...result,test_snapshot:self.testSnapshot},memory_bytes:memory').replace(b'{id,ok:false,memory_bytes:0}',b'{id,ok:false,memory_bytes:0,test_snapshot:self.testSnapshot}')
    proof['closure_bundles']={'original_sha256':hashlib.sha256(original).hexdigest(),'instrumented_sha256':hashlib.sha256(assets['/successor-closure-store.js']).hexdigest()}


def run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,database,candidate_actor,enrollment_invoke):
    peer_actor='alice' if candidate_actor=='bob' else 'bob';subjects={'peer':'owner' if peer_actor=='alice' else 'family','candidate':'owner' if candidate_actor=='alice' else 'family'}
    names={'peer':databases[0],'candidate':database};retained={};path='/v1/mls/successors/replace-bob/closure';h=hooks['closure']
    def args(role,kind):return {'identity':peer_actor if role=='peer' else candidate_actor,'database':names[role],'password':passwords[0 if role=='peer' else 1],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)},'operation':{'kind':kind}}
    def invoke(p,role,kind='close',setup=None,reject=False,arg=None):
        v=p.evaluate('''([role,arg,setup])=>new Promise(resolve=>{const w=new Worker('/'+(setup?'':'original-')+role+'-closure-worker.js',{type:'module'});const timer=setTimeout(()=>{w.terminate();resolve({ok:false,timeout:true})},25000);w.onerror=e=>{clearTimeout(timer);resolve({ok:false,error:e.message})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'closure',argument:arg})}else if(data.id===1){clearTimeout(timer);resolve(data);w.terminate()}}})''',[role,arg or args(role,kind),setup])
        snap=v.get('test_snapshot') or v.get('result',{}).get('test_snapshot')
        if snap:assert len(snap)==64 and retained.setdefault(role,snap)==snap
        if reject:assert not v['ok'] and 'result' not in v,v;return
        assert v['ok'],v;r=v['result'];assert r['committed'] and r['local_closed'] and v['memory_bytes']<=128*1024*1024;return r
    def snapshots():return [digest(a,0),digest(b,1),digest(b,1,database=database)]
    assert time.time()>expected['context']['expires_at']
    # The provider has advanced bidirectionally. Freeze a real unsent ciphertext too.
    hooks['drop_before']='enrolled-channel';enrollment_invoke(b,'candidate',{'kind':'send','id':'closure-pending','text':'must remain sealed'},reject=True);hooks['drop_before']=None
    original=snapshots();baseline=[saved_state(a,databases[0]),saved_state(b,database)];oldposts=len(hooks['channel_posts'])
    for p,role in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            invoke(p,role,setup={'testFault':fault},reject=True);assert snapshots()==original and not h['posts']
        bad=args(role,'close');bad['password']='z'*48;invoke(p,role,arg=bad,reject=True)
        bad=args(role,'close');bad['database']='missing-closure-store';invoke(p,role,arg=bad,reject=True)
        invoke(p,role,'observe',reject=True);assert snapshots()==original and not h['posts']
    proof['checks']['closure_local_failure_missing_password_zero_POST_full_pending_provider_retained']=True
    for mode in ('json','oversize','redirect','header','signature','domain','timeout'):
        def mutate(method,status,raw):
            if mode=='timeout':time.sleep(5.2);return status,raw,False
            if mode=='json':return status,b'{',False
            if mode=='oversize':return status,b' '*(224*1024+1),False
            if mode=='redirect':return 307,raw,False
            if mode=='header':return status,raw,True
            v=json.loads(raw);v['closure']=copy.deepcopy(v['enrollment']['approvals'][0]);
            if mode=='signature':v['closure']['signature']='AA=='
            return status,json.dumps(v).encode(),False
        h['callback']=mutate
        try:invoke(b,'candidate',reject=True)
        finally:h['callback']=None
        assert snapshots()==original and not h['posts']
    proof['checks']['closure_bounded_status_current_headers_signature_domain_and_timeout_denied']=True
    order=['candidate','peer'] if candidate_actor=='bob' else ['peer','candidate']
    for role in order:
        p=b if role=='candidate' else a;h['drop_before']=True;invoke(p,role,setup={'testObserve':True},reject=True);h['drop_before']=False
        enrollment_invoke(p,role,{'kind':'sync'},reject=True)
    sealed=snapshots();assert len(h['dropped'])==2 and not h['posts'] and len(hooks['channel_posts'])==oldposts
    crash(0);a=page(0);crash(1);b=page(1)
    def lost(method,status,raw):return (status,b'{',False) if method=='POST' else (status,raw,False)
    winner=order[0];h['callback']=lost;invoke(b if winner=='candidate' else a,winner,reject=True);h['callback']=None
    assert snapshots()==sealed and h['posts']==[h['dropped'][0]]
    code,receipt=direct(subjects[winner],'GET',path);assert code==200 and receipt['closure']['role']==winner
    # One POST alone closes both directions, even with the other participant offline.
    for role in ('candidate','peer'):
        for action in ('enrollment','enrolled-channel'):
            assert direct(subjects[role],'GET','/v1/mls/successors/replace-bob/'+action)[0]==403
    proof['checks']['one_participant_POST_after_actual_expiry_closes_both_directions_lost_reply_exact']=True
    restart();crash(0);a=page(0);crash(1);b=page(1)
    for p,role in ((a,'peer'),(b,'candidate')):
        r=invoke(p,role,setup={'testObserve':True});assert r['server_closed']
        enrollment_invoke(p,role,{'kind':'sync'},reject=True)
    assert len(h['posts'])==1 and len(retained)==2 and snapshots()[1]==original[1]
    stable=snapshots()
    # Restoring the former enrollment locally cannot reopen server delivery.
    for i,(p,role) in enumerate(((a,'peer'),(b,'candidate'))):
        saved=saved_state(p,names[role])
        try:
            saved_state(p,names[role],baseline[i]);enrollment_invoke(p,role,{'kind':'sync'},reject=True);assert saved_state(p,names[role])==baseline[i]
        finally:saved_state(p,names[role],saved)
    assert snapshots()==stable
    proof['checks']['closure_restart_exact_receipt_old_worker_rollback_cannot_reopen_full_state_retained']=True
    def rollback(method,status,raw):
        v=json.loads(raw);v['closure']=None;return status,json.dumps(v).encode(),False
    h['callback']=rollback
    try:invoke(b,'candidate','observe',reject=True)
    finally:h['callback']=None
    assert snapshots()==stable
    proof['checks']['closure_receipt_rollback_rejected_without_erasing_local_tombstone']=True
    # Administrator revocation closes even observation but never erases either tombstone.
    config['activations'][0]['status']='revoked';commit(6,config['people'])
    until=time.monotonic()+6
    while time.monotonic()<until:
        if direct(subjects['peer'],'GET',path)[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('closure authority revocation reload')
    restart()
    for p,role in ((a,'peer'),(b,'candidate')):invoke(p,role,'observe',reject=True)
    assert snapshots()==stable
    proof['checks']['closure_policy_revocation_restart_preserves_terminal_custody_and_pending']=True
    proof['boundary']='Synthetic persistent target unilateral closure after actual expiry; all original and enrolled private state retained; no global device enrollment or production cutover'
