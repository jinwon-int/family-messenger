"""Generated signed native clients; no product UI or human/device migration."""
import hashlib
import json
import os
import stat
import subprocess
import time
from password_worker_smoke import safe_bytes


def aggregate_assets(root, work, assets):
    st=work.lstat()
    assert stat.S_ISDIR(st.st_mode) and st.st_uid==os.getuid() and stat.S_IMODE(st.st_mode)==0o700
    assert not any(p.is_symlink() for p in (work,*work.parents))
    def write_new(path,raw):
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
    for name in ('aggregate-native-worker.js', 'aggregate-fork-worker.js'):
        assets['/' + name] = safe_bytes(root / 'experiments/openmls-browser/web' / name, 65536)
    main = safe_bytes(root / 'tests/fixtures/native-vault/main.js', 65536)
    main = main.replace(b"'./vault-native-worker.js'", b"name==='fork'?'./aggregate-fork-worker.js':'./aggregate-native-worker.js'")
    main = main.replace(b"!data.ok||method==='lock'", b"!data.ok||method==='lock'||method==='fork'")
    assets['/main.js'] = main
    cwd = root / 'experiments/device-keystore'
    source = safe_bytes(cwd / 'aggregate-store.js', 65536)
    def build(raw, target):
        result=subprocess.run(['node', 'node_modules/esbuild/bin/esbuild', '--bundle', '--format=esm', '--platform=browser', '--target=es2023', '--minify',
                        '--sourcefile=aggregate-store.js', '--external:/pkg/*', '--external:/trust-directory.js',
                        '--alias:age-encryption=' + str(cwd / 'node_modules/age-encryption'),
                        '--alias:libsodium-wrappers=' + str(cwd / 'node_modules/libsodium-wrappers')],
                       input=raw, cwd=cwd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert len(result.stdout)<1024*1024
        write_new(target,result.stdout)
        return result.stdout
    original = build(source, work / 'aggregate-store-original.js')
    base = safe_bytes(cwd / 'native-vault-store.js', 65536)
    marker = b"if(after)s.put(after,'state');if(fault==='abort-after-write')"
    assert base.count(marker) == 1
    base = base.replace(marker, b"if(after)s.put(after,'state');if(fault==='crash-before-complete'){self.postMessage({test_crash_boundary:true});while(true){}}if(fault==='abort-after-write')")
    path = work / 'aggregate-base-instrumented.js'
    write_new(path,base)
    source = source.replace(b"'./native-vault-store.js'", json.dumps(str(path)).encode())
    marker = b'await admit(a);live();await this.commit(before,after,fault,live);'
    assert source.count(marker) == 1
    source = source.replace(marker, b"if(after&&self.testAggregateHold){self.testAggregateHold=false;self.postMessage({test_aggregate_cas:true});await new Promise(resolve=>{self.testAggregateRelease=resolve;});}" + marker)
    marker = b'live();await admit(a);live();const result=operation(a);'
    assert source.count(marker) == 1
    source = source.replace(marker, marker + b"self.testAggregateInspection=a.rooms.map(r=>({room:r.room,digest:sodium.to_hex(sodium.crypto_generichash(32,enc.encode(JSON.stringify({...r,crypto:b64(r.crypto)})))),group:r.group,pending:r.pending?.request.client_id??null}));")
    source=source.replace(b'validateAggregate,fresh,publicKey}',b'validateAggregate,fresh,publicKey,checksum as testChecksum,validateRecord as testValidateRecord}')
    marker=b'candidate=encode(a);'
    assert source.count(marker)==1
    source=source.replace(marker,marker+b'''if(self.testAggregateForge&&(!original||candidate.length!==original.length||candidate.some((v,i)=>v!==original[i]))){
     const mode=self.testAggregateForge;self.testAggregateForge=null;const forged=structuredClone(a);
     if(mode==='duplicate-room')forged.rooms[1].room=forged.rooms[0].room;
     else if(mode==='wrong-actor')forged.rooms[1].identity='bob';
     else if(mode==='wrong-epoch'){forged.rooms[1].epoch++;forged.rooms[1].checksum=testChecksum(forged.rooms[1]);}
     else if(mode==='combined-quota'){
      for(const r of forged.rooms){const p=JSON.parse(dec.decode(r.crypto)),entry=[[250,251,252],[]];p.entries.push(entry);const n=Math.floor((1048000-enc.encode(JSON.stringify(p)).length)/2);if(n<1)fail();entry[1]=Array(n).fill(0);r.crypto=enc.encode(JSON.stringify(p));r.checksum=testChecksum(r);testValidateRecord(r,this.identity);}
      self.testAggregateQuotaIndividuallyValid=true;
     }else fail();candidate=encode(forged);
    }''')
    assets['/aggregate-store.js'] = build(source, work / 'aggregate-store-instrumented.js')
    return original


def aggregate_checks(a,b,databases,rpc,init,reopen,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,hold_next,arrived,release,tamper):
    def inspect(p):
        return rpc(p, 'test-aggregate-digest')
    def open_room(p,i,room):
        p.evaluate("async()=>{stopWorker('device');await spawn('device')}")
        return init(p,i,selected_room=room)
    def fork(p,i,intent,reject=False,password=None):
        p.evaluate("spawn('fork')")
        arg={'identity':['alice','bob'][i],'database':databases[i],'password':password or passwords[i],'intent':intent}
        r=p.evaluate('arg=>call("fork","fork",arg)',arg)
        if reject:
            assert not r['ok'] and 'result' not in r
            return
        assert r['ok'],r
        return r['result']
    group=rpc(a,'status')['group_id']
    intent={'id':'context-second','source':'family','target':'second','source_group':group,'pins':pins}
    assert direct('owner','POST','/v1/mls/reservations',{'room':'second','peer_actor':'bob'})[0]==201
    # Preserve an exact unaccepted source application while creating new contexts.
    prepare(a,'app-old-pending',b'synthetic source still pending')
    stable=digest(a,0)
    assert direct('owner','POST','/v1/rooms',{'id':'legacy-target','members':['bob']})[0]==201
    assert direct('owner','GET','/v1/rooms/legacy-target/devices')[0]==200
    fork(a,0,{**intent,'id':'context-legacy','target':'legacy-target'},reject=True)
    assert digest(a,0)==stable
    assert direct('owner','GET','/v1/rooms/legacy-target/messages')[0]==200
    assert direct('owner','POST','/v1/mls/rooms',{'room':'bound-target','group_id':'ca'*32,'device_id':pins[0]['device_id'],'peer_device':pins[1]['device_id']})[0]==201
    fork(a,0,{**intent,'id':'context-bound','target':'bound-target'},reject=True)
    assert digest(a,0)==stable
    proof['checks']['legacy_or_already_bound_target_denied_before_immutable_slot_commit']=True

    # Actual worker fetches must validate the entire bounded signed context.
    for mode in ('invalid-json','oversize','wrong-room','wrong-key','duplicate-pin','wrong-phase','wrong-header'):
        hook={'context':mode,'seen':0,'path':'/v1/mls/rooms/second/context'};tamper[0]=hook
        try:
            fork(a,0,intent,reject=True)
            assert hook['seen']==1
        finally:tamper[0]=None
        assert digest(a,0)==stable
    proof['checks']['bounded_context_body_pins_room_phase_and_actor_header_validated']=True

    # The second admission must use the original "creating" decision even
    # though the staged candidate now has a.fork. Bind a real reserved target
    # immediately after the first context read, then require denial before CAS.
    assert direct('owner','POST','/v1/mls/reservations',{'room':'raced-target','peer_actor':'bob'})[0]==201
    def advance_target():
        assert direct('owner','POST','/v1/mls/rooms',{'room':'raced-target','group_id':'cb'*32,'device_id':pins[0]['device_id'],'peer_device':pins[1]['device_id']})[0]==201
    hook={'context':'advance','path':'/v1/mls/rooms/raced-target/context','seen':0,'after_first':advance_target};tamper[0]=hook
    try:fork(a,0,{**intent,'id':'context-raced','target':'raced-target'},reject=True)
    finally:tamper[0]=None
    assert hook['seen']==2 and digest(a,0)==stable
    proof['checks']['target_advance_between_admissions_discards_candidate_before_cas']=True
    before_a,before_b=inspect(a),inspect(b)
    ka=fork(a,0,intent);kb=fork(b,1,intent)
    assert bytes(ka['public_key']).hex()==pins[0]['signing_key']
    assert bytes(kb['public_key']).hex()==pins[1]['signing_key']
    assert inspect(a)[0]==before_a[0] and inspect(b)[0]==before_b[0]
    stable=digest(a,0)
    assert fork(a,0,intent)==ka and digest(a,0)==stable
    proof['checks']['atomic_new_context_same_key_source_pending_unchanged_exact_retry']=True
    second_a,second_b=page(0),page(1)
    sa=init(second_a,0,selected_room='second');sb=init(second_b,1,selected_room='second')
    assert sa['public_key']==ka['public_key'] and sb['public_key']==kb['public_key']
    rpc(second_a,'create');rpc(second_a,'bind');rpc(second_b,'attach')
    for sender,receiver in ((second_b,second_a),(second_a,second_b),(second_b,second_a)):
        rpc(sender,'advance');rpc(sender,'flush');rpc(sender,'sync');rpc(receiver,'sync')
    assert rpc(second_a,'status')['phase']==rpc(second_b,'status')['phase']=='ready'
    assert rpc(second_a,'status')['group_id']!=group
    assert inspect(a)[0]==before_a[0] and inspect(b)[0]==before_b[0]
    stable=digest(a,0)
    hook={'context':'wrong-group','seen':0,'path':'/v1/mls/rooms/second/context'};tamper[0]=hook
    try:fork(a,0,intent,reject=True)
    finally:tamper[0]=None
    assert hook['seen']==1 and digest(a,0)==stable
    assert fork(a,0,intent)==ka and digest(a,0)==stable
    proof['checks']['committed_context_retry_accepts_progress_but_rejects_changed_group']=True
    prepare(second_a,'app-new-text','synthetic second room 한글'.encode())
    rpc(second_a,'flush');rpc(second_a,'sync');rpc(second_b,'sync')
    payload=bytes(range(256))*32
    prepare(second_b,'app-new-file',payload,'file');rpc(second_b,'flush');rpc(second_b,'sync');rpc(second_a,'sync')
    import base64
    assert base64.b64decode(rpc(second_a,'status')['messages'][-1]['payload'])==payload
    rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
    assert rpc(b,'status')['messages'][-1]['client_id']=='app-old-pending'
    proof['checks']['two_native_rooms_text_8192_file_and_original_outbox_reconciliation']=True
    fields=a.evaluate('''async n=>{const d=await new Promise(r=>{const q=indexedDB.open(n);q.onsuccess=()=>r(q.result)});const v=await new Promise(r=>{const q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result)});d.close();return {keys:Object.keys(v).sort(),scope:v.room,header:v.header.length,capsule:v.capsule.length,cipher:v.cipher.length}}''',databases[0])
    assert fields['keys']==sorted(['v','identity','room','vault','revision','capsule','header','cipher'])
    assert fields['scope']=='device-context-v1' and fields['header']==24 and fields['capsule']<8192
    proof['encrypted_state_sizes']=fields
    proof['checks']['idb_has_only_device_bound_capsule_and_complete_aggregate_ciphertext']=True

    # Native rekey stays local to the source; aggregate writes in target cannot
    # merge/erase its pending commit or reorder accepted old-epoch applications.
    rpc(a,'update',{'id':'update-source','fault':''});pending=inspect(a)[0]
    prepare(second_a,'app-during-old-update',b'separate context');rpc(second_a,'flush');rpc(second_a,'sync');rpc(second_b,'sync')
    assert inspect(a)[0]==pending
    assert fork(a,0,intent)==ka and inspect(a)[0]==pending
    prepare(b,'app-before-old-update',b'synthetic preceding old epoch');rpc(b,'flush');rpc(b,'sync')
    rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
    rpc(b,'advance');rpc(b,'flush');rpc(b,'sync');rpc(a,'sync')
    assert rpc(a,'status')['epoch']==rpc(b,'status')['epoch']==2
    assert rpc(second_a,'status')['epoch']==rpc(second_b,'status')['epoch']==1
    proof['checks']['native_source_pending_control_old_epoch_receive_survives_target_writes']=True

    # Strict IDB pending-write SIGKILL, then exact retry from the old aggregate.
    before=digest(a,0);source_before=inspect(a)[0]
    second_a.evaluate('()=>{window.pending=call("device","prepare",{id:"app-crash",bytes:[4,5],media_type:"file",fault:"crash-before-complete"})}')
    second_a.wait_for_function('()=>window.test_crash_boundary===true',timeout=10000)
    crash(0);a=page(0);init(a,0);second_a=page(0);init(second_a,0,selected_room='second')
    assert digest(a,0)==before and inspect(a)[0]==source_before
    prepare(second_a,'app-crash',b'\x04\x05','file');rpc(second_a,'flush');rpc(second_a,'sync');rpc(second_b,'sync')
    proof['checks']['browser_sigkill_during_target_idb_write_preserves_whole_source_and_target']=True

    # Native accepted response lost, browser killed: preserve exact outbox across
    # both room workers, reconcile native outcome, display only committed echo.
    prepare(second_a,'app-lost-reply',b'generated response loss');pending=inspect(second_a)[1];source_before=inspect(a)[0]
    arrived.clear();release.clear();hold_next[0]=True
    second_a.evaluate('()=>{window.pending=call("device","flush",null)}');assert arrived.wait(5)
    crash(0);release.set();a=page(0);init(a,0);second_a=page(0);init(second_a,0,selected_room='second')
    assert inspect(a)[0]==source_before and inspect(second_a)[1]==pending
    assert rpc(second_a,'status')['pending']['client_id']=='app-lost-reply'
    rpc(second_a,'flush');rpc(second_a,'sync');rpc(second_b,'sync')
    assert sum(m['client_id']=='app-lost-reply' for m in rpc(second_a,'status')['messages'])==1
    assert sum(m['client_id']=='app-lost-reply' for m in rpc(second_b,'status')['messages'])==1
    proof['checks']['accepted_lost_reply_browser_restart_exact_cipher_retry_and_single_echo']=True

    tab=page(0);init(tab,0,selected_room='second')
    q={'id':'app-race','bytes':[22,23],'media_type':'file','fault':''}
    second_a.evaluate('q=>{window.pending=call("device","prepare",q)}',q)
    assert rpc(tab,'prepare',q)['pending']['client_id']=='app-race'
    assert second_a.evaluate('window.pending')['ok']
    before=digest(a,0);prepare(tab,'app-race',b'conflicting','file',reject=True);assert digest(a,0)==before
    rpc(second_a,'flush');rpc(second_a,'sync');rpc(second_b,'sync')
    proof['checks']['two_tabs_exact_id_serialization_and_conflicting_content_denial']=True

    def save():
        a.evaluate('''async n=>{const d=await new Promise(r=>{const q=indexedDB.open(n);q.onsuccess=()=>r(q.result)});window.savedAggregate=await new Promise(r=>{const q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result)});d.close()}''',databases[0])
    def mutate(key):
        a.evaluate('''async([n,key])=>{const d=await new Promise(r=>{const q=indexedDB.open(n);q.onsuccess=()=>r(q.result)});await new Promise((r,j)=>{const t=d.transaction('device','readwrite'),s=t.objectStore('device'),q=s.get('state');q.onsuccess=()=>{const v=q.result;if(key==='revision')v.revision++;else v[key][v[key].length-1]^=1;s.put(v,'state')};t.oncomplete=r;t.onabort=j});d.close()}''',[databases[0],key])
    def restore():
        # Generated encrypted fixture rollback only, never a product import API.
        a.evaluate('''async n=>{const d=await new Promise(r=>{const q=indexedDB.open(n);q.onsuccess=()=>r(q.result)});await new Promise((r,j)=>{const t=d.transaction('device','readwrite');t.objectStore('device').put(window.savedAggregate,'state');t.oncomplete=r;t.onabort=j});d.close()}''',databases[0])
        open_room(a,0,'family');open_room(second_a,0,'second')

    save();rpc(second_a,'test-aggregate-hold')
    second_a.evaluate('()=>{window.test_aggregate_cas=false;window.pending=call("device","prepare",{id:"app-cas",bytes:[33],media_type:"file",fault:""})}')
    second_a.wait_for_function('()=>window.test_aggregate_cas===true',timeout=10000)
    mutate('revision');changed=digest(a,0)
    second_a.evaluate('window.testWorkers.at(-1).postMessage({test_aggregate_release:true})')
    assert not second_a.evaluate('window.pending')['ok'] and digest(a,0)==changed
    restore();proof['checks']['external_writer_conflict_is_retained_by_whole_cipher_cas']=True

    for key in ['capsule','header','cipher','revision']:
        save();mutate(key);bad=digest(a,0)
        rpc(a,'status',reject=True);assert digest(a,0)==bad
        restore()
    proof['checks']['corrupt_capsule_record_header_revision_denied_and_retained']=True
    save()
    a.evaluate('''async n=>{const d=await new Promise(r=>{const q=indexedDB.open(n);q.onsuccess=()=>r(q.result)});await new Promise((r,j)=>{const t=d.transaction('device','readwrite'),s=t.objectStore('device'),q=s.get('state');q.onsuccess=()=>{const v=q.result,b=new ArrayBuffer(25),view=new Uint8Array(b,0,24);view.set(v.header);v.header=view;s.put(v,'state')};t.oncomplete=r;t.onabort=j});d.close()}''',databases[0])
    bad=digest(a,0);rpc(a,'status',reject=True);assert digest(a,0)==bad;restore()
    proof['checks']['oversized_backing_buffer_rejected_even_with_valid_header_view']=True

    for mode in ['duplicate-room','wrong-actor','wrong-epoch','combined-quota']:
        save();rpc(second_a,'test-aggregate-forge',mode)
        prepare(second_a,'app-forge-'+mode,b'generated validation fixture')
        if mode=='combined-quota':assert rpc(second_a,'test-aggregate-quota-proof') is True
        bad=digest(a,0);rpc(a,'status',reject=True);assert digest(a,0)==bad
        restore()
    proof['checks']['authenticated_invalid_records_and_combined_quota_denied']=True

    stable=digest(a,0)
    fork(a,0,{**intent,'id':'context-conflict'},reject=True)
    fork(a,0,{**intent,'source_group':'aa'*32},reject=True)
    fork(a,0,intent,reject=True,password='synthetic-wrong-password-12345678901234567890')
    assert direct('owner','POST','/v1/mls/reservations',{'room':'third','peer_actor':'bob'})[0]==201
    fork(a,0,{**intent,'target':'third','id':'context-third'},reject=True)
    missing=page(0);init(missing,0,database=databases[0]+'-missing',reject=True)
    wrong_room=page(0);init(wrong_room,0,selected_room='third',reject=True)
    wrong_actor=page(0);init(wrong_actor,0,identity='bob',reject=True)
    assert digest(a,0)==stable
    proof['checks']['wrong_password_intent_room_actor_missing_registered_source_and_third_context_denied']=True

    # Reusing valid ciphertext under another database does not clone a device.
    save();clone=databases[0]+'-clone'
    a.evaluate('''async n=>new Promise((r,j)=>{const q=indexedDB.open(n,1);q.onupgradeneeded=()=>q.result.createObjectStore('device').add(window.savedAggregate,'state');q.onsuccess=()=>{q.result.close();r()};q.onerror=j})''',clone)
    cloned=page(0)
    rpc(cloned,'init',{'identity':'alice','room':'family','database':clone,'password':passwords[0],'create':False},reject=True)
    proof['checks']['valid_encrypted_aggregate_cannot_unlock_under_different_database_binding']=True

    before=digest(a,0);rpc(second_a,'test-aggregate-hold')
    second_a.evaluate('()=>{window.test_aggregate_cas=false;window.pending=call("device","prepare",{id:"app-lock-late",bytes:[34],media_type:"file",fault:""})}')
    second_a.wait_for_function('()=>window.test_aggregate_cas===true',timeout=10000)
    a.evaluate('window.lockVaults()');second_a.wait_for_function('()=>window.activeVaultWorkers()===0')
    assert not second_a.evaluate('window.pending')['ok'] and digest(a,0)==before
    open_room(a,0,'family');open_room(second_a,0,'second')
    proof['checks']['cross_tab_lock_retires_pending_candidate_without_late_commit']=True

    config['devices'][1]['status']='revoked';config['devices'][1]['device_revision']=2
    commit(2,config['people'])
    until=time.monotonic()+5
    while time.monotonic()<until:
        code,d=direct('owner','GET','/v1/rooms/family/devices')
        if code==200 and any(x['status']=='revoked' for x in d['devices']):break
        time.sleep(.05)
    else:raise AssertionError('revocation reload')
    before=digest(a,0);rpc(a,'status',reject=True);rpc(second_a,'status',reject=True)
    fork(a,0,intent,reject=True);assert digest(a,0)==before
    proof['checks']['revocation_denies_both_rooms_and_cached_context_retry']=True
    proof['native_aggregate_custody']=True
