"""Actual compiled intact-peer page/worker; old group/candidate are explicit fixtures."""
import copy,hashlib,http.client,json,subprocess,time
from pathlib import Path
from password_worker_smoke import safe_bytes


def compiled_assets(root,bundle,assets,proof,work):
    path=root/'server/internal/chat/peer_bundle.json';manifest=json.loads(safe_bytes(path,8192));compiled={}
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
    proof['peer_separate_fixture_sha256']={k:hashlib.sha256(assets[k]).hexdigest() for k in ('/successor-peer-worker.js','/peer-fault-store.js','/peer-inspection-worker.js','/peer-inspection-store.js','/candidate-store.js','/candidate-worker.js')}
    proof['peer_compiled_manifest_sha256']=hashlib.sha256(path.read_bytes()).hexdigest();proof['peer_compiled_expected_sha256']={k:hashlib.sha256(v).hexdigest() for k,v in compiled.items()}
    return compiled


def route_checks(port,cookies,compiled,proof):
    for path,raw in compiled.items():
        for cookie,status in ((None,401),(cookies[0],200),(cookies[1],200)):
            c=http.client.HTTPConnection('127.0.0.1',port,timeout=10);c.request('GET',path,headers={'Cookie':'synthetic_edge='+cookie} if cookie else {});r=c.getresponse();data=r.read();c.close();assert r.status==status
            if status==200:assert data==raw and r.getheader('X-Content-Type-Options')=='nosniff' and r.getheader('Cache-Control')=='no-store'
    for path in ('/peer_bundle.json','/peerassets/pkg.wasm','/peer-preparation/unknown','/successor/','/candidate-preparation/'):
        c=http.client.HTTPConnection('127.0.0.1',port,timeout=10);c.request('GET',path,headers={'Cookie':'synthetic_edge='+cookies[0]});r=c.getresponse();r.read();c.close();assert r.status>=400
    proof['checks']['peer_compiled_14_assets_signed_both_actors_exact_bytes_headers']=True
    proof['checks']['peer_compiled_unknown_and_other_profile_routes_denied']=True


def run(a,b,databases,rpc,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,tamper,restart,hooks,actor):
    index=['alice','bob'].index(actor);candidate_index=1-index;candidate=['alice','bob'][candidate_index];oldpages=[a,b]
    group=rpc(a,'status')['group_id'];prepare(a,'app-old-text',b'generated prior conversation');rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
    prepare(b,'app-old-file',bytes(range(256))*32,'file');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync');rpc(oldpages[index],'update',{'id':'update-peer-pending','fault':''})
    source=rpc(oldpages[index],'test-aggregate-digest')[0];assert source['pending']=='update-peer-pending'
    for p in (a,b):p.evaluate("stopWorker('device')")
    before=digest(oldpages[index],index);candidate_old=digest(oldpages[candidate_index],candidate_index);hooks['posts']=0;database=databases[index];password=passwords[index]
    def once(p,worker,method,argument):
        return p.evaluate("""([url,method,argument])=>new Promise((resolve,reject)=>{const w=new Worker(url,{type:'module'}),timer=setTimeout(()=>{w.terminate();reject(Error('timeout'))},60000);w.onerror=()=>{clearTimeout(timer);w.terminate();reject(Error('worker'))};w.onmessage=({data})=>{if(data.boot){w.postMessage({id:1,method,argument});argument.password=null;}else if(data.id===1){clearTimeout(timer);w.terminate();resolve(data);}}})""",[worker,method,argument])
    # Separate real candidate fixture: exact saved package, no fabricated key.
    candidate_db='family-mls-candidate-synthetic-peer-ceremony';candidate_arg={'identity':candidate,'database':candidate_db,'password':passwords[candidate_index],'create':True}
    reply=once(oldpages[candidate_index],'/candidate-worker.js','proposal',candidate_arg);assert reply['ok'];proposal=reply['result'];saved_candidate=digest(oldpages[candidate_index],candidate_index,database=candidate_db)
    now=int(time.time());old=config['devices'][candidate_index];admin={'subject':'owner','actor':'alice'};config['version']=2;config['successors']={'administrators':[admin],'intents':[]};commit(2,config['people'])
    intent={'intent_id':'replace-'+candidate,'action':'replace','actor':candidate,'subject':['owner','family'][candidate_index],'predecessor':old['device_id'],'predecessor_key':old['signing_key'],'predecessor_revision':1,'candidate':candidate+'-candidate','signing_key':proposal['public_key'],'fingerprint':hashlib.sha256(bytes.fromhex(proposal['public_key'])).hexdigest(),'package_sha256':proposal['package_sha256'],'previous_room':'family','previous_group':group,'next_room':'successor-room','administrator':admin,'acceptance':'out-of-band-fingerprint','base_revision':3,'created_at':now-1,'expires_at':now+240,'status':'candidate','decided_at':0,'decision_revision':0}
    config['successors']['intents']=[intent];commit(3,config['people']);intent.update(status='accepted',decided_at=int(time.time()),decision_revision=5);old.update(status='revoked',device_revision=2);commit(4,config['people']);path='/v1/mls/successors/'+intent['intent_id']+'/reservation'
    subject=['owner','family'][index];device=pins[index]['device_id'];context_path='/v1/mls/successors/'+intent['intent_id']+'/context'
    for _ in range(100):
        code,context=direct(subject,'GET',context_path,device=device)
        if code==200:break
        time.sleep(.05)
    assert code==200 and direct(['owner','family'][candidate_index],'GET',context_path,device=old['device_id'])[0]==403
    code,expected=direct(subject,'POST',path,{'reservation_id':'peer-ceremony-reservation','context_sha256':hashlib.sha256(json.dumps(context,separators=(',',':')).encode()).hexdigest()},device=device);assert code==201
    assert expected['context']['peer']['signing_key']==pins[index]['signing_key'] and expected['context']['package_sha256']==proposal['package_sha256']
    reply=once(oldpages[candidate_index],'/candidate-worker.js','bind',{'identity':candidate,'database':candidate_db,'password':passwords[candidate_index],'intent':{'accepted':True,'reservation':expected}});assert reply['ok'] and reply['result']['package']==proposal['package'] and reply['result']['reservation_id']==expected['reservation_id']
    saved_candidate=digest(oldpages[candidate_index],candidate_index,database=candidate_db)
    proof['checks']['peer_actual_old_text_file_pending_and_saved_candidate_exact_reservation']=True
    def ui(i=index):
        p=page(i);url=p.url.rstrip('/')+'/peer-preparation/'
        p.add_init_script("""const OriginalWorker=Worker;window.Worker=class extends OriginalWorker{constructor(...args){super(...args);this.addEventListener('message',e=>{if(window.dropPeerReply&&e.data?.ok===true){window.peerReplyDropped=true;e.stopImmediatePropagation();}})}};""")
        p.goto(url);p.wait_for_function("()=>document.getElementById('run').disabled");return p
    def document(reservation=expected,db=database):return json.dumps({'version':1,'scopes':[{'identity':actor,'role':'peer','database':db,'reservation':reservation}]},separators=(',',':'))
    def confirmation(r=expected):return hashlib.sha256(json.dumps(r,separators=(',',':'),sort_keys=True).encode()).hexdigest()
    def load(p,raw=None):
        p.locator('#request-file').set_input_files({'name':'request.json','mimeType':'application/json','buffer':(document() if raw is None else raw).encode()});p.locator('#request-load').click();p.wait_for_function("()=>document.getElementById('request-status').textContent.includes('요청을 읽었습니다')||document.getElementById('request-status').textContent.includes('형식')")
    def select(p,db=database):
        p.locator('#identity').select_option(actor);p.locator('#database').fill(db);p.locator('#action').select_option('prepare');load(p,document(db=db));p.locator('#confirmation').fill(confirmation())
    def credentials(p,value=password):p.locator('#password').fill(value);p.locator('#consent').check()
    def finish(p,state):
        p.wait_for_function("()=>['prepared','unknown'].includes(document.getElementById('status').dataset.state)",timeout=70000);assert p.locator('#status').get_attribute('data-state')==state,(state,p.locator('#status').inner_text())
        assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
    def execute(p,state,value=password):credentials(p,value);assert not p.locator('#run').is_disabled();p.locator('#run').click();finish(p,state)
    def public(p):return json.loads(p.locator('#public-result').inner_text())
    def state(p):return digest(p,index)
    p=ui();assert p.locator('#identity').input_value()==p.locator('#action').input_value()=='' and p.locator('#export').is_disabled();assert state(p)==before
    proof['checks']['peer_dom_no_automatic_scope_action_worker_or_export']=True
    select(p);credentials(p);p.locator('#confirmation').fill('0'*64);assert p.locator('#run').is_disabled();p.locator('#confirmation').fill(confirmation());p.locator('#consent').uncheck();assert p.locator('#run').is_disabled()
    for raw in ('{}','x'*32769,document(db=database+'-substituted'),document().replace('"version":1','"version":2',1)):
        load(p,raw);credentials(p);p.locator('#confirmation').fill(confirmation());assert p.locator('#run').is_disabled() and state(p)==before
    proof['checks']['peer_dom_bounded_file_explicit_scope_independent_digest_fresh_consent']=True
    select(p,db=database+'-missing');execute(p,'unknown');assert p.evaluate("async n=>(await indexedDB.databases()).every(x=>x.name!==n)",database+'-missing')
    select(p);execute(p,'unknown','W'*48);assert state(p)==before
    proof['checks']['peer_dom_missing_store_never_created_wrong_password_retained']=True
    wrong=ui(candidate_index);select(wrong);execute(wrong,'unknown');assert wrong.locator('#export').is_disabled();wrong.close();assert state(p)==before
    proof['checks']['peer_dom_wrong_signed_identity_denied']=True
    bad=copy.deepcopy(expected);bad['context']['target_room']='substituted';select(p);load(p,document(bad));p.locator('#confirmation').fill(confirmation(bad));execute(p,'unknown');assert state(p)==before
    proof['checks']['peer_dom_substituted_hint_denied_by_current_authority']=True
    for mode in ('invalid-json','oversize','wrong-header','wrong-phase'):
        select(p);hook={'context':mode,'path':path,'seen':0};tamper[0]=hook
        try:execute(p,'unknown')
        finally:tamper[0]=None
        assert hook['seen']>=1 and state(p)==before
    proof['checks']['peer_dom_malformed_oversize_wrong_actor_stale_signed_read_denied']=True
    select(p);hooks['fault']=True
    try:execute(p,'unknown')
    finally:hooks['fault']=False
    assert state(p)==before and p.locator('#export').is_disabled()
    proof['checks']['peer_dom_actual_local_commit_abort_retains_entire_old_cipher_zero_export']=True
    select(p);p.evaluate('window.dropPeerReply=true');credentials(p);p.locator('#run').click();p.wait_for_function('()=>window.peerReplyDropped===true',timeout=70000)
    prepared=state(p);assert prepared!=before and p.locator('#export').is_disabled();p.locator('#lock').click();assert not p.locator('#uncertain').is_hidden();crash(index);p=ui();select(p);execute(p,'prepared');result=public(p);assert state(p)==prepared
    assert set(result)=={'version','identity','database','committed','phase','public_key','reservation_id','intent_id','room'} and bytes(result['public_key']).hex()==pins[index]['signing_key']
    restart();p.reload();select(p);execute(p,'prepared');assert public(p)==result and state(p)==prepared
    proof['checks']['peer_dom_committed_reply_loss_browser_server_restart_same_cipher_no_reseal']=True
    with p.expect_download() as download:p.locator('#export').click()
    assert json.loads(Path(download.value.path()).read_text())==result
    assert p.evaluate('()=>localStorage.length===0&&sessionStorage.length===0')
    proof['checks']['peer_dom_only_validated_public_receipt_export_no_secret_storage']=True
    tab=ui();select(p);select(tab);credentials(p);credentials(tab);p.locator('#run').click();tab.locator('#run').click();finish(p,'prepared');finish(tab,'prepared');assert public(p)==public(tab)==result and state(p)==prepared;tab.close()
    proof['checks']['peer_dom_concurrent_tabs_exact_same_prepared_slot']=True
    reply=once(p,'/peer-inspection-worker.js','successor',{'identity':actor,'database':database,'password':password,'intent':{'accepted':True,'reservation':expected}});assert reply['ok'] and reply['result']['test_source_digest']==source['digest'] and state(p)==prepared
    proof['checks']['peer_separate_readonly_private_inspection_full_source_provider_pending_unchanged']=True
    p.locator('#lock').click();assert p.locator('#public-result').inner_text()=='' and p.locator('#export').is_disabled();p.reload();assert p.locator('#identity').input_value()==p.locator('#action').input_value()=='' and p.locator('#password').input_value()=='' and state(p)==prepared
    proof['checks']['peer_dom_lock_restart_clear_output_credentials_no_auto_reopen']=True
    # Role Alice covers real expiry; role Bob isolates current revocation BEFORE
    # expiry. Both retain the same prepared bytes and deny before private output.
    if actor=='alice':
        remaining=expected['context']['expires_at']-time.time()+.1;assert 0<remaining<250,remaining;time.sleep(remaining);terminal='expiry'
    else:
        assert expected['context']['expires_at']-time.time()>10;config['devices'][index].update(status='revoked',device_revision=2);commit(5,config['people'])
        for _ in range(100):
            if direct(subject,'GET',path,device=device)[0]==403:break
            time.sleep(.05)
        else:raise AssertionError('current revocation reload')
        terminal='unexpired peer revocation'
    restart();select(p);execute(p,'unknown');assert state(p)==prepared and p.locator('#export').is_disabled()
    proof['checks']['peer_dom_current_terminal_authority_denial_after_server_restart_retains_custody']=True;proof['terminal_authority_case']=terminal
    cp=page(candidate_index);assert digest(cp,candidate_index)==candidate_old and digest(cp,candidate_index,database=candidate_db)==saved_candidate
    assert direct(subject,'GET','/v1/mls/rooms/family/log',device=device)[0]==403 and direct(subject,'GET','/v1/mls/rooms/successor-room/log',device=device)[0]==403 and hooks['posts']==0
    proof['checks']['peer_original_predecessor_candidate_package_tombstones_retained_no_post_or_activation']=True
    proof['peer_actor']=actor;proof['boundary']='Synthetic original-v1 to peer-v2 preparation UI only. Actual original compiled worker; old encrypted pair/candidate and administrator are explicit fixtures. Private inspection/abort fixtures separate. No full human acceptance, later format migration or production cutover.'
