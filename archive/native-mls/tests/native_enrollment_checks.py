"""Generated paired persistent target enrollment; no production policy or data."""
import copy
import hashlib
import json
import os
import subprocess
import time
from password_worker_smoke import safe_bytes
from native_retirement_checks import saved_state


def enrollment_assets(root,work,assets,proof):
    cwd=root/'experiments/device-keystore';source=safe_bytes(cwd/'successor-enrollment-store.js',65536)
    def build(raw,name):
        result=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=successor-enrollment-store.js','--external:/pkg/*','--external:/trust-directory.js','--external:/handshake-wire.js','--external:/confirmation-wire.js','--external:/lease-wire.js','--external:/enrollment-wire.js'],input=raw,cwd=cwd,check=True,capture_output=True)
        fd=os.open(work/name,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(result.stdout)
        return result.stdout
    original=build(source,'enrollment-original.js')
    needle=b"await store.commit(before,after,'',live);";assert source.count(needle)==1
    source=source.replace(needle,b"let calls=0;await store.commit(before,after,self.testFault??'',()=>{if(self.testExpireAtCAS&&++calls===2)Date.now=()=>e.context.expires_at*1000+1;live();});")
    source=source.replace(b'async function transaction(',b'''function retained(a,role){let v=structuredClone(a);const r=target(v,role);if(r.enrollment){r.enrollment.crypto.fill(0);delete r.enrollment;v.version-=2;if(role==='candidate')v.checksum=exchangeChecksum(v);}const raw=encode(v,role);try{return sodium.to_hex(sodium.crypto_generichash(32,raw));}finally{sodium.memzero(raw);wipe(v,role);}}
async function transaction(''')
    needle=b'original=serialize(a,role);const r=target(a,role);';assert source.count(needle)==1;source=source.replace(needle,b'original=serialize(a,role);const savedRetained=retained(a,role);self.testSnapshot=savedRetained;const r=target(a,role);')
    needle=b'return {committed:true,approval:n.approval';assert source.count(needle)==1;source=source.replace(needle,b'if(savedRetained!==retained(a,role))fail();self.testSnapshot=savedRetained;return {committed:true,approval:n.approval')
    assets['/successor-enrollment-store.js']=build(source,'enrollment-instrumented.js');assets['/enrollment-original-store.js']=original
    for name in ('enrollment-wire.js','enrollment-worker.js','candidate-enrollment-worker.js','peer-enrollment-worker.js'):assets['/'+name]=safe_bytes(root/'experiments/openmls-browser/web'/name,65536)
    assets['/enrollment-original-worker.js']=assets['/enrollment-worker.js']
    for role in ('candidate','peer'):
        assets['/original-'+role+'-enrollment-worker.js']=assets['/'+role+'-enrollment-worker.js'].replace(b'./successor-enrollment-store.js',b'./enrollment-original-store.js').replace(b'./enrollment-worker.js',b'./enrollment-original-worker.js')
    assets['/enrollment-worker.js']=assets['/enrollment-worker.js'].replace(b'self.onmessage=async({data})=>{',b'self.onmessage=async({data})=>{if(data?.testSetup){Object.assign(self,data.testSetup);return;}').replace(b'result,memory_bytes:memory',b'result:{...result,test_snapshot:self.testSnapshot},memory_bytes:memory').replace(b'{id,ok:false,memory_bytes:0}',b'{id,ok:false,memory_bytes:0,test_snapshot:self.testSnapshot}')
    proof['enrollment_bundles']={'original_sha256':hashlib.sha256(original).hexdigest(),'instrumented_sha256':hashlib.sha256(assets['/successor-enrollment-store.js']).hexdigest()}


def run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,source,proposal,database,candidate_actor,lease_invoke):
    peer_actor='alice' if candidate_actor=='bob' else 'bob';peer_subject='owner' if peer_actor=='alice' else 'family'
    def args(role,op):
        i=0 if role=='peer' else 1
        return {'identity':[peer_actor,candidate_actor][i],'database':databases[0] if i==0 else database,'password':passwords[i],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)},'operation':op}
    if hooks.get('ui_enabled'):
        from native_successor_ui_checks import install
        install(hooks,expected,databases,database,passwords,candidate_actor,proof)
    retained={}
    def invoke(p,role,op=None,setup=None,reject=False,arg=None):
        ui_state=None
        if 'ui' in hooks and setup is None and arg is None and (op or {'kind':'enroll'})['kind'] in ('enroll','observe'):
            kind=(op or {'kind':'enroll'})['kind'];ui_state=hooks['ui']['perform'](p,role,'enroll' if kind=='enroll' else 'enrollment-observe')
            if reject:
                assert ui_state=='unknown';return
            assert ui_state!='unknown';op={'kind':'observe'}
        v=p.evaluate('''([role,arg,setup])=>new Promise(resolve=>{const w=new Worker('/'+(setup?'':'original-')+role+'-enrollment-worker.js',{type:'module'});const timer=setTimeout(()=>{w.terminate();resolve({ok:false,timeout:true})},25000);w.onerror=e=>{clearTimeout(timer);resolve({ok:false,error:e.message})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'enrollment',argument:arg})}else if(data.id===1){clearTimeout(timer);resolve(data);w.terminate()}}})''',[role,arg or args(role,op or {'kind':'enroll'}),setup])
        if v.get('test_snapshot'):
            snap=v['test_snapshot'];assert len(snap)==64;assert retained.setdefault(role,snap)==snap
        if reject:assert not v['ok'] and 'result' not in v,v;return
        assert v['ok'],v;r=v['result'];assert r['committed'] and v['memory_bytes']<=128*1024*1024
        if 'test_snapshot' in r:
            snap=r.pop('test_snapshot');assert len(snap)==64;assert retained.setdefault(role,snap)==snap
        if ui_state is not None:
            expected_state='active' if r['active'] else 'awaiting-admin' if r['pair_declared'] else 'awaiting-peer' if r['own_declared'] else 'local-saved'
            assert ui_state==expected_state,(ui_state,r)
        return r
    def snapshots():return [digest(a,0),digest(b,1),digest(b,1,database=database)]
    original=snapshots();original_devices=copy.deepcopy(config['devices']);old_states=[saved_state(a,databases[0]),saved_state(b,database)]
    for p,role in ((a,'peer'),(b,'candidate')):
        for setup in ({'testFault':'abort-before-write'},{'testFault':'abort-after-write'},{'testExpireAtCAS':True}):
            invoke(p,role,setup=setup,reject=True);assert snapshots()==original and not hooks['posts']
        bad=args(role,{'kind':'enroll'});bad['password']='z'*48;invoke(p,role,arg=bad,reject=True)
        invoke(p,role,{'kind':'observe'},reject=True);assert snapshots()==original and not hooks['posts']
    proof['checks']['enrollment_requires_existing_private_lease_local_CAS_expiry_password_zero_POST']=True
    # First role differs between CI variants. Each local seal survives unknown POST.
    order=[('candidate',b),('peer',a)] if candidate_actor=='bob' else [('peer',a),('candidate',b)]
    for role,p in order:
        hooks['drop_before']='enrollment';invoke(p,role,setup={'testObserve':True},reject=True);hooks['drop_before']=None
        if 'ui' in hooks:assert not invoke(p,role,{'kind':'observe'})['own_declared']
        lease_invoke(p,role,{'kind':'sync'},reject=True)
    pending=snapshots();assert not hooks['posts'] and len(hooks['dropped'])==2
    crash(0);a=page(0);crash(1);b=page(1)
    def lost(method,status,raw):return (status,b'{',False) if method=='POST' else (status,raw,False)
    for role in [x[0] for x in order]:
        p=b if role=='candidate' else a;hooks['callback']=lost;invoke(p,role,reject=True);hooks['callback']=None
        assert snapshots()[1]==original[1]
    assert hooks['posts']==hooks['dropped']
    restart();crash(0);a=page(0);crash(1);b=page(1)
    for p,role in ((a,'peer'),(b,'candidate')):
        r=invoke(p,role);assert r['own_declared'] and r['pair_declared'] and not r['active']
        invoke(p,role,{'kind':'send','id':'before-policy','text':'generated'},reject=True)
    proof['checks']['paired_fresh_persistent_consent_commit_before_POST_exact_retry_restart_lease_frozen']=True
    # A public pair never replaces a lost private enrollment record.
    for index,(p,role,name) in enumerate(((a,'peer',databases[0]),(b,'candidate',database))):
        saved=saved_state(p,name)
        try:
            saved_state(p,name,old_states[index]);before=saved_state(p,name);invoke(p,role,reject=True);assert saved_state(p,name)==before
        finally:saved_state(p,name,saved)
    proof['checks']['public_pair_cannot_reconstruct_missing_private_enrollment']=True
    grant=invoke(b,'candidate',{'kind':'observe'})['approval_sha256'];assert len(grant)==64
    config['version']=3;config['activations']=[{'intent_id':expected['context']['intent_id'],'approval_sha256':grant,'status':'active'}];commit(5,config['people']);commit(5,config['people'])
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        code,v=direct(peer_subject,'GET','/v1/mls/successors/replace-bob/enrollment')
        if code==200 and v['active']:break
        time.sleep(.05)
    else:raise AssertionError('explicit activation policy reload')
    for p,role in ((a,'peer'),(b,'candidate')):assert invoke(p,role,{'kind':'observe'},setup={'testObserve':True})['active']
    if 'ui' in hooks:
        for p,role in ((a,'peer'),(b,'candidate')):assert invoke(p,role,{'kind':'observe'})['active']
    stable=snapshots()
    if hooks.get('ui_handoff'):
        posts=len(hooks['posts'])
        for p,role in ((a,'peer'),(b,'candidate')):
            hooks['ui']['handoff_check'](p,role)
            assert snapshots()==stable and len(hooks['posts'])==posts
        proof['checks']['handoff_substituted_scope_rejected_by_real_custody_zero_POST']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        invoke(p,role,{'kind':'send','id':'abort','text':'generated'},setup={'testFault':'abort-after-write'},reject=True);assert snapshots()==stable and not hooks['channel_posts']
    hooks['drop_before']='enrolled-channel';invoke(b,'candidate',{'kind':'send','id':'one','text':'persistent candidate hello'},reject=True);hooks['drop_before']=None;pending=snapshots();crash(1);b=page(1)
    hooks['channel_callback']=lost;invoke(b,'candidate',{'kind':'sync'},reject=True);hooks['channel_callback']=None;assert snapshots()==pending
    invoke(b,'candidate',{'kind':'sync'});r=invoke(a,'peer',{'kind':'sync'});assert r['received']==[{'seq':1,'text':'persistent candidate hello'}]
    invoke(a,'peer',{'kind':'send','id':'two','text':'persistent peer reply'});r=invoke(b,'candidate',{'kind':'sync'});assert r['received']==[{'seq':2,'text':'persistent peer reply'}]
    stable=snapshots();invoke(b,'candidate',{'kind':'send','id':'one','text':'persistent candidate hello'});assert snapshots()==stable
    invoke(b,'candidate',{'kind':'send','id':'one','text':'changed'},reject=True);assert snapshots()==stable
    assert config['devices']==original_devices and snapshots()[1]==original[1]
    proof['checks']['separate_policy_gate_actual_bidirectional_saved_MLS_provider_lost_reply_idempotency']=True
    for mode in ('json','oversize','redirect','header','rollback'):
        def mutate(method,status,raw):
            if mode=='json':return status,b'{',False
            if mode=='oversize':return status,b' '*(224*1024+1),False
            if mode=='redirect':return 307,raw,False
            if mode=='header':return status,raw,True
            v=json.loads(raw);v['enrollment']['approvals']=[];v['active']=False;return status,json.dumps(v).encode(),False
        hooks['callback']=mutate
        try:invoke(b,'candidate',{'kind':'sync'},reject=True)
        finally:hooks['callback']=None
        assert snapshots()==stable
    proof['checks']['enrollment_bounded_receipts_redirect_rollback_reject_preserve_state']=True
    # Wait for actual server intent expiry, not a forged HTTP phase or browser clock.
    remaining=expected['context']['expires_at']-time.time()+.05;assert 0<remaining<500,remaining
    time.sleep(remaining)
    assert direct(peer_subject,'GET','/v1/mls/successors/replace-bob/lease')[0]==403
    restart();crash(0);a=page(0);crash(1);b=page(1)
    invoke(b,'candidate',{'kind':'send','id':'after-expiry','text':'durable after original expiry'})
    assert invoke(a,'peer',{'kind':'sync'})['received'][-1]['text']=='durable after original expiry'
    for p,role in ((a,'peer'),(b,'candidate')):invoke(p,role,{'kind':'observe'},setup={'testObserve':True})
    assert snapshots()[1]==original[1] and len(retained)==2
    proof['checks']['actual_server_expiry_and_worker_server_restart_persistent_admission_full_old_bytes_retained']=True
    if 'closure' in hooks:
        from native_closure_checks import run as closure_run
        closure_run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,database,candidate_actor,invoke)
        return
    stable=snapshots();config['activations'][0]['status']='revoked';commit(6,config['people'])
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        if direct(peer_subject,'GET','/v1/mls/successors/replace-bob/enrollment')[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('activation revocation reload')
    restart()
    for p,role in ((a,'peer'),(b,'candidate')):invoke(p,role,{'kind':'sync'},reject=True)
    assert snapshots()==stable and config['devices']==original_devices
    proof['checks']['persistent_policy_revocation_restart_denies_retains_all_custody_and_tombstones']=True
    proof['boundary']='Synthetic persistent unused target enrollment only, 64-message prototype cap; immutable global Devices and all former state retained; no production cutover'
