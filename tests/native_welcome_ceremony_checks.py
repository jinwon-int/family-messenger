"""Exact saved-package Welcome exchange using two encrypted browser stores."""
import copy
import hashlib
import json
import os
import subprocess
import threading
import time
from password_worker_smoke import safe_bytes


def compiled_assets(root,bundle,assets,proof,work):
    from native_custody_ceremony_checks import compiled_assets as preceding
    compiled=preceding(root,bundle,assets,proof,work,profile='welcome')
    for role in ('candidate','peer'):
        assets['/inspection-'+role+'-exchange-worker.js']=assets['/'+role+'-exchange-worker.js'].replace(b'./successor-exchange-store.js',b'./inspection-exchange-store.js').replace(b'./exchange-worker.js',b'./inspection-exchange-worker.js')
    assets['/inspection-exchange-store.js']=assets['/successor-exchange-store.js'];assets['/inspection-exchange-worker.js']=assets['/exchange-worker.js']
    source=safe_bytes(root/'experiments/device-keystore/successor-exchange-store.js',65536);needle=b"await store.commit(before,after,'',live);";assert source.count(needle)==1
    source=source.replace(needle,b"await store.commit(before,after,'abort-after-write',live);")
    raw=subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=successor-exchange-store.js','--external:/pkg/*','--external:/trust-directory.js','--external:/handshake-wire.js'],input=source,cwd=root/'experiments/device-keystore',capture_output=True,check=True).stdout
    assets['/welcome-fault-store.js']=raw
    for role in ('candidate','peer'):assets['/'+role+'-exchange-worker.js']=compiled['/'+role+'-exchange-worker.js'].replace(b'./successor-exchange-store.js',b'./welcome-fault-store.js')
    proof['welcome_separate_fixture_sha256']={k:hashlib.sha256(v).hexdigest() for k,v in assets.items() if k.startswith('/inspection-') or k=='/welcome-fault-store.js'}
    return compiled


def route_checks(port,cookies,compiled,proof):
    from native_custody_ceremony_checks import route_checks as preceding
    preceding(port,cookies,compiled,proof)
    proof['checks']['welcome_compiled_31_assets_signed_both_actors_exact_bytes_headers']=proof['checks'].pop('custody_compiled_22_assets_signed_both_actors_exact_bytes_headers')


def run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks,expected,source,proposal,database,candidate_actor='bob'):
    peer_actor='alice' if candidate_actor=='bob' else 'bob'
    peer_subject='owner' if peer_actor=='alice' else 'family'
    from urllib.parse import urlsplit
    for p in (a,b):p.evaluate("stopWorker('device')")
    def args(role):
        i=0 if role=='peer' else 1
        return {'identity':[peer_actor,candidate_actor][i],'database':databases[0] if i==0 else database,'password':passwords[i],'intent':{'accepted':True,'reservation':copy.deepcopy(expected)}}
    def begin(p,role,arg=None,setup=None,submit=True):
        if setup is None:
            q=arg or args(role);origin='{0.scheme}://{0.netloc}'.format(urlsplit(p.url));p.goto(origin+'/welcome-ceremony/');p.wait_for_selector('#run');p.evaluate('window.welcomeTestMode=true')
            assert p.locator('#identity').input_value()==p.locator('#role').input_value()==p.locator('#action').input_value()=='' and p.locator('#run').is_disabled()
            assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
            p.select_option('#identity',q['identity']);p.select_option('#role',role);p.fill('#database',q['database']);p.select_option('#action','exchange')
            doc={'version':1,'scopes':[{'identity':q['identity'],'role':role,'database':q['database'],'reservation':q['intent']['reservation']}]}
            p.locator('#request-file').set_input_files({'name':'request.json','mimeType':'application/json','buffer':json.dumps(doc).encode()});p.click('#request-load');p.wait_for_function("()=>document.getElementById('request-status').textContent.includes('요청을 읽었습니다')")
            p.fill('#confirmation',hashlib.sha256(json.dumps(q['intent']['reservation'],sort_keys=True,separators=(',',':')).encode()).hexdigest());p.fill('#password',q['password']);p.check('#consent')
            if submit:p.click('#run')
            return
        p.evaluate('window.welcomeTestMode=false')
        p.evaluate('''([role,arg,setup])=>{
          window.ew?.terminate();const w=new Worker('/inspection-'+role+'-exchange-worker.js',{type:'module'});window.ew=w;
          window.exchangeResult=new Promise(resolve=>{const timer=setTimeout(()=>{w.terminate();resolve({ok:false,timeout:true})},25000);w.onerror=e=>{clearTimeout(timer);resolve({ok:false,error:e.message})};w.onmessage=({data})=>{if(data.boot){if(setup)w.postMessage({testSetup:setup});w.postMessage({id:1,method:'exchange',argument:arg});}else if(data.id===1||data.id===2){clearTimeout(timer);resolve(data.id===2?{ok:false}:data)}}});
        }''',[role,arg or args(role),setup])
    def done(p,reject=False):
        if p.evaluate('window.welcomeTestMode===true'):
            p.wait_for_function("()=>!['idle','locked','working'].includes(document.getElementById('status').dataset.state)",timeout=70000)
            state=p.locator('#status').get_attribute('data-state');assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
            if reject:assert state=='unknown' and p.locator('#export').is_disabled();return {'ok':False}
            assert state!='unknown',p.locator('#status').inner_text()
            return json.loads(p.locator('#public-result').inner_text())
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
        begin(p,role,submit=False);assert not p.locator('#run').is_disabled()
        p.fill('#confirmation','0'*64);assert p.locator('#run').is_disabled()
        for raw in ('{}','x'*32769):
            p.locator('#request-file').set_input_files({'name':'bad.json','mimeType':'application/json','buffer':raw.encode()});p.click('#request-load');p.wait_for_function("()=>document.getElementById('request-status').textContent.includes('형식')")
            p.fill('#confirmation',hashlib.sha256(json.dumps(expected,sort_keys=True,separators=(',',':')).encode()).hexdigest());p.fill('#password',args(role)['password']);p.check('#consent');assert p.locator('#run').is_disabled()
        assert snapshots()==original and not hooks['posts']
    proof['checks']['welcome_dom_no_selection_or_post_bounded_file_independent_digest']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        hooks['ui_fault']=True
        try:exchange(p,role,reject=True)
        finally:hooks['ui_fault']=False
        assert snapshots()==original and not hooks['posts']
    proof['checks']['welcome_actual_dom_both_local_abort_zero_posts_cipher_retained']=True
    for p,role in ((a,'peer'),(b,'candidate')):
        for fault in ('abort-before-write','abort-after-write'):
            exchange(p,role,setup={'testFault':fault},reject=True)
            assert snapshots()==original and not hooks['posts']
        for flag in ('testExpireBeforeCommit','testExpireAtCAS'):
            exchange(p,role,setup={flag:True},reject=True)
            assert snapshots()==original and not hooks['posts']
        bad=args(role);bad['database']+='-missing';exchange(p,role,bad,reject=True)
        bad=args(role);bad['password']='w'*48;exchange(p,role,bad,reject=True)
        assert snapshots()==original and not hooks['posts']
    proof['checks']['exchange_local_abort_missing_wrong_password_zero_handshake_posts']=True
    proof['checks']['exchange_expiry_before_commit_and_at_cas_preserves_cipher_zero_posts']=True
    # Peer may wait first without generating a group or sending anything.
    if candidate_actor=='bob':
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
    if 'confirmation' in hooks:
        from native_confirmation_checks import run as confirm_run
        confirm_run(a,b,databases,proof,page,passwords,direct,config,commit,crash,digest,restart,hooks['confirmation'],expected,source,proposal,database,candidate_actor)
        return
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
    a.click("#lock");release.set();done(a,True);hooks['callback']=None
    assert snapshots()==stable
    arrived.clear();release.clear();hooks['callback']=held
    try:exchange(b,'candidate',reject=True)
    finally:release.set();hooks['callback']=None
    assert snapshots()==stable
    for p,role in ((a,'peer'),(b,'candidate')):
        bad=args(role);bad['intent']['reservation']['context']['expires_at']=1;exchange(p,role,bad,reject=True)
        assert snapshots()==stable
    assert direct('owner','GET','/v1/mls/rooms/successor-room/log')[0]==403
    if candidate_actor=='bob':
        remaining=expected['context']['expires_at']-time.time()+.1;assert 0<remaining<370;time.sleep(remaining);proof['terminal_authority_case']='expiry'
    else:
        assert expected['context']['expires_at']>time.time()+5
        next(d for d in config['devices'] if d['actor']==peer_actor).update(status='revoked',device_revision=2);commit(5,config['people']);time.sleep(1.2);proof['terminal_authority_case']='unexpired peer revocation'
    restart()
    for p,role in ((a,'peer'),(b,'candidate')):exchange(p,role,reject=True)
    assert snapshots()==stable and len(hooks['posts'])==3
    proof['checks']['lock_expiry_revocation_retains_private_state_no_native_activation']=True
    proof['candidate_actor']=candidate_actor
    proof['checks']['welcome_actual_dom_actions_fresh_credentials_both_roles']=True
    proof['boundary']='Synthetic exact-package Welcome private continuity only; empty server ack is not possession proof; no activation, production or human recovery'
