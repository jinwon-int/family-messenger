"""Original protected lease workers through an explicit synthetic DOM."""
import copy,hashlib,json,subprocess,threading,time
from urllib.parse import urlsplit
from password_worker_smoke import safe_bytes

def fixture_assets(root,assets,proof):
    web=root/'experiments/openmls-browser/web'
    if not web.exists():
        web=root.parent/'experiments/openmls-browser/web'
    mapping={'lease-ceremony.html':'/lease-ceremony/','lease-ceremony.css':'/lease-ceremony.css','lease-ceremony-ui.js':'/lease-ceremony-ui.js','lease-ceremony-client.js':'/lease-ceremony-client.js'}
    for name,url in mapping.items():
        raw=safe_bytes(web/name,65536);assets[url]=raw
    cwd=root/'experiments/device-keystore'
    if not cwd.exists():
        cwd=root.parent/'experiments/device-keystore'
    source=safe_bytes(cwd/'successor-lease-store.js',65536)
    needle=b"await store.commit(before,after,'',live);"
    assert source.count(needle)==1
    raw=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=successor-lease-store.js','--external:/pkg/*','--external:/trust-directory.js','--external:/handshake-wire.js','--external:/confirmation-wire.js','--external:/lease-wire.js'],input=source.replace(needle,b"await store.commit(before,after,'abort-after-write',live);"),cwd=cwd,capture_output=True,check=True).stdout
    assets['/lease-ceremony-fault-store.js']=raw
    for role in ('candidate','peer'):
        original=assets.get('/original-'+role+'-lease-worker.js') or assets.get('/'+role+'-lease-worker.js')
        if original is None:continue
        assets['/'+role+'-lease-worker.js']=original
        assets['/fault-'+role+'-lease-worker.js']=original.replace(b'./successor-lease-store.js',b'./lease-ceremony-fault-store.js')
    proof['lease_ceremony_packaging']='isolated synthetic fixture-served original UI; abort-after-write fault workers; not compiled Go assets'
    proof['lease_ceremony_fixture_sha256']={k:hashlib.sha256(assets[k]).hexdigest() for k in mapping.values()}
    return mapping

def run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,source,proposal,database,candidate_actor):
    peer_actor='alice' if candidate_actor=='bob' else 'bob';peer_subject='owner' if peer_actor=='alice' else 'family'
    def args(role,op=None):
        i=0 if role=='peer' else 1
        return {'identity':[peer_actor,candidate_actor][i],'database':databases[0] if i==0 else database,'password':passwords[i],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)},'operation':op or {'kind':'activate'}}
    def begin(p,role,op=None,arg=None,setup=None,submit=True):
        q=arg or args(role,op)
        if setup is None:
            origin='{0.scheme}://{0.netloc}'.format(urlsplit(p.url));p.goto(origin+'/lease-ceremony/');p.wait_for_selector('#run');p.evaluate('window.leaseTestMode=true')
            assert p.locator('#identity').input_value()==p.locator('#role').input_value()==p.locator('#action').input_value()=='' and p.locator('#run').is_disabled()
            assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
            kind=q['operation']['kind'];p.select_option('#identity',q['identity']);p.select_option('#role',role);p.fill('#database',q['database']);p.select_option('#action',kind)
            doc={'version':1,'scopes':[{'identity':q['identity'],'role':role,'database':q['database'],'reservation':q['intent']['reservation']}]}
            p.locator('#request-file').set_input_files({'name':'request.json','mimeType':'application/json','buffer':json.dumps(doc).encode()});p.click('#request-load');p.wait_for_function("()=>document.getElementById('request-status').textContent.includes('요청을 읽었습니다')")
            p.fill('#confirmation',hashlib.sha256(json.dumps(q['intent']['reservation'],sort_keys=True,separators=(',',':')).encode()).hexdigest());p.fill('#password',q['password'])
            if kind=='send':
                p.fill('#message-id',q['operation']['id']);p.fill('#message-text',q['operation']['text'])
            p.check('#consent')
            if submit:p.click('#run')
            return
        p.evaluate('window.leaseTestMode=false')
        p.evaluate('''([role,arg,setup])=>{
          window.ew?.terminate();const w=new Worker('/'+(setup?'fault-':'original-')+role+'-lease-worker.js',{type:'module'});window.ew=w;
          window.leaseResult=new Promise(resolve=>{const timer=setTimeout(()=>{w.terminate();resolve({ok:false,timeout:true})},25000);w.onerror=e=>{clearTimeout(timer);resolve({ok:false,error:e.message})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'lease',argument:arg});}else if(data.id===1||data.id===2){clearTimeout(timer);resolve(data.id===2?{ok:false}:data)}}});
        }''',[role,q,setup])
    def done(p,reject=False):
        if p.evaluate('window.leaseTestMode===true'):
            p.wait_for_function("()=>!['idle','locked','working'].includes(document.getElementById('status').dataset.state)",timeout=70000)
            state=p.locator('#status').get_attribute('data-state');assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
            if reject:assert state=='unknown' and p.locator('#export').is_disabled();return {'ok':False}
            assert state!='unknown',p.locator('#status').inner_text()
            value=json.loads(p.locator('#public-result').inner_text());assert 'received' not in value
            value['received']=[{'seq':int(li.get_attribute('data-seq')),'text':li.inner_text()} for li in p.locator('#received-list li').all()]
            return value
        v=p.evaluate('window.leaseResult')
        if reject:assert not v['ok'] and 'result' not in v,v;return v
        assert v['ok'],v
        assert v['memory_bytes']<=128*1024*1024
        proof['max_worker_linear_memory_bytes']=max(proof.get('max_worker_linear_memory_bytes',0),v['memory_bytes'])
        r=v['result'];assert r['committed'] and 'pending' not in r and 'approval' not in r
        return r
    def lease(p,role,op=None,arg=None,setup=None,reject=False):begin(p,role,op,arg,setup);return done(p,reject)
    def snapshots():return [digest(a,0),digest(b,1),digest(b,1,database=database)]
    original=snapshots()
    for p,role in ((a,'peer'),(b,'candidate')):
        begin(p,role,submit=False);assert not p.locator('#run').is_disabled()
        p.fill('#confirmation','0'*64);assert p.locator('#run').is_disabled()
        for raw in ('{}','x'*32769):
            p.locator('#request-file').set_input_files({'name':'bad.json','mimeType':'application/json','buffer':raw.encode()});p.click('#request-load');p.wait_for_function("()=>document.getElementById('request-status').textContent.includes('형식')")
            p.fill('#password',args(role)['password']);p.check('#consent');assert p.locator('#run').is_disabled()
        assert snapshots()==original and not hooks['posts']
    proof['checks']['lease_dom_no_selection_bounded_files_independent_digest_and_no_post']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        for setup in ({'testFault':'abort-before-write'},{'testFault':'abort-after-write'},{'testExpireAtCAS':True}):
            lease(p,role,setup=setup,reject=True);assert snapshots()==original and not hooks['posts']
        bad=args(role);bad['password']='w'*48;lease(p,role,arg=bad,reject=True)
    proof['checks']['lease_ceremony_both_roles_local_abort_actual_CAS_expiry_wrong_password_zero_approvals']=True
    def lost(method,status,raw):return (status,b'{',False) if method=='POST' else (status,raw,False)
    hooks['drop_before']='lease';lease(b,'candidate',reject=True);hooks['drop_before']=None;pending=snapshots();crash(1);b=page(1)
    hooks['callback']=lost;lease(b,'candidate',reject=True);hooks['callback']=None;assert hooks['posts']==[hooks['dropped'][-1]] and snapshots()==pending
    lease(b,'candidate');lease(b,'candidate',{'kind':'sync'},reject=True)
    hooks['callback']=lost;lease(a,'peer',reject=True);hooks['callback']=None
    crash(0);a=page(0);assert lease(a,'peer')['phase']=='leased';assert lease(b,'candidate')['phase']=='leased'
    proof['checks']['lease_ceremony_actual_dom_pair_gate_exact_approval_retry_lost_reply_restart']=True
    stable=snapshots()
    for p,role in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            lease(p,role,{'kind':'send','id':'abort','text':'generated abort'},setup={'testFault':fault},reject=True);assert snapshots()==stable and not hooks['channel_posts']
    hooks['drop_before']='channel';lease(b,'candidate',{'kind':'send','id':'message-one','text':'generated candidate hello'},reject=True);hooks['drop_before']=None;pending=snapshots();message=hooks['dropped'][-1];crash(1);b=page(1)
    hooks['channel_callback']=lost;lease(b,'candidate',{'kind':'sync'},reject=True);hooks['channel_callback']=None
    assert hooks['channel_posts']==[message] and snapshots()==pending
    lease(b,'candidate',{'kind':'sync'});stable=snapshots()
    lease(a,'peer',{'kind':'sync'},setup={'testFault':'abort-after-write'},reject=True);assert snapshots()==stable
    received=lease(a,'peer',{'kind':'sync'});assert received['received']==[{'seq':1,'text':'generated candidate hello'}]
    lease(a,'peer',{'kind':'send','id':'message-two','text':'generated peer reply'})
    received=lease(b,'candidate',{'kind':'sync'});assert received['received']==[{'seq':2,'text':'generated peer reply'}]
    stable=snapshots();lease(b,'candidate',{'kind':'send','id':'message-one','text':'generated candidate hello'});assert snapshots()==stable and len(hooks['channel_posts'])==2
    lease(b,'candidate',{'kind':'send','id':'message-one','text':'changed'},reject=True);assert snapshots()==stable
    restart();crash(0);a=page(0);crash(1);b=page(1)
    assert lease(b,'candidate',{'kind':'sync'})['received']==received['received'] and snapshots()==stable
    proof['checks']['lease_ceremony_actual_dom_bidirectional_messages_lost_posts_exact_retry_restart']=True
    for i in range(61):lease(b,'candidate',{'kind':'send','id':'capacity-'+str(i),'text':'generated capacity '+str(i)})
    hooks['drop_before']='channel';lease(b,'candidate',{'kind':'send','id':'capacity-race','text':'generated pending at capacity'},reject=True);hooks['drop_before']=None
    lease(a,'peer',{'kind':'send','id':'final-slot','text':'generated final peer message'})
    post_count=len(hooks['channel_posts']);assert post_count==64
    full=lease(b,'candidate',{'kind':'sync'});assert full['channel_full'] and full['outbox_status']=='blocked-capacity' and full['received'][-1]=={'seq':64,'text':'generated final peer message'}
    stable=snapshots();assert len(hooks['channel_posts'])==post_count
    crash(1);b=page(1);got=lease(b,'candidate',{'kind':'sync'});assert got['channel_full'] and got['outbox_status']=='blocked-capacity' and snapshots()==stable and len(hooks['channel_posts'])==post_count
    for p,role in ((a,'peer'),(b,'candidate')):
        lease(p,role,{'kind':'send','id':'overflow','text':'generated overflow'},reject=True)
        assert snapshots()==stable and len(hooks['channel_posts'])==post_count
    proof['checks']['lease_ceremony_full_channel_race_preserves_pending_stops_reposts_and_keeps_reading_after_restart']=True
    arrived=threading.Event();release=threading.Event()
    def held(method,status,raw):arrived.set();release.wait(7);return status,raw,False
    hooks['callback']=held;begin(a,'peer');assert arrived.wait(15)
    a.click('#lock');release.set();done(a,True);hooks['callback']=None
    assert snapshots()==stable
    proof['checks']['lease_ceremony_lock_during_in_flight_post_zero_success']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        bad=args(role,{'kind':'sync'});bad['intent']['reservation']['context']['expires_at']=1;lease(p,role,arg=bad,reject=True)
    next(d for d in config['devices'] if d['actor']==peer_actor).update(status='revoked',device_revision=2);commit(5,config['people'])
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        if direct(peer_subject,'GET','/v1/mls/successors/replace-bob/lease')[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('revocation reload')
    for p,role in ((a,'peer'),(b,'candidate')):lease(p,role,{'kind':'sync'},reject=True)
    assert snapshots()==stable
    proof['checks']['lease_ceremony_expiry_revocation_fail_closed_retain_committed_state']=True
    proof['candidate_actor']=candidate_actor
    proof['boundary']='Synthetic target-scoped expiring native channel DOM; no global enrollment, human keys, schema 13 or production cutover'
