"""Actual short-lived native successor channel with protected paired approvals."""
import copy
import hashlib
import json
import os
import subprocess
import time
from password_worker_smoke import safe_bytes


def lease_assets(root,work,assets,proof):
    cwd=root/'experiments/device-keystore';source=safe_bytes(cwd/'successor-lease-store.js',65536)
    def build(raw,name):
        result=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=successor-lease-store.js','--external:/pkg/*','--external:/trust-directory.js','--external:/handshake-wire.js','--external:/confirmation-wire.js','--external:/lease-wire.js'],input=raw,cwd=cwd,check=True,capture_output=True)
        fd=os.open(work/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(result.stdout)
        return result.stdout
    original=build(source,'lease-original.js')
    needle=b"await store.commit(before,after,'',live);";assert source.count(needle)==1
    source=source.replace(needle,b'''let calls=0;await store.commit(before,after,self.testFault??'',()=>{if(self.testExpireAtCAS&&++calls===2)Date.now=()=>e.context.expires_at*1000+1;live();});''')
    needle=b'return {committed:true,role,approval:';assert source.count(needle)==1
    source=source.replace(needle,b'''self.testSnapshot={package:role==='candidate'?a.package:null,source:role==='peer'?sodium.to_hex(sodium.crypto_generichash(32,enc.encode(JSON.stringify({...a.rooms[0],crypto:b64(a.rooms[0].crypto)})))):null};return {committed:true,role,approval:''')
    assets['/successor-lease-store.js']=build(source,'lease-instrumented.js');assets['/lease-original-store.js']=original
    for n in ('lease-wire.js','lease-worker.js','candidate-lease-worker.js','peer-lease-worker.js'):assets['/'+n]=safe_bytes(root/'experiments/openmls-browser/web'/n,65536)
    assets['/lease-original-worker.js']=assets['/lease-worker.js']
    for role in ('candidate','peer'):
        assets['/original-'+role+'-lease-worker.js']=assets['/'+role+'-lease-worker.js'].replace(b'./successor-lease-store.js',b'./lease-original-store.js').replace(b'./lease-worker.js',b'./lease-original-worker.js')
    assets['/lease-worker.js']=assets['/lease-worker.js'].replace(b'self.onmessage=async({data})=>{',b'self.onmessage=async({data})=>{if(data?.testSetup){Object.assign(self,data.testSetup);return;}').replace(b'result,memory_bytes:memory',b'result:{...result,test_snapshot:self.testSnapshot},memory_bytes:memory')
    proof['lease_bundles']={'original_sha256':hashlib.sha256(original).hexdigest(),'instrumented_sha256':hashlib.sha256(assets['/successor-lease-store.js']).hexdigest()}


def run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,source,proposal,database,candidate_actor):
    peer_actor='alice' if candidate_actor=='bob' else 'bob';peer_subject='owner' if peer_actor=='alice' else 'family'
    def args(role,op):
        i=0 if role=='peer' else 1
        return {'identity':[peer_actor,candidate_actor][i],'database':databases[0] if i==0 else database,'password':passwords[i],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)},'operation':op}
    def invoke(p,role,op=None,setup=None,reject=False,arg=None):
        v=p.evaluate('''([role,arg,setup])=>new Promise(resolve=>{const w=new Worker('/'+(setup?'':'original-')+role+'-lease-worker.js',{type:'module'});const timer=setTimeout(()=>{w.terminate();resolve({ok:false,timeout:true})},25000);w.onerror=e=>{clearTimeout(timer);resolve({ok:false,error:e.message})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'lease',argument:arg})}else if(data.id===1){clearTimeout(timer);resolve(data);w.terminate()}}})''',[role,arg or args(role,op or {'kind':'activate'}),setup])
        if reject:assert not v['ok'] and 'result' not in v,v;return
        assert v['ok'],v;r=v['result'];assert r['committed'];assert v['memory_bytes']<=128*1024*1024
        if 'test_snapshot' in r:
            snap=r.pop('test_snapshot');assert snap['source']==source['digest'] if role=='peer' else snap['package']==proposal['package']
        return r
    def snapshots():return [digest(a,0),digest(b,1),digest(b,1,database=database)]
    original=snapshots()
    for p,role in ((a,'peer'),(b,'candidate')):
        for setup in ({'testFault':'abort-before-write'},{'testFault':'abort-after-write'},{'testExpireAtCAS':True}):
            invoke(p,role,setup=setup,reject=True);assert snapshots()==original and not hooks['posts']
        bad=args(role,{'kind':'activate'});bad['password']='w'*48;invoke(p,role,arg=bad,reject=True)
    proof['checks']['lease_both_roles_local_abort_actual_CAS_expiry_wrong_password_zero_approvals']=True
    def lost(method,status,raw):return (status,b'{',False) if method=='POST' else (status,raw,False)
    hooks['drop_before']='lease';invoke(b,'candidate',reject=True);hooks['drop_before']=None;pending=snapshots();crash(1);b=page(1)
    hooks['callback']=lost;invoke(b,'candidate',reject=True);hooks['callback']=None;assert hooks['posts']==[hooks['dropped'][-1]] and snapshots()==pending
    invoke(b,'candidate');invoke(b,'candidate',{'kind':'sync'},reject=True)
    hooks['callback']=lost;invoke(a,'peer',reject=True);hooks['callback']=None
    crash(0);a=page(0);assert invoke(a,'peer')['phase']=='leased';assert invoke(b,'candidate')['phase']=='leased'
    assert len(hooks['posts'])==5
    proof['checks']['actual_pinned_signatures_pair_gate_exact_approval_retry_lost_reply_restart']=True
    stable=snapshots()
    for p,role in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            invoke(p,role,{'kind':'send','id':'abort','text':'generated abort'},setup={'testFault':fault},reject=True);assert snapshots()==stable and not hooks['channel_posts']
    hooks['drop_before']='channel';invoke(b,'candidate',{'kind':'send','id':'message-one','text':'generated candidate hello'},reject=True);hooks['drop_before']=None;pending=snapshots();message=hooks['dropped'][-1];crash(1);b=page(1)
    hooks['channel_callback']=lost;invoke(b,'candidate',{'kind':'sync'},reject=True);hooks['channel_callback']=None
    assert hooks['channel_posts']==[message] and snapshots()==pending
    invoke(b,'candidate',{'kind':'sync'});stable=snapshots()
    invoke(a,'peer',{'kind':'sync'},setup={'testFault':'abort-after-write'},reject=True);assert snapshots()==stable
    received=invoke(a,'peer',{'kind':'sync'});assert received['received']==[{'seq':1,'text':'generated candidate hello'}]
    invoke(a,'peer',{'kind':'send','id':'message-two','text':'generated peer reply'})
    received=invoke(b,'candidate',{'kind':'sync'});assert received['received']==[{'seq':2,'text':'generated peer reply'}]
    stable=snapshots();invoke(b,'candidate',{'kind':'send','id':'message-one','text':'generated candidate hello'});assert snapshots()==stable and len(hooks['channel_posts'])==2
    invoke(b,'candidate',{'kind':'send','id':'message-one','text':'changed'},reject=True);assert snapshots()==stable
    restart();crash(0);a=page(0);crash(1);b=page(1)
    assert invoke(b,'candidate',{'kind':'sync'})==received and snapshots()==stable
    for p,role in ((a,'peer'),(b,'candidate')):invoke(p,role,{'kind':'sync'},setup={'testObserve':True})
    assert snapshots()[1]==original[1]
    proof['checks']['actual_native_channel_bidirectional_MLS_protected_commit_lost_posts_exact_retry_restart']=True
    proof['checks']['lease_preserves_full_source_pending_package_legacy_bytes_no_global_device_admission']=True
    for mode in ('json','oversize','redirect','header','rollback'):
        def mutate(method,status,raw):
            if mode=='json':return status,b'{',False
            if mode=='oversize':return status,b' '*2049,False
            if mode=='redirect':return 307,raw,False
            if mode=='header':return status,raw,True
            v=json.loads(raw);v.update(phase='awaiting-pair',approvals=[]);return status,json.dumps(v).encode(),False
        hooks['callback']=mutate
        try:invoke(b,'candidate',{'kind':'sync'},reject=True)
        finally:hooks['callback']=None
        assert snapshots()==stable
    for p,role in ((a,'peer'),(b,'candidate')):
        bad=args(role,{'kind':'sync'});bad['intent']['reservation']['context']['expires_at']=1;invoke(p,role,arg=bad,reject=True)
    next(d for d in config['devices'] if d['actor']==peer_actor).update(status='revoked',device_revision=2);commit(5,config['people'])
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        if direct(peer_subject,'GET','/v1/mls/successors/replace-bob/lease')[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('revocation reload')
    for p,role in ((a,'peer'),(b,'candidate')):invoke(p,role,{'kind':'sync'},reject=True)
    assert snapshots()==stable
    proof['checks']['lease_malformed_receipts_expiry_revocation_fail_closed_retain_committed_state']=True
    proof['boundary']='Synthetic target-scoped expiring native channel; no global enrollment or production cutover; durable activation and lifecycle acceptance remain'


def reject_premature(p,role,arg):
    arg=copy.deepcopy(arg);arg['operation']={'kind':'activate'}
    v=p.evaluate('''([role,arg])=>new Promise(resolve=>{const w=new Worker('/original-'+role+'-lease-worker.js',{type:'module'});const timer=setTimeout(()=>{w.terminate();resolve({ok:true,timeout:true})},25000);w.onmessage=({data})=>{if(data.boot)w.postMessage({id:1,method:'lease',argument:arg});else if(data.id===1){clearTimeout(timer);resolve(data);w.terminate()}}})''',[role,arg])
    assert v['ok'] is False and 'result' not in v,v
