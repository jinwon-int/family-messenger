"""Protected MLS application confirmation; no plaintext possession claim."""
import base64
import hashlib
import json
import os
import subprocess
import threading
import time
from password_worker_smoke import safe_bytes


def confirmation_assets(root,work,assets,proof):
    cwd=root/'experiments/device-keystore';source=safe_bytes(cwd/'successor-confirmation-store.js',65536)
    def build(raw,name):
        result=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=successor-confirmation-store.js','--external:/pkg/*','--external:/trust-directory.js','--external:/handshake-wire.js','--external:/confirmation-wire.js'],input=raw,cwd=cwd,check=True,capture_output=True)
        assert len(result.stdout)<1024*1024
        fd=os.open(work/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(result.stdout)
        return result.stdout
    original=build(source,'confirmation-original.js')
    source=source.replace(b'{exact,fail}',b'{exact,fail,unhex}').replace(b'{same,bytes,request,jsonHash}',b'{same,bytes,request,jsonHash,hash,b64}')
    source=b"import {staged_trusted_apply} from '/pkg/family_mls_browser_experiment.js';\n"+source
    needle=b"await store.commit(before,after,'',live);";assert source.count(needle)==1
    source=source.replace(needle,b"await store.commit(before,after,self.testFault??'',live);")
    needle=b'store.root.seen=(after??before).revision;return result;';assert source.count(needle)==1
    source=source.replace(needle,b'''store.root.seen=(after??before).revision;
     self.testSnapshot={provider:hash(target(a,role).crypto),source:role==='peer'?sodium.to_hex(sodium.crypto_generichash(32,enc.encode(JSON.stringify({...a.rooms[0],crypto:b64(a.rooms[0].crypto)})))):null,package:role==='candidate'?a.package:null};
     if(self.testCrypto){const r=target(a,role),other=e.context[role==='peer'?'candidate':'peer'];let t;try{t=staged_trusted_apply(r.crypto,r.identity,self.testCrypto.method,bytes(self.testCrypto.input),other.actor,unhex(other.signing_key));self.testOutput=b64(t.output());}finally{t?.free();}}
     return result;''')
    assets['/successor-confirmation-store.js']=build(source,'confirmation-instrumented.js')
    for name in ('confirmation-wire.js','confirmation-worker.js','candidate-confirmation-worker.js','peer-confirmation-worker.js'):
        assets['/'+name]=safe_bytes(root/'experiments/openmls-browser/web'/name,65536)
    assets['/confirmation-original-store.js']=original
    assets['/confirmation-original-worker.js']=assets['/confirmation-worker.js']
    for role in ('peer','candidate'):
        assets['/original-'+role+'-confirmation-worker.js']=assets['/'+role+'-confirmation-worker.js'].replace(b'./successor-confirmation-store.js',b'./confirmation-original-store.js').replace(b'./confirmation-worker.js',b'./confirmation-original-worker.js')
    worker=assets['/confirmation-worker.js'].replace(b'self.onmessage=async({data})=>{',b'self.onmessage=async({data})=>{if(data?.testSetup){Object.assign(self,data.testSetup);return;}')
    assets['/confirmation-worker.js']=worker.replace(b'result,memory_bytes:memory',b'result:{...result,test_snapshot:self.testSnapshot,test_output:self.testOutput??null},memory_bytes:memory')
    proof['confirmation_bundles']={'original_sha256':hashlib.sha256(original).hexdigest(),'instrumented_sha256':hashlib.sha256(assets['/successor-confirmation-store.js']).hexdigest()}


def run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,source,proposal,database,candidate_actor):
    import copy
    peer_actor='alice' if candidate_actor=='bob' else 'bob';peer_subject='owner' if peer_actor=='alice' else 'family'
    def args(role):
        i=0 if role=='peer' else 1
        return {'identity':[peer_actor,candidate_actor][i],'database':databases[0] if i==0 else database,'password':passwords[i],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)}}
    def begin(p,role,arg=None,setup=None):
        p.evaluate('''([role,arg,setup])=>{
          window.pw?.terminate();const w=new Worker('/'+(setup?'':'original-')+role+'-confirmation-worker.js',{type:'module'});window.pw=w;
          window.confirmResult=new Promise(resolve=>{const timer=setTimeout(()=>{w.terminate();resolve({ok:false,timeout:true})},25000);w.onerror=e=>{clearTimeout(timer);resolve({ok:false,error:e.message})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'confirm',argument:arg});}else if(data.id===1||data.id===2){clearTimeout(timer);resolve(data.id===2?{ok:false}:data)}}});
        }''',[role,arg or args(role),setup])
    def done(p,reject=False):
        v=p.evaluate('window.confirmResult')
        if reject:assert not v['ok'] and 'result' not in v,v;return v
        assert v['ok'],v;assert v['memory_bytes']<=128*1024*1024
        proof['max_worker_linear_memory_bytes']=max(proof['max_worker_linear_memory_bytes'],v['memory_bytes'])
        r=v['result'];assert r['committed'] and 'pending' not in r
        if 'test_snapshot' in r:
            if r['role']=='peer':assert r['test_snapshot']['source']==source['digest']
            else:assert r['test_snapshot']['package']==proposal['package']
        return r
    def confirm(p,role,arg=None,setup=None,reject=False):begin(p,role,arg,setup);return done(p,reject)
    def snapshots():return [digest(a,0),digest(b,1),digest(b,1,database=database)]
    original=snapshots()
    for p,role in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            confirm(p,role,setup={'testFault':fault},reject=True);assert snapshots()==original and not hooks['posts']
        bad=args(role);bad['database']+='-missing';confirm(p,role,bad,reject=True)
        bad=args(role);bad['password']='w'*48;confirm(p,role,bad,reject=True)
        count=[0]
        def revoked_fresh(method,status,raw):
            count[0]+=1
            return (403,raw,False) if count[0]==2 else (status,raw,False)
        hooks['callback']=revoked_fresh
        try:confirm(p,role,reject=True)
        finally:hooks['callback']=None
        assert count[0]==2 and snapshots()==original and not hooks['posts']
    proof['checks']['confirmation_local_abort_missing_password_and_fresh_denial_zero_posts']=True
    wait=confirm(a,'peer');assert not wait['peer_verified'] and wait['phase']=='awaiting-candidate-proof'
    # Two candidate tabs own the same saved pending ciphertext even when no
    # request reaches the server. Both library sender transitions cannot commit.
    hooks['drop_before']=True;tab=page(1);begin(b,'candidate');begin(tab,'candidate');done(b,True);done(tab,True);hooks['drop_before']=False
    assert len(hooks['dropped'])==2 and hooks['dropped'][0]==hooks['dropped'][1] and not hooks['posts']
    pending=snapshots();crash(1);b=page(1)
    def lost(method,status,raw):return (status,b'{',False) if method=='POST' else (status,raw,False)
    hooks['callback']=lost;confirm(b,'candidate',reject=True);hooks['callback']=None
    assert hooks['posts']==[hooks['dropped'][0]] and snapshots()==pending
    crash(1);b=page(1);candidate=confirm(b,'candidate');assert not candidate['peer_verified'] and candidate['transcript_revision']==1
    stable=snapshots()
    # Actual valid MLS ciphertext carrying the wrong bound application frame.
    wrong=confirm(b,'candidate',setup={'testCrypto':{'method':'encrypt','input':base64.b64encode(b'wrong confirmation context').decode()}})['test_output']
    def substitute(payload,index):
        def change(method,status,raw):
            v=json.loads(raw);v['records'][index]['request']['payload']=payload
            v['records'][index]['sha256']=hashlib.sha256(json.dumps(v['records'][index]['request'],separators=(',',':')).encode()).hexdigest()
            return status,json.dumps(v).encode(),False
        return change
    for payload in (wrong,base64.b64encode(b'invalid MLS ciphertext').decode()):
        hooks['callback']=substitute(payload,0)
        try:confirm(a,'peer',reject=True)
        finally:hooks['callback']=None
        assert snapshots()==stable and len(hooks['posts'])==1
    for fault in ('abort-before-write','abort-after-write'):
        confirm(a,'peer',setup={'testFault':fault},reject=True);assert snapshots()==stable and len(hooks['posts'])==1
    hooks['drop_before']=True;confirm(a,'peer',reject=True);hooks['drop_before']=False
    peer_pending=hooks['dropped'][-1];pending=snapshots();crash(0);a=page(0)
    hooks['callback']=lost;confirm(a,'peer',reject=True);hooks['callback']=None
    assert hooks['posts'][-1]==peer_pending and len(hooks['posts'])==2 and snapshots()==pending
    crash(0);a=page(0);peer=confirm(a,'peer');assert peer['peer_verified']
    stable=snapshots()
    for fault in ('abort-before-write','abort-after-write'):
        confirm(b,'candidate',setup={'testFault':fault},reject=True);assert snapshots()==stable and len(hooks['posts'])==2
    for payload in (base64.b64encode(b'invalid peer proof').decode(),hooks['posts'][0]['payload']):
        hooks['callback']=substitute(payload,1)
        try:confirm(b,'candidate',reject=True)
        finally:hooks['callback']=None
        assert snapshots()==stable
    candidate=confirm(b,'candidate');assert candidate['peer_verified'] and candidate['group_id']==peer['group_id'] and candidate['transcript_revision']==peer['transcript_revision']==2
    proof['checks']['actual_context_bound_peer_authenticated_MLS_confirmation_both_directions']=True
    proof['checks']['confirmation_unknown_posts_same_role_race_and_lost_replies_exact_ciphertext']=True
    proof['checks']['invalid_MLS_and_valid_MLS_wrong_frame_rejected_no_commit_or_reply']=True
    stable=snapshots();assert stable[1]==original[1]
    restart();crash(0);a=page(0);crash(1);b=page(1)
    assert confirm(a,'peer')==peer and confirm(b,'candidate')==candidate and snapshots()==stable
    tab=page(0);begin(a,'peer');begin(tab,'peer');assert done(a)==done(tab)==peer and snapshots()==stable
    plaintext=base64.b64encode(b'generated post-confirmation ratchet continuity').decode()
    for sender,srole,receiver,rrole in ((a,'peer',b,'candidate'),(b,'candidate',a,'peer')):
        cipher=confirm(sender,srole,setup={'testCrypto':{'method':'encrypt','input':plaintext}})['test_output']
        assert confirm(receiver,rrole,setup={'testCrypto':{'method':'decrypt_peer','input':cipher}})['test_output']==plaintext and snapshots()==stable
    proof['checks']['persisted_send_receive_ratchets_source_pending_legacy_and_restart_unchanged']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        result=p.evaluate('''([role,arg])=>new Promise(resolve=>{const w=new Worker('/original-'+role+'-exchange-worker.js',{type:'module'});const timer=setTimeout(()=>{w.terminate();resolve({ok:true})},25000);w.onmessage=({data})=>{if(data.boot)w.postMessage({id:1,method:'exchange',argument:arg});else if(data.id===1){clearTimeout(timer);resolve(data);w.terminate()}}})''',[role,args(role)])
        assert result['ok'] is False and snapshots()==stable
    proof['checks']['old_exchange_entry_rejects_confirmation_formats_without_reset']=True
    for mode in ('json','oversize','redirect','header','rollback'):
        def mutate(method,status,raw):
            if mode=='json':return status,b'{',False
            if mode=='oversize':return status,b' '*16385,False
            if mode=='redirect':return 307,raw,False
            if mode=='header':return status,raw,True
            v=json.loads(raw);v.update(revision=1,phase='awaiting-peer-proof',records=v['records'][:1]);return status,json.dumps(v).encode(),False
        hooks['callback']=mutate
        try:confirm(a,'peer',reject=True)
        finally:hooks['callback']=None
        assert snapshots()==stable
    arrived=threading.Event();release=threading.Event()
    def held(method,status,raw):arrived.set();release.wait(7);return status,raw,False
    hooks['callback']=held;begin(a,'peer');assert arrived.wait(15)
    a.evaluate("window.pw.postMessage({id:2,method:'lock',argument:null})");release.set();done(a,True);hooks['callback']=None
    arrived.clear();release.clear();hooks['callback']=held
    try:confirm(b,'candidate',reject=True)
    finally:release.set();hooks['callback']=None
    assert snapshots()==stable and len(hooks['posts'])==2
    for p,role in ((a,'peer'),(b,'candidate')):
        bad=args(role);bad['intent']['reservation']['context']['expires_at']=1;confirm(p,role,bad,reject=True)
    assert direct(peer_subject,'GET','/v1/mls/rooms/successor-room/log')[0]==403
    next(d for d in config['devices'] if d['actor']==peer_actor).update(status='revoked',device_revision=2);commit(5,config['people'])
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        if direct(peer_subject,'GET','/v1/mls/successors/replace-bob/reservation')[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('revocation reload')
    for p,role in ((a,'peer'),(b,'candidate')):confirm(p,role,reject=True)
    assert snapshots()==stable and len(hooks['posts'])==2
    proof['checks']['confirmation_malformed_stale_lock_timeout_expiry_revocation_retains_state']=True
    proof['boundary']='Actual protected MLS peer confirmation only; server opaque receipts are not proof; no active admission or production cutover'
