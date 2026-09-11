"""Actual compiled paired custody page/workers; old group/candidate are explicit fixtures."""
import copy,hashlib,http.client,json,subprocess,time
from pathlib import Path
from password_worker_smoke import safe_bytes


def compiled_assets(root,bundle,assets,proof,work):
    path=root/'server/internal/chat/custody_bundle.json';manifest=json.loads(safe_bytes(path,8192));compiled={}
    for e in manifest['files']:
        raw=safe_bytes(bundle/e['source'][7:] if e['source'].startswith('bundle:') else root/e['source'],2*1024*1024)
        assert len(raw)==e['bytes'] and hashlib.sha256(raw).hexdigest()==e['sha256'];compiled[e['url']]=raw
    cwd=root/'experiments/device-keystore'
    def build(source,name):
        return subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile='+name,'--external:/pkg/*','--external:/trust-directory.js'],input=source,cwd=cwd,check=True,capture_output=True).stdout
    source=safe_bytes(cwd/'successor-peer-store.js',65536);needle=b'export class SuccessorPeerStore extends AggregateStore {';assert source.count(needle)==1
    fault=source.replace(needle,needle+b"\n async commit(before,after,fault,live){return super.commit(before,after,'abort-after-write',live);}\n")
    assets['/peer-fault-store.js']=build(fault,'successor-peer-store.js');worker=compiled['/successor-peer-worker.js'];needle=b"'./successor-peer-store.js'";assert worker.count(needle)==1
    assets['/successor-peer-worker.js']=worker.replace(needle,b"'./peer-fault-store.js'")
    # Separate read-only private inspection: authenticate/validate the existing
    # state and return only the full source-record hash. It cannot commit v1->v2.
    marker=b"await this.commit(before,after,'',live);";assert source.count(marker)==1
    inspection=source.replace(marker,b"if(after)fail();await this.commit(before,null,'',live);")
    marker=b"return {committed:true,phase:'inactive-peer-custody'";assert inspection.count(marker)==1
    inspection=inspection.replace(marker,b"return {test_source_digest:sodium.to_hex(sodium.crypto_generichash(32,enc.encode(JSON.stringify({...a.rooms[0],crypto:b64(a.rooms[0].crypto)})))),committed:true,phase:'inactive-peer-custody'")
    assets['/peer-inspection-store.js']=build(inspection,'successor-peer-store.js');assets['/peer-inspection-worker.js']=worker.replace(needle,b"'./peer-inspection-store.js'")
    assets['/candidate-store.js']=build(safe_bytes(cwd/'candidate-store.js',65536),'candidate-store.js');assets['/candidate-worker.js']=safe_bytes(root/'experiments/openmls-browser/web/candidate-worker.js',65536)
    proof['custody_separate_fixture_sha256']={k:hashlib.sha256(assets[k]).hexdigest() for k in ('/successor-peer-worker.js','/peer-fault-store.js','/peer-inspection-worker.js','/peer-inspection-store.js','/candidate-store.js','/candidate-worker.js')}
    proof['custody_compiled_manifest_sha256']=hashlib.sha256(path.read_bytes()).hexdigest();proof['custody_compiled_expected_sha256']={k:hashlib.sha256(v).hexdigest() for k,v in compiled.items()}
    csource=safe_bytes(cwd/'candidate-store.js',65536);needle=b'export class CandidateStore extends NativeVaultStore {';assert csource.count(needle)==1
    csource=csource.replace(needle,needle+b" async commit(before,after,fault,live){return super.commit(before,after,'abort-after-write',live);}")
    assets['/candidate-fault-store.js']=build(csource,'candidate-store.js')
    for role,store,fault in [('candidate','candidate-store.js','candidate-fault-store.js'),('peer','successor-peer-store.js','peer-fault-store.js')]:
        name='/'+role+'-custody-worker.js';assets[name]=compiled[name].replace(store.encode(),fault.encode())
    assets['/candidate-worker.js']=compiled['/candidate-worker.js'].replace(b'candidate-store.js',b'candidate-fault-store.js')
    proof['custody_fault_entry_sha256']={k:hashlib.sha256(assets[k]).hexdigest() for k in ('/candidate-worker.js','/successor-peer-worker.js','/candidate-custody-worker.js','/peer-custody-worker.js','/candidate-fault-store.js')}
    return compiled


def route_checks(port,cookies,compiled,proof):
    for path,raw in compiled.items():
        for cookie,status in ((None,401),(cookies[0],200),(cookies[1],200)):
            c=http.client.HTTPConnection('127.0.0.1',port,timeout=10);c.request('GET',path,headers={'Cookie':'synthetic_edge='+cookie} if cookie else {});r=c.getresponse();data=r.read();c.close();assert r.status==status
            if status==200:assert data==raw and r.getheader('X-Content-Type-Options')=='nosniff' and r.getheader('Cache-Control')=='no-store'
    for path in ('/custody_bundle.json','/custodyassets/pkg.wasm','/custody-ceremony/unknown','/successor/','/candidate-preparation/'):
        c=http.client.HTTPConnection('127.0.0.1',port,timeout=10);c.request('GET',path,headers={'Cookie':'synthetic_edge='+cookies[0]});r=c.getresponse();r.read();c.close();assert r.status>=400
    proof['checks']['custody_compiled_22_assets_signed_both_actors_exact_bytes_headers']=True
    proof['checks']['custody_compiled_unknown_and_other_profile_routes_denied']=True


def run(a,b,databases,rpc,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,tamper,restart,hooks,actor,custody_hooks,order):
    index=['alice','bob'].index(actor);candidate_index=1-index;candidate=['alice','bob'][candidate_index];oldpages=[a,b]
    group=rpc(a,'status')['group_id'];prepare(a,'app-old-text',b'generated prior conversation');rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
    prepare(b,'app-old-file',bytes(range(256))*32,'file');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync')
    if actor=='alice':
        pending_id='update-peer-pending';rpc(a,'update',{'id':pending_id,'fault':''})
    else:
        # Preserve the existing leader-only rekey rule, including its rejection
        # without mutation. Bob's real pending work is an unsent application.
        rejected_before=digest(b,1);rpc(b,'update',{'id':'update-peer-pending','fault':''},reject=True);assert digest(b,1)==rejected_before
        b.evaluate("stopWorker('device');spawn('device')");rpc(b,'init',{'identity':'bob','room':'family','database':databases[1],'password':passwords[1],'create':False})
        pending_id='app-peer-pending';prepare(b,pending_id,b'generated unsent peer message')
    source=rpc(oldpages[index],'test-aggregate-digest')[0];assert source['pending']==pending_id
    proof['checks']['custody_pending_command_matches_actor_authority_with_rejected_update_unchanged']=True
    for p in (a,b):p.evaluate("stopWorker('device')")
    before=digest(oldpages[index],index);candidate_old=digest(oldpages[candidate_index],candidate_index);hooks['posts']=0;database=databases[index];password=passwords[index]
    def once(p,worker,method,argument):
        return p.evaluate("""([url,method,argument])=>new Promise((resolve,reject)=>{const w=new Worker(url,{type:'module'}),timer=setTimeout(()=>{w.terminate();reject(Error('timeout'))},60000);w.onerror=()=>{clearTimeout(timer);w.terminate();reject(Error('worker'))};w.onmessage=({data})=>{if(data.boot){w.postMessage({id:1,method,argument});argument.password=null;}else if(data.id===1){clearTimeout(timer);w.terminate();resolve(data);}}})""",[worker,method,argument])
    # Separate real candidate fixture: exact saved package, no fabricated key.
    candidate_db='family-mls-candidate-synthetic-peer-ceremony';candidate_arg={'identity':candidate,'database':candidate_db,'password':passwords[candidate_index],'create':True}
    reply=once(oldpages[candidate_index],'/candidate-worker.js','proposal',candidate_arg);assert reply['ok'];proposal=reply['result'];saved_candidate=digest(oldpages[candidate_index],candidate_index,database=candidate_db)
    now=int(time.time());old=config['devices'][candidate_index];admin={'subject':'owner','actor':'alice'};config['version']=2;config['successors']={'administrators':[admin],'intents':[]};commit(2,config['people'])
    intent={'intent_id':'replace-'+candidate,'action':'replace','actor':candidate,'subject':['owner','family'][candidate_index],'predecessor':old['device_id'],'predecessor_key':old['signing_key'],'predecessor_revision':1,'candidate':candidate+'-candidate','signing_key':proposal['public_key'],'fingerprint':hashlib.sha256(bytes.fromhex(proposal['public_key'])).hexdigest(),'package_sha256':proposal['package_sha256'],'previous_room':'family','previous_group':group,'next_room':'successor-room','administrator':admin,'acceptance':'out-of-band-fingerprint','base_revision':3,'created_at':now-1,'expires_at':now+360,'status':'candidate','decided_at':0,'decision_revision':0}
    config['successors']['intents']=[intent];commit(3,config['people']);intent.update(status='accepted',decided_at=int(time.time()),decision_revision=5);old.update(status='revoked',device_revision=2);commit(4,config['people']);path='/v1/mls/successors/'+intent['intent_id']+'/reservation'
    subject=['owner','family'][index];device=pins[index]['device_id'];context_path='/v1/mls/successors/'+intent['intent_id']+'/context'
    for _ in range(100):
        code,context=direct(subject,'GET',context_path,device=device)
        if code==200:break
        time.sleep(.05)
    assert code==200 and direct(['owner','family'][candidate_index],'GET',context_path,device=old['device_id'])[0]==403
    code,expected=direct(subject,'POST',path,{'reservation_id':'peer-ceremony-reservation','context_sha256':hashlib.sha256(json.dumps(context,separators=(',',':')).encode()).hexdigest()},device=device);assert code==201
    assert expected['context']['peer']['signing_key']==pins[index]['signing_key'] and expected['context']['package_sha256']==proposal['package_sha256']
    custody_hooks['posts'].clear();proof['checks']['custody_actual_old_pair_pending_and_saved_candidate_package']=True
    roles={'peer':index,'candidate':candidate_index};dbs={'peer':database,'candidate':candidate_db};identities={'peer':actor,'candidate':candidate}
    def snapshots():return [digest(oldpages[index],index),digest(oldpages[candidate_index],candidate_index),digest(oldpages[candidate_index],candidate_index,database=candidate_db)]
    before=snapshots()
    def ui(role):
        p=page(roles[role]);p.goto(p.url.rstrip('/')+'/custody-ceremony/');p.wait_for_selector('#run');return p
    def document(role,reservation=expected,db=None):return json.dumps({'version':1,'scopes':[{'identity':identities[role],'role':role,'database':db or dbs[role],'reservation':reservation}]},separators=(',',':'))
    def checksum(r=expected):return hashlib.sha256(json.dumps(r,separators=(',',':'),sort_keys=True).encode()).hexdigest()
    def load(p,role,raw=None):
        p.locator('#request-file').set_input_files({'name':'scope.json','mimeType':'application/json','buffer':(document(role) if raw is None else raw).encode()});p.locator('#request-load').click();p.wait_for_function("()=>document.getElementById('request-status').textContent.includes('요청을 읽었습니다')||document.getElementById('request-status').textContent.includes('형식')")
    def select(p,role,action='declare',db=None):
        p.locator('#identity').select_option(identities[role]);p.locator('#role').select_option(role);p.locator('#database').fill(db or dbs[role]);p.locator('#action').select_option(action);load(p,role,document(role,db=db));p.locator('#confirmation').fill(checksum())
    def credentials(p,role,pw=None):p.locator('#password').fill(pw or passwords[roles[role]]);p.locator('#consent').check()
    def finish(p,state):
        p.wait_for_function("()=>['prepared','own-declared','pair-declared','unknown'].includes(document.getElementById('status').dataset.state)",timeout=70000);actual=p.locator('#status').get_attribute('data-state');assert actual in state if isinstance(state,tuple) else actual==state,(state,actual,p.locator('#status').inner_text())
        assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
    def execute(p,role,state,pw=None):credentials(p,role,pw);assert not p.locator('#run').is_disabled();p.locator('#run').click();finish(p,state)
    def public(p):return json.loads(p.locator('#public-result').inner_text())
    pages={role:ui(role) for role in roles}
    for role,p in pages.items():
        assert p.locator('#identity').input_value()==p.locator('#role').input_value()==p.locator('#action').input_value()=='' and p.locator('#export').is_disabled()
        select(p,role);credentials(p,role);p.locator('#confirmation').fill('0'*64);assert p.locator('#run').is_disabled()
        for raw in ('{}','x'*32769,document(role,db=dbs[role]+'-wrong')):
            load(p,role,raw);credentials(p,role);p.locator('#confirmation').fill(checksum());assert p.locator('#run').is_disabled()
    assert snapshots()==before and not custody_hooks['posts'];proof['checks']['custody_dom_explicit_role_scope_action_bounded_file_independent_digest_no_auto_post']=True
    for role,p in pages.items():
        select(p,role,db=dbs[role]+'-missing');execute(p,role,'unknown')
        select(p,role);execute(p,role,'unknown','W'*48)
        hooks['fault']=True
        try:execute(p,role,'unknown')
        finally:hooks['fault']=False
        assert snapshots()==before and not custody_hooks['posts'] and p.locator('#export').is_disabled()
    proof['checks']['custody_dom_both_actual_commit_abort_missing_password_preserve_bytes_zero_post']=True
    for role,p in pages.items():
        bad=copy.deepcopy(expected);bad['context']['target_room']='substituted';select(p,role);load(p,role,document(role,bad));p.locator('#confirmation').fill(checksum(bad));execute(p,role,'unknown')
        for mode in ('invalid-json','wrong-header'):
            select(p,role);hook={'context':mode,'path':path,'seen':0};tamper[0]=hook
            try:execute(p,role,'unknown')
            finally:tamper[0]=None
            assert hook['seen']>=1
        assert snapshots()==before and not custody_hooks['posts']
    proof['checks']['custody_dom_substituted_scope_and_stale_signed_reservation_zero_post']=True
    for role,p in pages.items():
        select(p,role,'prepare');execute(p,role,'prepared');assert public(p)['state']=='prepared' and not custody_hooks['posts']
    prepared=snapshots();assert prepared[0]!=before[0] and prepared[1]==before[1] and prepared[2]!=before[2]
    proof['checks']['custody_dom_both_real_protected_preparation_commits_before_explicit_declaration']=True
    c_hash=hashlib.sha256(json.dumps(expected['context'],separators=(',',':')).encode()).hexdigest()
    def stable_id(role):return hashlib.sha256(json.dumps(['family-successor-custody-declaration',1,role,expected['reservation_id'],c_hash,expected['context'][role]['device_id']],separators=(',',':')).encode()).hexdigest()
    def valid(p,role):
        r=public(p);assert r['own_declared'] and r['committed'] and r['role']==role and r['declaration_id']==stable_id(role);return r
    sequence=['candidate','peer'] if order=='candidate' else ['peer','candidate']
    if order=='concurrent':
        for role,p in pages.items():select(p,role);credentials(p,role)
        for p in pages.values():p.locator('#run').click()
        for role,p in pages.items():finish(p,('own-declared','pair-declared'));valid(p,role)
    else:
        for n,role in enumerate(sequence):select(pages[role],role);execute(pages[role],role,'own-declared' if n==0 else 'pair-declared');valid(pages[role],role)
    assert snapshots()==prepared
    proof['checks']['custody_dom_actual_paired_order_slots_stable_id_no_reseal']=True
    # Destroy a reply to an actual server-committed POST. No new declaration ID
    # after the unknown result, including a whole browser/server restart.
    role=sequence[0];p=pages[role];select(p,role)
    def lost(method,status,raw):return (status,b'{',False) if method=='POST' else (status,raw,False)
    custody_hooks['callback']=lost
    try:execute(p,role,'unknown')
    finally:custody_hooks['callback']=None
    assert p.locator('#export').is_disabled() and snapshots()==prepared;crash(roles[role]);oldpages[roles[role]]=page(roles[role]);pages[role]=ui(role);restart();p=pages[role];select(p,role);execute(p,role,'pair-declared');valid(p,role);assert snapshots()==prepared
    proof['checks']['custody_dom_lost_post_reply_browser_worker_server_restart_exact_declared_slot']=True
    for role,p in pages.items():
        select(p,role);execute(p,role,'pair-declared');result=valid(p,role)
        with p.expect_download() as download:p.locator('#export').click()
        assert json.loads(Path(download.value.path()).read_text())==result and set(result)=={'version','identity','database','role','state','committed','own_declared','declaration_id','readiness'}
        assert p.evaluate('()=>localStorage.length===0&&sessionStorage.length===0')
    proof['checks']['custody_dom_only_exact_public_receipt_export_no_credentials_provider_storage']=True
    for mode in ('invalid-json','oversize','redirect','wrong-header','phase','get-regression'):
        def mutate(method,status,raw):
            if mode=='invalid-json':return status,b'{',False
            if mode=='oversize':return status,b' '*4097,False
            if mode=='redirect':return 307,raw,False
            if mode=='wrong-header':return status,raw,True
            v=json.loads(raw)
            if mode=='phase':v['phase']='ready'
            if mode=='get-regression' and method=='GET':v.update(phase='custody-pending',revision=1,declarations=[x for x in v['declarations'] if x['role']=='peer'])
            return status,json.dumps(v).encode(),False
        custody_hooks['callback']=mutate
        try:select(pages['peer'],'peer');execute(pages['peer'],'peer','unknown')
        finally:custody_hooks['callback']=None
        assert snapshots()==prepared
    proof['checks']['custody_dom_signed_post_readiness_bounds_redirect_identity_phase_and_regression_denied']=True
    tab=ui('peer');select(tab,'peer');select(pages['peer'],'peer');credentials(tab,'peer');credentials(pages['peer'],'peer');tab.locator('#run').click();pages['peer'].locator('#run').click();finish(tab,'pair-declared');finish(pages['peer'],'pair-declared');assert valid(tab,'peer')==valid(pages['peer'],'peer') and snapshots()==prepared;tab.close()
    proof['checks']['custody_dom_concurrent_same_role_no_duplicate_slot_or_private_write']=True
    # Both HTTP deadline and user lock retain prepared state and sticky uncertainty.
    import threading
    arrived=threading.Event();release=threading.Event()
    def held(method,status,raw):
        if method=='POST':arrived.set();release.wait(7)
        return status,raw,False
    for do_lock in (True,False):
        arrived.clear();release.clear();custody_hooks['callback']=held;p=pages['candidate'];select(p,'candidate');credentials(p,'candidate');p.locator('#run').click();assert arrived.wait(15)
        if do_lock:p.locator('#lock').click()
        finish(p,'unknown');release.set();custody_hooks['callback']=None;assert snapshots()==prepared and not p.locator('#uncertain').is_hidden() and p.locator('#export').is_disabled()
    proof['checks']['custody_dom_lock_timeout_retains_private_commit_no_late_success_or_retry']=True
    for role,p in pages.items():
        select(p,role,'prepare');execute(p,role,'prepared');assert not p.locator('#uncertain').is_hidden() if role=='candidate' else True
    reply=once(pages['peer'],'/peer-inspection-worker.js','successor',{'identity':actor,'database':database,'password':password,'intent':{'accepted':True,'reservation':expected}});assert reply['ok'] and reply['result']['test_source_digest']==source['digest']
    reply=once(pages['candidate'],'/candidate-worker.js','bind',{'identity':candidate,'database':candidate_db,'password':passwords[candidate_index],'intent':{'accepted':True,'reservation':expected}});assert reply['ok'] and reply['result']['package']==proposal['package'] and snapshots()==prepared
    assert all(p['declaration_id']==stable_id(p['role']) for p in custody_hooks['posts'])
    proof['checks']['custody_exact_saved_package_full_old_source_provider_pending_retained']=True
    if order=='candidate':
        remaining=expected['context']['expires_at']-time.time()+.1;assert 0<remaining<370;time.sleep(remaining);terminal='expiry'
    else:
        assert expected['context']['expires_at']-time.time()>10;config['devices'][index].update(status='revoked',device_revision=2);commit(5,config['people']);time.sleep(1.2);terminal='unexpired peer revocation'
    restart();count=len(custody_hooks['posts'])
    for role,p in pages.items():select(p,role);execute(p,role,'unknown');assert p.locator('#export').is_disabled()
    assert snapshots()==prepared and len(custody_hooks['posts'])==count
    assert direct(subject,'GET','/v1/mls/rooms/successor-room/log',device=device)[0]==403
    proof['checks']['custody_current_terminal_denial_both_roles_zero_post_tombstones_and_bytes_retained']=True
    proof['custody_order']=order;proof['peer_actor']=actor;proof['terminal_authority_case']=terminal
    proof['boundary']='Synthetic original-store preparation and explicit custody declarations only. Native22asset graph; old native pair/candidate creation/administrator and read-only inspection/abort fixtures separate. No Welcome, active enrollment or full human acceptance.'
