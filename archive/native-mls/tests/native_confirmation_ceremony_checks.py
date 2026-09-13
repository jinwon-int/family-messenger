"""Original protected confirmation workers through the actual own-server DOM."""
import base64,copy,hashlib,json,threading,time,subprocess
from urllib.parse import urlsplit
from password_worker_smoke import safe_bytes

def compiled_assets(root,bundle,assets,proof,work):
    manifest=json.loads(safe_bytes(root/'server/internal/chat/confirmation_bundle.json',8192));compiled={}
    for e in manifest['files']:
        raw=safe_bytes(root/'server/internal/chat/confirmationassets'/e['file'],e['bytes'])
        assert len(raw)==e['bytes'] and hashlib.sha256(raw).hexdigest()==e['sha256'];compiled[e['url']]=raw
    # Separate instrumented aliases for fault and disposable private inspection only.
    for role in ('candidate','peer'):
        assets['/inspection-'+role+'-confirmation-worker.js']=assets['/'+role+'-confirmation-worker.js'].replace(b'./successor-confirmation-store.js',b'./inspection-confirmation-store.js').replace(b'./confirmation-worker.js',b'./inspection-confirmation-worker.js')
    assets['/inspection-confirmation-store.js']=assets['/successor-confirmation-store.js'];assets['/inspection-confirmation-worker.js']=assets['/confirmation-worker.js']
    source=safe_bytes(root/'experiments/device-keystore/successor-confirmation-store.js',65536);needle=b"await store.commit(before,after,'',live);";assert source.count(needle)==1
    source=source.replace(needle,b"await store.commit(before,after,'abort-after-write',live);")
    raw=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=successor-confirmation-store.js','--external:/pkg/*','--external:/trust-directory.js','--external:/handshake-wire.js','--external:/confirmation-wire.js'],input=source,cwd=root/'experiments/device-keystore',capture_output=True,check=True).stdout
    assets['/confirmation-fault-store.js']=raw
    for role in ('candidate','peer'):assets['/'+role+'-confirmation-worker.js']=compiled['/'+role+'-confirmation-worker.js'].replace(b'./successor-confirmation-store.js',b'./confirmation-fault-store.js')
    proof['confirmation_ui_compiled_expected_sha256']={k:hashlib.sha256(v).hexdigest() for k,v in compiled.items()}
    proof['confirmation_ui_separate_fixture_sha256']={k:hashlib.sha256(v).hexdigest() for k,v in assets.items() if k.startswith('/inspection-') or k=='/confirmation-fault-store.js'}
    return compiled

def route_checks(port,cookies,compiled,proof):
    from native_custody_ceremony_checks import route_checks as preceding
    preceding(port,cookies,compiled,proof)
    proof['checks']['confirmation_compiled_22_assets_signed_both_actors_exact_bytes_headers']=proof['checks'].pop('custody_compiled_22_assets_signed_both_actors_exact_bytes_headers')

def run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,source,proposal,database,candidate_actor):
    import copy
    peer_actor='alice' if candidate_actor=='bob' else 'bob';peer_subject='owner' if peer_actor=='alice' else 'family'
    def args(role):
        i=0 if role=='peer' else 1
        return {'identity':[peer_actor,candidate_actor][i],'database':databases[0] if i==0 else database,'password':passwords[i],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)}}
    def begin(p,role,arg=None,setup=None,submit=True):
        if setup is None:
            q=arg or args(role);origin='{0.scheme}://{0.netloc}'.format(urlsplit(p.url));p.goto(origin+'/confirmation-ceremony/');p.wait_for_selector('#run');p.evaluate('window.confirmationTestMode=true')
            assert p.locator('#identity').input_value()==p.locator('#role').input_value()==p.locator('#action').input_value()=='' and p.locator('#run').is_disabled()
            assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
            p.select_option('#identity',q['identity']);p.select_option('#role',role);p.fill('#database',q['database']);p.select_option('#action','confirm')
            doc={'version':1,'scopes':[{'identity':q['identity'],'role':role,'database':q['database'],'reservation':q['intent']['reservation']}]}
            p.locator('#request-file').set_input_files({'name':'request.json','mimeType':'application/json','buffer':json.dumps(doc).encode()});p.click('#request-load');p.wait_for_function("()=>document.getElementById('request-status').textContent.includes('요청을 읽었습니다')")
            p.fill('#confirmation',hashlib.sha256(json.dumps(q['intent']['reservation'],sort_keys=True,separators=(',',':')).encode()).hexdigest());p.fill('#password',q['password']);p.check('#consent')
            if submit:p.click('#run')
            return
        p.evaluate('window.confirmationTestMode=false')
        p.evaluate('''([role,arg,setup])=>{
          window.ew?.terminate();const w=new Worker('/inspection-'+role+'-confirmation-worker.js',{type:'module'});window.ew=w;
          window.confirmResult=new Promise(resolve=>{const timer=setTimeout(()=>{w.terminate();resolve({ok:false,timeout:true})},25000);w.onerror=e=>{clearTimeout(timer);resolve({ok:false,error:e.message})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'confirm',argument:arg});}else if(data.id===1||data.id===2){clearTimeout(timer);resolve(data.id===2?{ok:false}:data)}}});
        }''',[role,arg or args(role),setup])
    def done(p,reject=False):
        if p.evaluate('window.confirmationTestMode===true'):
            p.wait_for_function("()=>!['idle','locked','working'].includes(document.getElementById('status').dataset.state)",timeout=70000)
            state=p.locator('#status').get_attribute('data-state');assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
            if reject:assert state=='unknown' and p.locator('#export').is_disabled();return {'ok':False}
            assert state!='unknown',p.locator('#status').inner_text()
            return json.loads(p.locator('#public-result').inner_text())
        v=p.evaluate('window.confirmResult')
        if reject:assert not v['ok'] and 'result' not in v,v;return v
        assert v['ok'],v
        assert v['memory_bytes']<=128*1024*1024
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
        begin(p,role,submit=False);assert not p.locator('#run').is_disabled()
        p.fill('#confirmation','0'*64);assert p.locator('#run').is_disabled()
        for raw in ('{}','x'*32769):
            p.locator('#request-file').set_input_files({'name':'bad.json','mimeType':'application/json','buffer':raw.encode()});p.click('#request-load');p.wait_for_function("()=>document.getElementById('request-status').textContent.includes('형식')")
            p.fill('#password',args(role)['password']);p.check('#consent');assert p.locator('#run').is_disabled()
        assert snapshots()==original and not hooks['posts']
        hooks['ui_fault']=True
        try:confirm(p,role,reject=True)
        finally:hooks['ui_fault']=False
        assert snapshots()==original and not hooks['posts']
    proof['checks']['confirmation_dom_no_selection_bounded_files_independent_digest_and_no_post']=True
    proof['checks']['confirmation_actual_dom_local_abort_both_roles_zero_post_cipher_retained']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            confirm(p,role,setup={'testFault':fault},reject=True);assert snapshots()==original and not hooks['posts']
        for flag in ('testExpireBeforeCommit','testExpireAtCAS'):
            confirm(p,role,setup={flag:True},reject=True)
            assert snapshots()==original and not hooks['posts']
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
    proof['checks']['confirm_expiry_before_commit_and_at_cas_preserves_cipher_zero_posts']=True
    wait=confirm(a,'peer');assert not wait['peer_verified'] and wait['phase']=='awaiting-candidate-proof' and wait['state']=='awaiting-candidate'
    # Two candidate tabs own the same saved pending ciphertext even when no
    # request reaches the server. Both library sender transitions cannot commit.
    hooks['drop_before']=True;tab=page(1);begin(b,'candidate');begin(tab,'candidate');done(b,True);done(tab,True);hooks['drop_before']=False
    assert len(hooks['dropped'])==2 and hooks['dropped'][0]==hooks['dropped'][1] and not hooks['posts']
    pending=snapshots();crash(1);b=page(1)
    def lost(method,status,raw):return (status,b'{',False) if method=='POST' else (status,raw,False)
    hooks['callback']=lost;confirm(b,'candidate',reject=True);hooks['callback']=None
    assert hooks['posts']==[hooks['dropped'][0]] and snapshots()==pending
    crash(1);b=page(1);candidate=confirm(b,'candidate');assert not candidate['peer_verified'] and candidate['transcript_revision']==1 and candidate['state']=='candidate-recorded'
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
    crash(0);a=page(0);peer=confirm(a,'peer');assert peer['peer_verified'] and peer['state']=='peer-reply-recorded' and '확인할 수 없습니다' in a.locator('#status').inner_text()
    stable=snapshots()
    for fault in ('abort-before-write','abort-after-write'):
        confirm(b,'candidate',setup={'testFault':fault},reject=True);assert snapshots()==stable and len(hooks['posts'])==2
    for payload in (base64.b64encode(b'invalid peer proof').decode(),hooks['posts'][0]['payload']):
        hooks['callback']=substitute(payload,1)
        try:confirm(b,'candidate',reject=True)
        finally:hooks['callback']=None
        assert snapshots()==stable
    if 'lease' in hooks:
        from native_lease_checks import reject_premature
        reject_premature(b,'candidate',args('candidate'));assert snapshots()==stable and not hooks['lease']['posts']
        proof['checks']['lease_rejects_public_complete_confirmation_before_candidate_private_receive_commit']=True
    candidate=confirm(b,'candidate');assert candidate['peer_verified'] and candidate['group_id']==peer['group_id'] and candidate['transcript_revision']==peer['transcript_revision']==2
    assert candidate['state']=='candidate-verified'
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
    a.click("#lock");release.set();done(a,True);hooks['callback']=None
    arrived.clear();release.clear();hooks['callback']=held
    try:confirm(b,'candidate',reject=True)
    finally:release.set();hooks['callback']=None
    assert snapshots()==stable and len(hooks['posts'])==2
    for p,role in ((a,'peer'),(b,'candidate')):
        bad=args(role);bad['intent']['reservation']['context']['expires_at']=1;confirm(p,role,bad,reject=True)
    assert direct(peer_subject,'GET','/v1/mls/rooms/successor-room/log')[0]==403
    if 'lease' in hooks:
        from native_lease_checks import run as lease_run
        lease_run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks['lease'],expected,source,proposal,database,candidate_actor)
        return
    if candidate_actor=='bob':
        remaining=expected['context']['expires_at']-time.time()+.1;assert 0<remaining<490;time.sleep(remaining);proof['terminal_authority_case']='expiry'
    else:
        assert expected['context']['expires_at']>time.time()+5
        next(d for d in config['devices'] if d['actor']==peer_actor).update(status='revoked',device_revision=2);commit(5,config['people'])
        deadline=time.monotonic()+6
        while time.monotonic()<deadline:
            if direct(peer_subject,'GET','/v1/mls/successors/replace-bob/reservation')[0]==403:break
            time.sleep(.05)
        else:raise AssertionError('revocation reload')
        proof['terminal_authority_case']='unexpired peer revocation'
    restart()
    for p,role in ((a,'peer'),(b,'candidate')):confirm(p,role,reject=True)
    assert snapshots()==stable and len(hooks['posts'])==2
    proof['checks']['confirmation_malformed_stale_lock_timeout_expiry_revocation_retains_state']=True
    proof['candidate_actor']=candidate_actor
    proof['checks']['confirmation_actual_dom_both_roles_fresh_credentials_stage_specific_status']=True
    proof['boundary']='Actual protected MLS peer confirmation only; server opaque receipts are not proof; no active admission or production cutover'
