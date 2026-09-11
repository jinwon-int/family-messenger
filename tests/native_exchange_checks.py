"""Exact saved-package Welcome exchange using two encrypted browser stores."""
import copy
import hashlib
import json
import os
import subprocess
import threading
import time
from password_worker_smoke import safe_bytes


def exchange_assets(root,work,assets,proof):
    cwd=root/'experiments/device-keystore'
    source=safe_bytes(cwd/'successor-exchange-store.js',65536)
    def build(raw,name):
        result=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=successor-exchange-store.js','--external:/pkg/*','--external:/trust-directory.js','--external:/handshake-wire.js'],input=raw,cwd=cwd,check=True,capture_output=True)
        assert len(result.stdout)<1024*1024
        fd=os.open(work/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(result.stdout)
        return result.stdout
    original=build(source,'exchange-original.js')
    needle=b"await store.commit(before,after,'',live);"
    assert source.count(needle)==1
    source=source.replace(needle,b"await store.commit(before,after,self.testFault??'',live);")
    needle=b'store.root.seen=(after??before).revision;return result;'
    assert source.count(needle)==1
    source=source.replace(needle,b'''store.root.seen=(after??before).revision;
     self.testSnapshot={provider:hash(target(a,role).crypto),source:role==='peer'?sodium.to_hex(sodium.crypto_generichash(32,enc.encode(JSON.stringify({...a.rooms[0],crypto:b64(a.rooms[0].crypto)})))):null,package:role==='candidate'?a.package:null};
     if(self.testCrypto){const r=target(a,role),other=e.context[role==='peer'?'candidate':'peer'];let t;try{t=staged_trusted_apply(r.crypto,r.identity,self.testCrypto.method,bytes(self.testCrypto.input),other.actor,unhex(other.signing_key));self.testOutput=b64(t.output());}finally{t?.free();}}
     return result;''')
    assets['/successor-exchange-store.js']=build(source,'exchange-instrumented.js')
    for name in ('candidate-exchange-worker.js','peer-exchange-worker.js','exchange-worker.js','handshake-wire.js'):
        assets['/'+name]=safe_bytes(root/'experiments/openmls-browser/web'/name,65536)
    assets['/exchange-original-store.js']=original
    assets['/exchange-original-worker.js']=assets['/exchange-worker.js']
    for role in ('peer','candidate'):
        assets['/original-'+role+'-exchange-worker.js']=assets['/'+role+'-exchange-worker.js'].replace(b'./successor-exchange-store.js',b'./exchange-original-store.js').replace(b'./exchange-worker.js',b'./exchange-original-worker.js')
    worker=assets['/exchange-worker.js']
    worker=worker.replace(b'self.onmessage=async({data})=>{',b'self.onmessage=async({data})=>{if(data?.testSetup){Object.assign(self,data.testSetup);return;}')
    worker=worker.replace(b'result,memory_bytes:memory',b'result:{...result,test_snapshot:self.testSnapshot,test_output:self.testOutput??null},memory_bytes:memory')
    assets['/exchange-worker.js']=worker
    proof['exchange_bundles']={'original_sha256':hashlib.sha256(original).hexdigest(),'instrumented_sha256':hashlib.sha256(assets['/successor-exchange-store.js']).hexdigest()}


def run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,source,proposal,database,candidate_actor='bob'):
    peer_actor='alice' if candidate_actor=='bob' else 'bob'
    peer_subject='owner' if peer_actor=='alice' else 'family'
    def args(role):
        i=0 if role=='peer' else 1
        return {'identity':[peer_actor,candidate_actor][i],'database':databases[0] if i==0 else database,'password':passwords[i],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)}}
    def begin(p,role,arg=None,setup=None):
        p.evaluate('''([role,arg,setup])=>{
          window.ew?.terminate();const w=new Worker('/'+(setup?'':'original-')+role+'-exchange-worker.js',{type:'module'});window.ew=w;
          window.exchangeResult=new Promise(resolve=>{const timer=setTimeout(()=>{w.terminate();resolve({ok:false,timeout:true})},25000);w.onerror=e=>{clearTimeout(timer);resolve({ok:false,error:e.message})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'exchange',argument:arg});}else if(data.id===1||data.id===2){clearTimeout(timer);resolve(data.id===2?{ok:false}:data)}}});
        }''',[role,arg or args(role),setup])
    def done(p,reject=False):
        v=p.evaluate('window.exchangeResult')
        if reject:assert not v['ok'] and 'result' not in v,v;return v
        assert v['ok'],v
        assert v['memory_bytes']<=128*1024*1024
        proof['max_worker_linear_memory_bytes']=max(proof['max_worker_linear_memory_bytes'],v['memory_bytes'])
        r=v['result'];assert r['committed'] and 'pending' not in r
        if 'test_snapshot' in r:
            if r['role']=='peer':assert r['test_snapshot']['source']==source['digest']
            else:assert r['test_snapshot']['package']==proposal['package']
        return r
    def exchange(p,role,arg=None,setup=None,reject=False):begin(p,role,arg,setup);return done(p,reject)
    def snapshots():return [digest(a,0),digest(b,1),digest(b,1,database=database)]
    original=snapshots()
    for p,role in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            exchange(p,role,setup={'testFault':fault},reject=True)
            assert snapshots()==original and not hooks['posts']
        bad=args(role);bad['database']+='-missing';exchange(p,role,bad,reject=True)
        bad=args(role);bad['password']='w'*48;exchange(p,role,bad,reject=True)
        assert snapshots()==original and not hooks['posts']
    proof['checks']['exchange_local_abort_missing_wrong_password_zero_handshake_posts']=True
    # Peer may wait first without generating a group or sending anything.
    waiting=exchange(a,'peer');assert waiting['phase']=='awaiting-key-package' and waiting['group_id']=='' and not hooks['posts']
    kp=exchange(b,'candidate');assert kp['phase']=='awaiting-welcome'
    assert len(hooks['posts'])==1 and hooks['posts'][0]['kind']=='key_package'
    import base64
    assert base64.b64decode(hooks['posts'][0]['payload']).hex()==proposal['package']
    # Welcome is committed locally and remotely, then its reply is destroyed.
    def lost(method,status,raw):return (status,b'{',False) if method=='POST' else (status,raw,False)
    hooks['drop_before']=True
    exchange(a,'peer',reject=True);hooks['drop_before']=False
    staged=snapshots();assert len(hooks['posts'])==1 and len(hooks['dropped'])==1
    crash(0);a=page(0)
    hooks['callback']=lost
    exchange(a,'peer',reject=True);hooks['callback']=None
    assert hooks['posts'][-1]==hooks['dropped'][0] and snapshots()==staged
    assert len(hooks['posts'])==2 and hooks['posts'][1]['kind']=='welcome'
    welcome=copy.deepcopy(hooks['posts'][1]);crash(0);a=page(0)
    def substituted(method,status,raw):
        v=json.loads(raw);q=v['records'][1]['request'];q['payload']=base64.b64encode(b'generated substituted Welcome').decode()
        v['records'][1]['sha256']=hashlib.sha256(json.dumps(q,separators=(',',':')).encode()).hexdigest()
        return status,json.dumps(v).encode(),False
    hooks['callback']=substituted
    exchange(a,'peer',reject=True);hooks['callback']=None
    assert snapshots()==staged and len(hooks['posts'])==2
    peer=exchange(a,'peer');assert peer['phase']=='awaiting-ack' and len(hooks['posts'])==2
    stable=snapshots();assert exchange(a,'peer')==peer and snapshots()==stable
    # Aborted local Welcome consumption cannot acknowledge it.
    for fault in ('abort-before-write','abort-after-write'):
        exchange(b,'candidate',setup={'testFault':fault},reject=True)
        assert snapshots()==stable and len(hooks['posts'])==2
    hooks['callback']=lost
    exchange(b,'candidate',reject=True);hooks['callback']=None
    assert len(hooks['posts'])==3 and hooks['posts'][2]['kind']=='ack'
    crash(1);b=page(1)
    candidate=exchange(b,'candidate');peer=exchange(a,'peer')
    assert candidate['phase']==peer['phase']=='exchange-recorded-inactive'
    assert candidate['group_id']==peer['group_id']==welcome['group_id']
    proof['checks']['exact_saved_package_actual_welcome_join_committed_before_ack_lost_replies_restart']=True
    proof['checks']['unknown_unaccepted_post_retries_exact_sealed_welcome_substitution_rejected']=True
    stable=snapshots();assert stable[1]==original[1]
    restart();crash(0);a=page(0);crash(1);b=page(1)
    assert exchange(a,'peer')==peer and exchange(b,'candidate')==candidate and snapshots()==stable
    tab=page(0);begin(a,'peer');begin(tab,'peer');assert done(a)==done(tab)==peer and snapshots()==stable
    proof['checks']['source_full_pending_legacy_cipher_restart_concurrent_retry_no_reseal']=True
    # Use disposable library transitions on the actual reopened protected states.
    # No ratchet changes are saved and no application API is added to the worker.
    plaintext=base64.b64encode(b'generated exact-package continuity').decode()
    for sender,srole,receiver,rrole in ((a,'peer',b,'candidate'),(b,'candidate',a,'peer')):
        encrypted=exchange(sender,srole,setup={'testCrypto':{'method':'encrypt','input':plaintext}})['test_output']
        opened=exchange(receiver,rrole,setup={'testCrypto':{'method':'decrypt_peer','input':encrypted}})['test_output']
        assert opened==plaintext and snapshots()==stable
    proof['checks']['bidirectional_actual_saved_private_crypto_continuity_disposable_transitions']=True
    proof['checks']['original_uninstrumented_workers_perform_all_successful_protocol_writes']=True
    def malformed(mode):
        def change(method,status,raw):
            v=json.loads(raw)
            if mode=='json':raw=b'{'
            elif mode=='oversize':raw=b' '*(192*1024+1)
            elif mode=='redirect':return 307,raw,False
            elif mode=='header':return status,raw,True
            elif mode=='status':return 202,raw,False
            else:
                if mode=='rollback':v.update(revision=2,phase='awaiting-ack',records=v['records'][:2])
                elif mode=='unknown':v['extra']=True
                elif mode=='digest':v['records'][1]['sha256']='aa'*32
                elif mode=='context':v['context_sha256']='ab'*32
                elif mode=='phase':v['phase']='ready'
                raw=json.dumps(v).encode()
            return status,raw,False
        return change
    for mode in ('json','oversize','redirect','header','status','rollback','unknown','digest','context','phase'):
        hooks['callback']=malformed(mode)
        try:exchange(a,'peer',reject=True)
        finally:hooks['callback']=None
        assert snapshots()==stable and len(hooks['posts'])==3,mode
    proof['checks']['bounded_signed_transcript_rejects_rollback_malformed_authority_and_redirect']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        result=p.evaluate('''([role,arg])=>new Promise(resolve=>{const w=new Worker('/'+role+'-custody-worker.js',{type:'module'});const timer=setTimeout(()=>{w.terminate();resolve({ok:true})},25000);w.onmessage=({data})=>{if(data.boot)w.postMessage({id:1,method:'declare',argument:arg});else if(data.id===1){clearTimeout(timer);resolve(data);w.terminate()}}})''',[role,args(role)])
        assert result['ok'] is False and 'result' not in result and snapshots()==stable
    proof['checks']['unchanged_legacy_workers_reject_new_explicit_formats_without_reset']=True
    arrived=threading.Event();release=threading.Event()
    def held(method,status,raw):arrived.set();release.wait(7);return status,raw,False
    hooks['callback']=held;begin(a,'peer');assert arrived.wait(15)
    a.evaluate("window.ew.postMessage({id:2,method:'lock',argument:null})");release.set();done(a,True);hooks['callback']=None
    assert snapshots()==stable
    arrived.clear();release.clear();hooks['callback']=held
    try:exchange(b,'candidate',reject=True)
    finally:release.set();hooks['callback']=None
    assert snapshots()==stable
    for p,role in ((a,'peer'),(b,'candidate')):
        bad=args(role);bad['intent']['reservation']['context']['expires_at']=1;exchange(p,role,bad,reject=True)
        assert snapshots()==stable
    assert direct('owner','GET','/v1/mls/rooms/successor-room/log')[0]==403
    next(d for d in config['devices'] if d['actor']==peer_actor).update(status='revoked',device_revision=2);commit(5,config['people'])
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        if direct(peer_subject,'GET','/v1/mls/successors/replace-bob/reservation')[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('revocation reload')
    for p,role in ((a,'peer'),(b,'candidate')):exchange(p,role,reject=True)
    assert snapshots()==stable and len(hooks['posts'])==3
    proof['checks']['lock_expiry_revocation_retains_private_state_no_native_activation']=True
    proof['boundary']='Synthetic exact-package Welcome private continuity only; empty server ack is not possession proof; no activation, production or human recovery'
