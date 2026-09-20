"""Real candidate DOM + original compiled worker; old pair is a separate fixture."""
import copy
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import time
from password_worker_smoke import safe_bytes


def compiled_assets(root,bundle,assets,proof,work):
    path=root/'server/internal/chat/candidate_bundle.json';manifest=json.loads(safe_bytes(path,8192));compiled={}
    for e in manifest['files']:
        raw=safe_bytes(bundle/e['source'][7:] if e['source'].startswith('bundle:') else root/e['source'],2*1024*1024)
        assert len(raw)==e['bytes'] and hashlib.sha256(raw).hexdigest()==e['sha256'];compiled[e['url']]=raw
    source=safe_bytes(root/'experiments/device-keystore/candidate-store.js',65536)
    needle=b'export class CandidateStore extends NativeVaultStore {';assert source.count(needle)==1
    fault=source.replace(needle,needle+b"\n async commit(before,after,fault,live){return super.commit(before,after,'abort-after-write',live);}\n")
    r=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=candidate-store.js','--external:/pkg/*','--external:/trust-directory.js'],input=fault,cwd=root/'experiments/device-keystore',check=True,capture_output=True)
    assets['/candidate-fault-store.js']=r.stdout
    worker=compiled['/candidate-worker.js'];assert worker.count(b"'./candidate-store.js'")==1
    assets['/candidate-worker.js']=worker.replace(b"'./candidate-store.js'",b"'./candidate-fault-store.js'")
    proof['candidate_fault_fixture_sha256']={k:hashlib.sha256(assets[k]).hexdigest() for k in ('/candidate-worker.js','/candidate-fault-store.js')}
    proof['candidate_compiled_manifest_sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
    proof['candidate_compiled_expected_sha256']={k:hashlib.sha256(v).hexdigest() for k,v in compiled.items()}
    proof['candidate_ceremony_boundary']='Normal candidate page/worker graph from compiled Go, original protected store; old pair fixture and explicit abort-only worker/store separately served.'
    return compiled


def route_checks(port,cookies,compiled,proof):
    for path,raw in compiled.items():
        for cookie,status in ((None,401),(cookies[0],200),(cookies[1],200)):
            c=http.client.HTTPConnection('127.0.0.1',port,timeout=10);c.request('GET',path,headers={'Cookie':'synthetic_edge='+cookie} if cookie else {});r=c.getresponse();data=r.read();c.close();assert r.status==status
            if status==200:assert data==raw and r.getheader('X-Content-Type-Options')=='nosniff' and r.getheader('Cache-Control')=='no-store'
    for path in ('/candidate_bundle.json','/candidateassets/pkg.wasm','/candidate-preparation/unknown','/successor/'):
        c=http.client.HTTPConnection('127.0.0.1',port,timeout=10);c.request('GET',path,headers={'Cookie':'synthetic_edge='+cookies[0]});r=c.getresponse();r.read();c.close();assert r.status>=400
    proof['checks']['candidate_compiled_15_assets_signed_both_actors_exact_bytes_headers']=True
    proof['checks']['candidate_compiled_unknown_and_other_profile_routes_denied']=True


def run(a,b,databases,rpc,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,tamper,restart,hooks,actor):
    index=['alice','bob'].index(actor);peer_index=1-index;peer=['alice','bob'][peer_index]
    group=rpc(a,'status')['group_id'];prepare(a,'app-old-text',b'generated prior conversation');rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
    prepare(b,'app-old-file',bytes(range(256))*32,'file');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync');rpc(a,'update',{'id':'update-old-pending','fault':''})
    for p in (a,b):p.evaluate("stopWorker('device')")
    old_sources=[digest(a,0),digest(b,1)];hooks['posts']=0;database='family-mls-candidate-synthetic-'+actor+'-ceremony';password=passwords[index]
    # Page instrumentation drops a real committed response without forging success.
    def ui(i=index):
        p=page(i);url=p.url.rstrip('/')+'/candidate-preparation/'
        p.add_init_script("""const OriginalWorker=Worker;window.Worker=class extends OriginalWorker{constructor(...args){super(...args);this.addEventListener('message',e=>{if(window.dropCandidateReply&&e.data?.ok===true){window.candidateReplyDropped=true;e.stopImmediatePropagation();}})}};""")
        p.goto(url);p.wait_for_function("()=>document.getElementById('run').disabled");return p
    def select(p,kind,db=None,identity=actor):
        p.locator('#identity').select_option(identity);p.locator('#database').fill(db or database);p.locator('#database').press('Tab');p.locator('#action').select_option(kind)
    def credentials(p):p.locator('#password').fill(password);p.locator('#consent').check()
    def finish(p,state):
        p.wait_for_function("()=>['proposal','bound','unknown'].includes(document.getElementById('status').dataset.state)",timeout=70000)
        assert p.locator('#status').get_attribute('data-state')==state,(state,p.locator('#status').inner_text())
    def execute(p,state):credentials(p);assert not p.locator('#run').is_disabled();p.locator('#run').click();finish(p,state);assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
    def public(p):return json.loads(p.locator('#public-result').inner_text())
    def state(p):return digest(p,index,database=database)
    p=ui();assert p.locator('#identity').input_value()==p.locator('#action').input_value()=='' and p.locator('#export').is_disabled()
    proof['checks']['candidate_dom_no_automatic_scope_action_worker_or_export']=True
    select(p,'reopen');execute(p,'unknown');assert p.locator('#export').is_disabled()
    # Reopen failure records the attempted name: use an explicitly different fresh
    # scope rather than resetting a potentially uncertain database.
    database+='-new';select(p,'create');p.evaluate('window.dropCandidateReply=true');credentials(p);p.locator('#run').click();p.wait_for_function('()=>window.candidateReplyDropped===true',timeout=70000);created=state(p);assert p.locator('#export').is_disabled();p.locator('#lock').click();crash(index);p=ui();select(p,'create');execute(p,'unknown');assert state(p)==created;select(p,'reopen');execute(p,'proposal');proposal=public(p);before=state(p);assert before==created
    proof['checks']['candidate_dom_creation_committed_reply_loss_restart_no_key_regeneration']=True
    assert set(proposal)=={'version','identity','database','committed','phase','public_key','package','package_sha256','reservation_id'} and proposal['identity']==actor and proposal['database']==database
    assert hashlib.sha256(bytes.fromhex(proposal['package'])).hexdigest()==proposal['package_sha256']
    with p.expect_download() as download:p.locator('#export').click()
    assert json.loads(Path(download.value.path()).read_text())==proposal
    proof['checks']['candidate_dom_actual_encrypted_commit_before_public_export_exact_package']=True
    select(p,'create');execute(p,'unknown');assert state(p)==before
    select(p,'reopen');execute(p,'proposal');assert public(p)==proposal and state(p)==before
    crash(index);p=ui();assert p.locator('#public-result').inner_text()=='';select(p,'create');p.wait_for_function("()=>!document.getElementById('attempt').hidden");execute(p,'unknown');assert state(p)==before
    select(p,'reopen');execute(p,'proposal');assert public(p)==proposal and state(p)==before
    proof['checks']['candidate_dom_restart_attempt_marker_no_recreation_exact_reopen']=True
    outer=p.evaluate("""async name=>{const d=await new Promise(r=>{let q=indexedDB.open(name);q.onsuccess=()=>r(q.result)});const s=await new Promise(r=>{let q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result)});d.close();return Object.keys(s).sort()}""",database)
    assert outer==sorted(['v','identity','room','vault','revision','capsule','header','cipher'])
    assert p.evaluate("""async()=>{const d=await new Promise(r=>{const q=indexedDB.open('family-candidate-preparation-attempts-v1');q.onsuccess=()=>r(q.result)});const values=await new Promise(r=>{const q=d.transaction('attempts').objectStore('attempts').getAll();q.onsuccess=()=>r(q.result)});d.close();return values.length>0&&values.every(v=>v===1)&&localStorage.length===0}""")
    proof['checks']['candidate_dom_no_private_output_or_credentials_in_public_attempt_storage']=True
    wrong=ui(peer_index);select(wrong,'reopen');execute(wrong,'unknown');assert wrong.locator('#export').is_disabled();wrong.close();assert state(p)==before
    proof['checks']['candidate_dom_expected_signed_actor_mismatch_denied']=True
    # Synthetic administrator receives the actual exported proposal. The page
    # never installs policy or derives acceptance from its public input file.
    now=int(time.time());old=config['devices'][index];admin={'subject':'owner','actor':'alice'};config['version']=2;config['successors']={'administrators':[admin],'intents':[]};commit(2,config['people'])
    intent={'intent_id':'replace-'+actor,'action':'replace','actor':actor,'subject':['owner','family'][index],'predecessor':old['device_id'],'predecessor_key':old['signing_key'],'predecessor_revision':1,'candidate':actor+'-candidate','signing_key':proposal['public_key'],'fingerprint':hashlib.sha256(bytes.fromhex(proposal['public_key'])).hexdigest(),'package_sha256':proposal['package_sha256'],'previous_room':'family','previous_group':group,'next_room':'successor-room','administrator':admin,'acceptance':'out-of-band-fingerprint','base_revision':3,'created_at':now-1,'expires_at':now+240,'status':'candidate','decided_at':0,'decision_revision':0}
    config['successors']['intents']=[intent];commit(3,config['people']);intent.update(status='accepted',decided_at=int(time.time()),decision_revision=5);old.update(status='revoked',device_revision=2);commit(4,config['people']);path='/v1/mls/successors/'+intent['intent_id']+'/reservation'
    peer_subject=['owner','family'][peer_index];peer_device=pins[peer_index]['device_id'];context_path='/v1/mls/successors/'+intent['intent_id']+'/context'
    for _ in range(100):
        code,context=direct(peer_subject,'GET',context_path,device=peer_device)
        if code==200:break
        time.sleep(.05)
    assert code==200
    assert direct(['owner','family'][index],'GET',context_path,device=old['device_id'])[0]==403
    proof['checks']['candidate_dom_revoked_predecessor_denied_intact_peer_explicit_authority']=True
    code,expected=direct(peer_subject,'POST',path,{'reservation_id':'ceremony-reservation','context_sha256':hashlib.sha256(json.dumps(context,separators=(',',':')).encode()).hexdigest()},device=peer_device);assert code==201
    def document(reservation=expected,db=None):return json.dumps({'version':1,'scopes':[{'identity':actor,'role':'candidate','database':db or database,'reservation':reservation}]},separators=(',',':'))
    confirmation=hashlib.sha256(json.dumps(expected,separators=(',',':'),sort_keys=True).encode()).hexdigest()
    def load(p,raw=None):p.locator('#request-file').set_input_files({'name':'request.json','mimeType':'application/json','buffer':(raw or document()).encode()});p.locator('#request-load').click();p.wait_for_function("()=>document.getElementById('request-status').textContent.includes('요청을 읽었습니다')||document.getElementById('request-status').textContent.includes('형식')")
    def binding(p):select(p,'bind');load(p);p.locator('#confirmation').fill(confirmation)
    binding(p);credentials(p);p.locator('#confirmation').fill('0'*64);assert p.locator('#run').is_disabled();p.locator('#confirmation').fill(confirmation);assert not p.locator('#run').is_disabled()
    for raw in ('{}','x'*32769,document(db=database+'-substituted'),document().replace('"version":1','"version":2',1)):
        load(p,raw);credentials(p);p.locator('#confirmation').fill(confirmation);assert p.locator('#run').is_disabled() and state(p)==before
    proof['checks']['candidate_dom_bounded_single_scope_file_independent_digest_and_consent_required']=True
    binding(p)
    bad=copy.deepcopy(expected);bad['context']['target_room']='substituted';load(p,document(bad));p.locator('#confirmation').fill(hashlib.sha256(json.dumps(bad,separators=(',',':'),sort_keys=True).encode()).hexdigest());execute(p,'unknown');assert state(p)==before
    proof['checks']['candidate_dom_substituted_accepted_hint_denied_by_current_authority']=True
    for mode in ('invalid-json','oversize','wrong-header','wrong-phase'):
        binding(p);hook={'context':mode,'path':path,'seen':0};tamper[0]=hook
        try:execute(p,'unknown')
        finally:tamper[0]=None
        assert hook['seen']>=1 and state(p)==before
    proof['checks']['candidate_dom_malformed_oversize_wrong_actor_stale_signed_read_denied']=True
    # Explicit fault fixture changes only the worker/store for this one call.
    binding(p);hooks['fault']=True
    try:execute(p,'unknown')
    finally:hooks['fault']=False
    assert state(p)==before and p.locator('#export').is_disabled()
    proof['checks']['candidate_dom_actual_local_commit_abort_retains_exact_proposal_no_export']=True
    binding(p);p.evaluate('window.dropCandidateReply=true');credentials(p);p.locator('#run').click();p.wait_for_function('()=>window.candidateReplyDropped===true',timeout=70000)
    bound=state(p);assert bound!=before and p.locator('#export').is_disabled();p.locator('#lock').click();assert not p.locator('#uncertain').is_hidden();crash(index);p=ui();binding(p);execute(p,'bound');result=public(p);assert state(p)==bound
    assert all(result[k]==proposal[k] for k in ('public_key','package','package_sha256')) and result['reservation_id']==expected['reservation_id']
    restart();p.reload();binding(p);execute(p,'bound');assert public(p)==result and state(p)==bound
    proof['checks']['candidate_dom_real_committed_reply_loss_browser_server_restart_exact_bind_reconciliation']=True
    tab=ui();binding(p);binding(tab);credentials(p);credentials(tab);p.locator('#run').click();tab.locator('#run').click();finish(p,'bound');finish(tab,'bound');assert public(p)==public(tab)==result and state(p)==bound;tab.close()
    proof['checks']['candidate_dom_concurrent_tabs_exact_same_binding_no_reseal']=True
    p.locator('#lock').click();assert p.locator('#public-result').inner_text()=='' and p.locator('#export').is_disabled()
    select(p,'reopen');execute(p,'unknown');assert state(p)==bound
    proof['checks']['candidate_dom_lock_clears_public_output_bound_generic_reopen_denied']=True
    # Real expiry, no worker time override. Existing bound bytes must be retained.
    remaining=expected['context']['expires_at']-time.time()+.1;assert 0<remaining<250,remaining;time.sleep(remaining)
    binding(p);execute(p,'unknown');assert state(p)==bound and p.locator('#export').is_disabled()
    proof['checks']['candidate_dom_actual_intent_expiry_denies_binding_retains_exact_saved_package']=True
    config['devices'][peer_index].update(status='revoked',device_revision=2);commit(5,config['people']);time.sleep(1.1);restart();binding(p);execute(p,'unknown');assert state(p)==bound
    aa,bb=page(0),page(1);assert [digest(aa,0),digest(bb,1)]==old_sources
    assert direct('owner','GET','/v1/mls/rooms/family/log')[0]==403 and direct('owner','GET','/v1/mls/rooms/successor-room/log')[0]==403
    assert hooks['posts']==0
    proof['checks']['candidate_dom_expired_revoked_tombstones_original_pair_pending_retained_zero_post']=True
    proof['candidate_actor']=actor;proof['boundary']='Synthetic candidate proposal and exact reservation binding UI only. Actual original protected custody; no declarations, activation, full human ceremony or production cutover.'
