"""Original Go-served chat and recovery bytes; disposable signed browser profiles."""
import copy
import hashlib
import json
import secrets
import time
from pathlib import Path
from playwright.sync_api import expect
from native_aggregate_history_ui_checks import fill, export_ui


def native_checks(a,b,contexts,url,passwords,pins,proof,crash_page,open_page,direct,restart,config,commit):
    groups=[]
    for room in ('family','second'):
        code,status=direct('owner','GET',f'/v1/mls/rooms/{room}/status');assert code==200
        groups.append(status['group_id'])
    expected=[]
    for i,actor in enumerate(('alice','bob')):
        expected.append({'database':'family-mls-device-vault-synthetic-ui-'+actor,'identity':actor,'primary_room':'family',
            'rooms':[{'room':room,'group_id':group,'pins':pins} for room,group in zip(('family','second'),groups)],
            'fork':{'id':'context-ui-'+str(i),'source':'family','target':'second','source_group':groups[0],'pins':pins}})
    def digest(p,i):
        # Read existing encrypted state only; never create or decrypt a profile.
        return p.evaluate('''async name=>{
          if(!(await indexedDB.databases()).some(d=>d.name===name))throw Error('missing');
          const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j;q.onupgradeneeded=()=>{q.transaction.abort();j(Error('upgrade'))}});
          const v=await new Promise((r,j)=>{const t=d.transaction('device','readonly'),q=t.objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();
          const data=JSON.stringify(v,(k,x)=>x instanceof Uint8Array?Array.from(x):x);
          return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(data)))).join(',');
        }''',expected[i]['database'])
    marker='synthetic compiled aggregate pending'
    # Real native prepared outboxes, with transport aborted before acceptance.
    for room in ('family','second'):
        a.locator('#room').fill(room);open_page(a)
        a.route('**/log',lambda r:r.abort() if r.request.method=='POST' else r.continue_())
        expect(a.locator('#send')).to_be_enabled(timeout=25000)
        a.locator('#text').fill(marker+' '+room);a.locator('#send').click()
        expect(a.locator('#chat')).to_be_hidden(timeout=25000)
        a.unroute('**/log')
    b.locator('#lock').click()
    before=[digest(p,i) for i,p in enumerate((a,b))]
    archives=[export_ui(p,url,expected[i],passwords[i],proof) for i,p in enumerate((a,b))]
    assert [digest(p,i) for i,p in enumerate((a,b))]==before
    a=crash_page(0)
    assert digest(a,0)==before[0]
    restart()
    assert digest(a,0)==before[0] and digest(b,1)==before[1]
    proof['checks']['compiled_aggregate_export_both_rooms_source_sigkill_server_restart_exact_sealed_pending_preserved']=True
    context=contexts[1].browser.new_context(accept_downloads=True)
    context.add_cookies(a.context.cookies())
    context.add_init_script("window.liveBlobURLs=new Set();const make=URL.createObjectURL,drop=URL.revokeObjectURL;URL.createObjectURL=function(...args){const u=make.apply(this,args);liveBlobURLs.add(u);return u};URL.revokeObjectURL=function(u){liveBlobURLs.delete(u);return drop.call(this,u)}")
    requests=[];errors=[]
    context.on('request',lambda r:requests.append((r.method,r.url)))
    p=context.new_page();p.on('pageerror',lambda e:errors.append(str(e)));p.goto(url+'/aggregate-history/')
    def read(e=expected[0],pw=passwords[0],raw=archives[0],ok=True):
        p.locator('#lock').click();fill(p,e,pw,raw);p.locator('#read').click()
        if ok:
            expect(p.locator('#messages')).to_contain_text('synthetic second-room only',timeout=30000)
            assert p.locator('#messages section').count()==2
        else:
            expect(p.locator('#status')).to_contain_text('확인',timeout=30000)
            expect(p.locator('#read')).to_be_enabled(timeout=30000);expect(p.locator('#result')).to_be_hidden()
        assert p.locator('#password').input_value()==p.locator('#archive').input_value()==''
    try:
        assert p.locator('#expected').input_value()==''
        read()
        assert marker not in p.locator('#messages').inner_text()
        assert 'synthetic UI 한글' in p.locator('#messages section[data-room=family]').inner_text()
        assert p.locator('#messages section[data-room=second] button').count()==1 and p.locator('#send').count()==0
        with p.expect_download() as event:p.locator('#messages section[data-room=second] button').click()
        assert Path(event.value.path()).read_bytes()==bytes(range(256))*32
        proof['checks']['compiled_aggregate_history_two_committed_rooms_8kib_download_no_pending_or_composer']=True
        p.locator('#lock').click();assert p.evaluate('liveBlobURLs.size')==0
        fill(p,expected[0],passwords[0]);p.locator('#export').click()
        expect(p.locator('#read')).to_be_enabled(timeout=30000);expect(p.locator('#result')).to_be_hidden()
        assert p.evaluate('indexedDB.databases()')==[]
        read(pw=secrets.token_urlsafe(32),ok=False)
        for field in ('pins','group','fork','room'):
            e=copy.deepcopy(expected[0])
            if field=='pins':
                e['rooms'][1]['pins'][1]['signing_key']='11'*32
                e['rooms'][1]['pins'][1]['fingerprint']=hashlib.sha256(bytes.fromhex('11'*32)).hexdigest()
            elif field=='group':e['rooms'][1]['group_id']='11'*16
            elif field=='fork':e['fork']['id']='context-substituted'
            else:e['rooms'][1]['room']='wrong'
            read(e=e,ok=False)
        for raw in (archives[1],archives[0][:-1]):read(raw=raw,ok=False)
        changed=json.loads(archives[0]);changed['state']['revision']+=1
        read(raw=json.dumps(changed,separators=(',',':')).encode(),ok=False)
        proof['checks']['compiled_aggregate_history_wrong_password_pins_group_fork_room_swapped_archive_tamper_truncation_deny']=True
        p.evaluate("()=>{window.fileReads=0;const read=File.prototype.arrayBuffer;File.prototype.arrayBuffer=function(){fileReads++;return read.call(this)}}")
        read(raw=b'x'*(6*1024*1024+1),ok=False);assert p.evaluate('fileReads')==0
        e=copy.deepcopy(expected[0]);e['database']='한'*1500
        fill(p,e,passwords[0],archives[0]);p.locator('#read').click()
        expect(p.locator('#status')).to_contain_text('입력과 파일 크기');assert p.evaluate('fileReads')==0
        proof['checks']['compiled_aggregate_history_file_and_utf8_caps_before_read_no_missing_profile_creation']=True
        context.clear_cookies();context.add_cookies(b.context.cookies());read(ok=False)
        context.clear_cookies();context.add_cookies(a.context.cookies());read()
        p.evaluate("()=>{navigator.locks.request('family-native-vault-kdf',()=>new Promise(resolve=>{window.releaseKDF=resolve;window.kdfHeld=true}))}")
        p.wait_for_function('()=>window.kdfHeld===true');p.locator('#lock').click()
        fill(p,expected[0],passwords[0],archives[0]);p.locator('#read').click()
        p.wait_for_function("async()=>{const q=await navigator.locks.query();return q.pending.some(x=>x.name==='family-native-vault-kdf')}")
        p.locator('#lock').click();p.evaluate('()=>releaseKDF()');read()
        sibling=context.new_page();sibling.goto(url+'/aggregate-history/');sibling.locator('#lock').click()
        expect(p.locator('#result')).to_be_hidden();sibling.close();read()
        p.evaluate("()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});document.dispatchEvent(new Event('visibilitychange'))}")
        expect(p.locator('#result')).to_be_hidden();assert p.evaluate('liveBlobURLs.size')==0
        p.evaluate('()=>delete document.hidden');read()
        # Hold one File completion across a fresh successful reader operation.
        p.evaluate("()=>{const original=File.prototype.arrayBuffer;let once=true;File.prototype.arrayBuffer=function(){if(once){once=false;window.fileHeld=true;return new Promise(resolve=>{window.finishOldFile=()=>original.call(this).then(resolve)})}return original.call(this)}}")
        fill(p,expected[0],passwords[0],archives[0]);p.locator('#read').click();p.wait_for_function('()=>window.fileHeld===true')
        p.locator('#lock').click();read();p.evaluate('()=>finishOldFile()')
        expect(p.locator('#messages')).to_contain_text('synthetic second-room only')
        proof['checks']['compiled_aggregate_history_actor_switch_kdf_lock_sibling_hide_and_late_file_are_terminal']=True
        p.reload();assert p.locator('#expected').input_value()==p.locator('#password').input_value()==''
        expect(p.locator('#result')).to_be_hidden();read()
        assert p.evaluate('indexedDB.databases()')==[] and p.evaluate('sessionStorage.length+localStorage.length')==0
        assert all(method=='GET' and u.split('/v1/',1)[1]=='session' for method,u in requests if '/v1/' in u)
        assert not errors,errors
        assert digest(a,0)==before[0] and digest(b,1)==before[1]
        proof['checks']['compiled_aggregate_reader_reopen_zero_native_send_import_livewrite_and_exact_source_preservation']=True
        p.locator('#lock').click()
        for page in (a,b):
            page.goto(url+'/aggregate/');open_page(page)
        # The source is still the original sender and explicitly retains pending.
        assert a.locator('#pending').get_attribute('data-client-id').startswith('app-')
        proof['checks']['compiled_aggregate_history_original_sender_outbox_retained_no_auto_retry']=True
    except BaseException:
        context.close();raise
    def after_revocation():
        try:
            read() # Possessed history remains valid after peer device retirement.
            proof['checks']['compiled_aggregate_history_peer_revocation_does_not_erase_past_archive']=True
            config['devices'][0]['status']='revoked';config['devices'][0]['device_revision']=2;commit(3,[])
            end=time.monotonic()+5
            while time.monotonic()<end:
                if direct('owner','GET','/v1/session')[0]==401:break
                time.sleep(.05)
            else:raise AssertionError('account revocation reload')
            p.locator('#messages section[data-room=second] button').click()
            expect(p.locator('#result')).to_be_hidden(timeout=10000);assert p.evaluate('liveBlobURLs.size')==0
            proof['checks']['compiled_aggregate_history_signed_account_revocation_denies_download_clears_view']=True
            proof['native_aggregate_history_embedded']=True
        finally:context.close()
    return a,after_revocation
