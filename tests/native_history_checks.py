"""Read-only archive acceptance through actual native clients and isolated workers."""
import base64
import copy
import hashlib
import json
import secrets
import time
from playwright.sync_api import expect


def checks(a,b,contexts,pages,url,passwords,pins,proof,crash_page,open_page,direct,history_ui=False):
    database='family-mls-vault-synthetic-ui-alice-family'
    code,status=direct('owner','GET','/v1/mls/rooms/family/status');assert code==200
    expected={'database':database,'identity':'alice','room':'family','group_id':status['group_id'],'pins':pins}
    def digest(p):
        return p.evaluate('''async n=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(n,1);q.onsuccess=()=>r(q.result);q.onerror=j});const v=await new Promise((r,j)=>{const t=d.transaction('device','readonly');const q=t.objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();return {revision:v.revision,hash:Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',v.cipher))).join(',')}}''',database)
    marker='synthetic history excludes unaccepted pending'
    def block(route):
        if route.request.method=='POST':route.abort()
        else:route.continue_()
    a.route('**/log',block)
    expect(a.locator('#send')).to_be_enabled(timeout=20000)
    a.locator('#text').fill(marker);a.locator('#send').click();expect(a.locator('#chat')).to_be_hidden(timeout=25000)
    original=digest(a)
    def install(p):
        p.evaluate("async()=>{const {HistoryReader}=await import('/history-client.js');window.historyCaller=new HistoryReader(()=>{window.readHistory=null});}")
    if history_ui:
        from native_history_ui_checks import export_ui
        archive_ui=export_ui(a, url, expected, passwords[0], proof)
    install(a)
    export_started=time.monotonic()
    exported=a.evaluate('''async arg=>{const r=await historyCaller.read(arg,true);if(!r.ok)return {ok:false};window.encryptedHistoryArchive=r.result.archive;return {ok:true,archive:Array.from(r.result.archive),memory:r.memory_bytes}}''',{'expected':expected,'password':passwords[0]})
    assert exported['ok'] and exported['memory']<=128*1024*1024
    proof['history_export_total_ms']=round((time.monotonic()-export_started)*1000,2)
    proof['history_max_linear_bytes']=exported['memory']
    proof['history_read_total_ms']=[]
    archive=exported['archive'];assert digest(a)==original
    if history_ui:assert archive_ui==bytes(archive)
    wire=json.loads(bytes(archive));assert set(wire)=={'format','database','state'} and set(wire['state'])=={'v','identity','room','vault','revision','capsule','header','cipher'}
    proof['checks']['coherent_readonly_export_does_not_mutate_live_encrypted_state']=True
    proof['history_archive_bytes']=len(archive)
    # SIGKILL only the owned source browser. Recovery gets no source cookies/IDB.
    a=crash_page(0);assert digest(a)==original
    reader_context=contexts[1].browser.new_context();reader=reader_context.new_page();reader.goto(url);install(reader)
    requests=[];reader_context.on('request',lambda request:requests.append(request.url))
    assert reader.evaluate('async()=>await indexedDB.databases()')==[]
    def read(raw=archive,exp=expected,password=passwords[0],accept=True):
        started=time.monotonic()
        result=reader.evaluate('''async arg=>{arg.archive=new Uint8Array(arg.archive);const r=await historyCaller.read(arg);window.readHistory=r.ok?r.result:null;return {ok:r.ok,memory:r.memory_bytes,result:r.ok?r.result:null}}''',{'expected':exp,'password':password,'archive':raw})
        proof['history_read_total_ms'].append(round((time.monotonic()-started)*1000,2))
        assert result['ok'] is accept,result
        if accept:
            assert result['memory']<=128*1024*1024
            proof['history_max_linear_bytes']=max(proof['history_max_linear_bytes'],result['memory'])
            assert set(result['result'])=={'identity','room','group_id','pins','cursor','epoch','messages'}
        return result['result']
    try:
        missing={**expected,'database':database+'-missing'}
        denied=reader.evaluate('async arg=>await historyCaller.read(arg,true)',{'expected':missing,'password':passwords[0]})
        assert not denied['ok'] and reader.evaluate('async()=>await indexedDB.databases()')==[]
        proof['checks']['missing_export_database_denies_without_creation']=True
        recovered=read()
        assert any(m['media_type']=='text' and 'synthetic UI 한글' in base64.b64decode(m['payload']).decode() for m in recovered['messages'])
        assert any(m['media_type']=='file' and base64.b64decode(m['payload'])==bytes(range(256))*4 for m in recovered['messages'])
        assert all(marker.encode() not in base64.b64decode(m['payload']) for m in recovered['messages'])
        proof['checks']['source_browser_sigkill_separate_reader_recovers_only_committed_text_and_file']=True
        proof['checks']['archive_pending_frame_never_becomes_recovered_delivery']=True
        assert not any('/v1/' in u for u in requests) and reader.evaluate('async()=>await indexedDB.databases()')==[]
        assert digest(a)==original
        proof['checks']['reader_has_no_native_requests_no_idb_import_and_no_live_writes']=True
        forged=reader.evaluate('''arg=>new Promise(resolve=>{const w=new Worker('/history-forge-worker.js',{type:'module'});w.onmessage=({data})=>{if(data.ready)w.postMessage(arg);else{w.terminate();resolve(data)}}})''',{'archive':archive,'password':passwords[0]})
        assert forged['ok']
        for raw in forged['fixtures'].values():read(raw=raw,accept=False)
        proof['checks']['valid_mac_wrong_sender_pending_history_provider_and_nonfinal_record_denied']=True
        read(password=secrets.token_urlsafe(32),accept=False)
        for field,value in [('identity','bob'),('room','other'),('database',database+'-other'),('group_id','aa'*32)]:
            e=copy.deepcopy(expected);e[field]=value;read(exp=e,accept=False)
        e=copy.deepcopy(expected);e['pins'][1]['signing_key']='11'*32;e['pins'][1]['fingerprint']=hashlib.sha256(bytes.fromhex('11'*32)).hexdigest();read(exp=e,accept=False)
        proof['checks']['wrong_password_actor_room_database_group_and_independent_pin_deny']=True
        def changed(field):
            value=json.loads(bytes(archive));s=value['state']
            if field in ('capsule','header','cipher'):
                v=bytearray(base64.b64decode(s[field]));v[-1]^=1;s[field]=base64.b64encode(v).decode()
            elif field=='vault':s[field]='aa'*16
            else:s[field]+=1
            return list(json.dumps(value,separators=(',',':')).encode())
        for field in ('capsule','header','cipher','vault','revision'):read(raw=changed(field),accept=False)
        read(raw=archive[:-1],accept=False)
        proof['checks']['capsule_header_cipher_metadata_revision_tamper_and_truncation_deny']=True
        bad=reader.evaluate('''async arg=>{arg.archive=new Uint8Array(6*1024*1024+1);return (await historyCaller.read(arg)).ok}''',{'expected':expected,'password':passwords[0]});assert not bad
        backing=reader.evaluate('''async arg=>{arg.archive=new Uint8Array(new ArrayBuffer(6*1024*1024+1),0,1);return (await historyCaller.read(arg)).ok}''',{'expected':expected,'password':passwords[0]});assert not backing
        duplicate=list(bytes(archive).replace(b'"format":',b'"format":"wrong","format":',1));read(raw=duplicate,accept=False)
        proof['checks']['oversized_and_duplicate_field_archives_denied']=True
        # Hold the cooperative global KDF lock to make late cancellation deterministic.
        reader.evaluate("()=>{window.holdingKDF=false;window.holdKDF=navigator.locks.request('family-native-vault-kdf',()=>new Promise(r=>{window.releaseHistoryKDF=r;window.holdingKDF=true}));}")
        reader.wait_for_function('()=>holdingKDF')
        reader.evaluate('''arg=>{arg.archive=new Uint8Array(arg.archive);window.lateHistory=historyCaller.read(arg)}''',{'expected':expected,'password':passwords[0],'archive':archive})
        reader.wait_for_function("async()=>{const q=await navigator.locks.query();return q.pending.some(x=>x.name==='family-native-vault-kdf')}")
        reader.evaluate('()=>{historyCaller.lock();releaseHistoryKDF()}');assert not reader.evaluate('()=>lateHistory')['ok']
        assert reader.evaluate('readHistory') is None
        proof['checks']['lock_while_waiting_kdf_discards_late_result']=True
        denied=reader.evaluate('''async arg=>{arg.archive=new Uint8Array(arg.archive);arg.uncloneable=()=>{};return await historyCaller.read(arg)}''',{'expected':expected,'password':passwords[0],'archive':archive});assert not denied['ok']
        reader.reload();install(reader);again=read();assert again==recovered
        proof['checks']['clone_failure_retires_and_reader_reload_never_reuses_secret']=True
        # No reader dispatcher for send/import/re-enrollment, even with valid archive.
        denied=reader.evaluate('''()=>new Promise(resolve=>{const w=new Worker('/history-worker.js',{type:'module'});w.onmessage=({data})=>{if(data.ready)w.postMessage({id:1,method:'send',argument:null});else{w.terminate();resolve(data)}}})''');assert not denied['ok']
        assert not any('/v1/' in u for u in requests) and reader.evaluate('async()=>await indexedDB.databases()')==[] and digest(a)==original
        assert reader.evaluate('sessionStorage.length+localStorage.length')==0
        proof['checks']['reader_send_import_commands_denied_and_no_persisted_recovery_secrets']=True
    finally:reader_context.close()
    if history_ui:
        from native_history_ui_checks import reader_ui
        reader_ui(a, b, contexts, url, expected, passwords[0], bytes(archive), marker, proof)
        assert digest(a)==original
    # Continuing the live fixture is explicit original-device retry, never archive import.
    open_page(a);expect(a.locator('#retry')).to_be_visible(timeout=25000);a.locator('#retry').click()
    for p in (a,b):expect(p.locator('#messages')).to_contain_text(marker,timeout=25000)
    proof['checks']['original_live_device_requires_explicit_retry_after_readonly_recovery']=True
    proof['native_readonly_history']=True
    return a
