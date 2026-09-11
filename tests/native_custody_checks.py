"""Paired protected client custody against the real signed synthetic server."""
import copy
import hashlib
import json
import threading
import time
from password_worker_smoke import safe_bytes


def custody_assets(root,work,assets,proof):
    from native_candidate_checks import candidate_assets
    from native_successor_peer_checks import successor_assets
    candidate_assets(root,work,assets,proof)
    main=assets['/main.js']
    successor_assets(root,work,assets,proof)
    assets['/main.js']=main
    for name in ('candidate-custody-worker.js','peer-custody-worker.js','custody-worker.js','custody-declaration.js'):
        assets['/'+name]=safe_bytes(root/'experiments/openmls-browser/web'/name,65536)
    # Served-only setup and private-source digest; originals remain hash recorded.
    raw=assets['/custody-worker.js']
    proof['custody_worker_original_sha256']=hashlib.sha256(raw).hexdigest()
    raw=raw.replace(b'self.onmessage=async({data})=>{',b'self.onmessage=async({data})=>{if(data?.testSetup){Object.assign(self,data.testSetup);return;}')
    raw=raw.replace(b'await store.open(selected.database,selected.identity,selected.room);',b"await store.open(selected.database,selected.identity,selected.room);if(self.testMutateIntent)a.intent.reservation.context.target_room='mutated-after-await';")
    raw=raw.replace(b'result,memory_bytes:memory',b'result:{...result,test_source_digest:self.testSourceDigest??null},memory_bytes:memory')
    assets['/custody-worker.js']=raw


def run(a,b,databases,rpc,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,tamper,restart,hooks,order,exchange_hooks=None,candidate_actor='bob'):
    peer_actor='alice' if candidate_actor=='bob' else 'bob'
    peer_subject='owner' if peer_actor=='alice' else 'family'
    if candidate_actor=='alice':
        assert exchange_hooks is not None
        a,b=b,a;databases=databases[::-1];passwords=passwords[::-1];pins=pins[::-1]
        original_page,original_crash,original_digest=page,crash,digest
        page=lambda i:original_page(1-i)
        crash=lambda i:original_crash(1-i)
        digest=lambda p,i,**kw:original_digest(p,1-i,**kw)
    group=rpc(a,'status')['group_id']
    prepare(a,'app-prior-text',b'generated old conversation');rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
    prepare(b,'app-prior-file',bytes(range(256))*32,'file');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync')
    if peer_actor=='alice':rpc(a,'update',{'id':'update-old-pending','fault':''})
    else:prepare(a,'app-old-pending',b'generated retained peer outbox')
    source_record=rpc(a,'test-aggregate-digest')[0]
    assert source_record['pending']==('update-old-pending' if peer_actor=='alice' else 'app-old-pending')
    a.evaluate("stopWorker('device')");b.evaluate("stopWorker('device')")
    database='family-mls-candidate-synthetic-'+candidate_actor+'-proposal'
    def argument(create=False,identity=candidate_actor,db=None):return {'identity':identity,'database':db or database,'password':passwords[1],'create':create}
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
    now=int(time.time());old=next(d for d in config['devices'] if d['actor']==candidate_actor);config['version']=2;admin={'subject':'owner','actor':'alice'}
    config['successors']={'administrators':[admin],'intents':[]};commit(2,config['people'])
    intent={'intent_id':'replace-bob','action':'replace','actor':candidate_actor,'subject':('family' if candidate_actor=='bob' else 'owner'),'predecessor':old['device_id'],'predecessor_key':old['signing_key'],'predecessor_revision':1,
            'candidate':candidate_actor+'-candidate','signing_key':proposal['public_key'],'fingerprint':hashlib.sha256(bytes.fromhex(proposal['public_key'])).hexdigest(),'package_sha256':proposal['package_sha256'],
            'previous_room':'family','previous_group':group,'next_room':'successor-room','administrator':admin,'acceptance':'out-of-band-fingerprint','base_revision':3,'created_at':now-1,'expires_at':now+hooks.get('intent_ttl',850),'status':'candidate','decided_at':0,'decision_revision':0}
    config['successors']['intents']=[intent];commit(3,config['people'])
    intent.update(status='accepted',decided_at=int(time.time()),decision_revision=5);old.update(status='revoked',device_revision=2);commit(4,config['people'])
    path='/v1/mls/successors/replace-bob/reservation'
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        code,c=direct(peer_subject,'GET','/v1/mls/successors/replace-bob/context')
        if code==200:break
        time.sleep(.05)
    else:raise AssertionError('accepted context reload')
    code,expected=direct(peer_subject,'POST',path,{'reservation_id':'candidate-reservation','context_sha256':hashlib.sha256(json.dumps(c,separators=(',',':')).encode()).hexdigest()});assert code==201
    def args(role,db=None):
        i=0 if role=='peer' else 1
        return {'identity':[peer_actor,candidate_actor][i],'database':db or (databases[0] if i==0 else database),'password':passwords[i],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)}}
    def begin(p,role,arg=None,setup=None):
        p.evaluate('''async ([role,arg,setup])=>{
          window.cw?.terminate();const w=new Worker('/'+(role==='peer'?'peer':'candidate')+'-custody-worker.js',{type:'module'});window.cw=w;
          window.custodyResult=new Promise(resolve=>{const timer=setTimeout(()=>{w.terminate();resolve({ok:false})},25000);w.onerror=()=>{clearTimeout(timer);resolve({ok:false})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'declare',argument:arg});}else if(data.id===1||data.id===2){clearTimeout(timer);resolve(data.id===2?{ok:false}:data)}}});
        }''',[role,arg or args(role),setup])
    def done(p,reject=False):
        value=p.evaluate('window.custodyResult')
        if reject:assert not value['ok'] and 'result' not in value,value;return value
        assert value['ok'],value
        assert value['memory_bytes']<=128*1024*1024
        proof['max_worker_linear_memory_bytes']=max(proof['max_worker_linear_memory_bytes'],value['memory_bytes'])
        return value['result']
    def declare(p,role,arg=None,setup=None,reject=False):begin(p,role,arg,setup);return done(p,reject)
    def snapshots():return [digest(a,0),digest(b,1),state()]
    before=snapshots()
    for p,role in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            declare(p,role,setup={'testFault':fault},reject=True)
            assert snapshots()==before and not hooks['posts']
        declare(p,role,args(role,args(role)['database']+'-missing'),reject=True)
        bad=args(role);bad['password']='w'*48;declare(p,role,bad,reject=True)
        assert snapshots()==before and not hooks['posts']
    proof['checks']['both_local_transaction_abort_missing_store_wrong_password_zero_posts']=True
    # Compute retry IDs independently using the public protocol's frozen encoding.
    context_hash=hashlib.sha256(json.dumps(expected['context'],separators=(',',':')).encode()).hexdigest()
    def stable_id(role):return hashlib.sha256(json.dumps(['family-successor-custody-declaration',1,role,expected['reservation_id'],context_hash,expected['context'][role]['device_id']],separators=(',',':')).encode()).hexdigest()
    def valid(result,role,revision):
        assert result['own_declared'] and result['committed'] and result['role']==role and result['declaration_id']==stable_id(role)
        assert result['readiness']['revision']==revision
        if role=='peer':assert result['test_source_digest']==source_record['digest']
    if order=='concurrent':
        begin(a,'peer');begin(b,'candidate');results=[done(a),done(b)]
        for role,result in zip(('peer','candidate'),results):valid(result,role,result['readiness']['revision'])
    else:
        first,second=(('candidate',b),('peer',a)) if order=='candidate' else (('peer',a),('candidate',b))
        # Server commits the first POST; a destroyed reply cannot emit success.
        seen=threading.Event()
        def lost(method,status,raw):
            if method=='POST':seen.set();return status,b'{',False
            return status,raw,False
        hooks['callback']=lost
        declare(first[1],first[0],reject=True);assert seen.is_set()
        hooks['callback']=None
        committed=snapshots();i=0 if first[0]=='peer' else 1
        crash(i)
        if i==0:a=page(0)
        else:b=page(1)
        first=(first[0],a if i==0 else b)
        valid(declare(first[1],first[0]),first[0],1);assert snapshots()==committed
        valid(declare(second[1],second[0]),second[0],2)
    stable=snapshots();assert stable[0]!=before[0] and stable[1]==before[1] and stable[2]!=before[2]
    assert call(b,'bind',{'identity':candidate_actor,'database':database,'password':passwords[1],'intent':{'accepted':True,'reservation':expected}})['package']==proposal['package']
    assert snapshots()==stable
    for p,role in ((a,'peer'),(b,'candidate')):valid(declare(p,role,setup={'testMutateIntent':True}),role,2)
    # Same-role cross-tab retry and both-role requests all observe immutable slots.
    tab=page(0);begin(a,'peer');begin(tab,'peer');valid(done(a),'peer',2);valid(done(tab),'peer',2)
    restart();crash(0);a=page(0);crash(1);b=page(1)
    for p,role in ((a,'peer'),(b,'candidate')):valid(declare(p,role),role,2)
    assert snapshots()==stable
    assert all(p['declaration_id']==stable_id(p['role']) for p in hooks['posts'])
    proof['checks']['paired_'+order+'_order_exact_public_id_lost_reply_browser_worker_server_restart_no_reseal']=True
    proof['checks']['actual_accepted_package_full_peer_source_pending_and_legacy_bob_cipher_preserved']=True
    if exchange_hooks is not None:
        from native_exchange_checks import run as exchange_run
        exchange_run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,exchange_hooks,expected,source_record,proposal,database,candidate_actor)
        return
    def mutation(mode):
        def apply(method,status,raw):
            value=json.loads(raw)
            if mode=='invalid-json':raw=b'{'
            elif mode=='oversize':raw=b' '*4097
            elif mode=='redirect':return 307,raw,False
            elif mode=='wrong-header':return status,raw,True
            elif mode=='bad-status':return 202,raw,False
            else:
                if mode=='phase':value['phase']='ready'
                elif mode=='revision':value['revision']=0
                elif mode=='duplicate':value['declarations'][1]=value['declarations'][0]
                elif mode=='order':value['declarations'].reverse()
                elif mode=='own-id':value['declarations'][1]['declaration_id']='wrong'
                elif mode=='device':value['declarations'][0]['device_id']='wrong'
                elif mode=='context':value['context_sha256']='ab'*32
                elif mode=='missing-own':value.update(revision=1,phase='custody-pending',declarations=value['declarations'][:1])
                elif mode=='unknown':value['extra']=True
                elif mode=='get-regression':
                    if method=='GET':value.update(revision=1,phase='custody-pending',declarations=value['declarations'][1:])
                raw=json.dumps(value).encode()
            return status,raw,False
        return apply
    for mode in ('invalid-json','oversize','redirect','wrong-header','bad-status','phase','revision','duplicate','order','own-id','device','context','missing-own','unknown','get-regression'):
        hooks['callback']=mutation(mode)
        try:declare(a,'peer',reject=True)
        finally:hooks['callback']=None
        assert snapshots()==stable,mode
    proof['checks']['bounded_signed_post_get_status_header_redirect_shape_slots_identity_and_monotonicity']=True
    # Abort during an outstanding HTTP operation cannot erase committed custody.
    arrived=threading.Event();release=threading.Event()
    def held(method,status,raw):
        if method=='POST':arrived.set();release.wait(7)
        return status,raw,False
    hooks['callback']=held
    begin(a,'peer');assert arrived.wait(15)
    a.evaluate("window.cw.postMessage({id:2,method:'lock',argument:null})")
    release.set();done(a,True);hooks['callback']=None
    assert snapshots()==stable
    # A full response deadline also retains custody and a stable retry identity.
    arrived.clear();release.clear();hooks['callback']=held
    try:declare(b,'candidate',reject=True)
    finally:release.set();hooks['callback']=None
    assert snapshots()==stable
    proof['checks']['lock_and_response_deadline_retain_committed_custody_no_late_success']=True
    assert direct('owner','GET','/v1/mls/rooms/successor-room/log')[0]==403
    assert direct('owner','POST','/v1/mls/rooms',{'room':'successor-room','group_id':'ba'*32,'device_id':'alice-first','peer_device':'bob-candidate'})[0]==403
    # An already-expired descriptor is rejected before any declaration POST.
    # The server suite separately exercises authoritative expiry on this endpoint.
    for p,role in ((a,'peer'),(b,'candidate')):
        bad=args(role);bad['intent']['reservation']['context']['expires_at']=1
        count=len(hooks['posts']);declare(p,role,bad,reject=True);assert len(hooks['posts'])==count and snapshots()==stable
    arrived.clear();release.clear();hooks['callback']=held
    begin(a,'peer');assert arrived.wait(15)
    config['devices'][0].update(status='revoked',device_revision=2);commit(5,config['people'])
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        if direct('owner','GET',path)[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('revocation reload')
    release.set();done(a,True);hooks['callback']=None
    assert snapshots()==stable
    proof['checks']['revocation_during_committed_post_denies_followup_readiness_retains_custody']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        count=len(hooks['posts']);declare(p,role,reject=True);assert len(hooks['posts'])==count and snapshots()==stable
    proof['checks']['expired_descriptor_current_revocation_denied_retained_and_native_target_inactive']=True
    proof['boundary']='Paired synthetic protected custody and public declarations only; no new group, activation, human ceremony, production or product UI'
