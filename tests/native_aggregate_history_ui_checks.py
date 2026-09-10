"""Generated DOM recovery proof; no human archive/password or production service."""
import copy
import hashlib
import json
import secrets
from pathlib import Path
from playwright.sync_api import expect


def fill(page, expected, password, archive=None):
    page.locator('#expected').fill(json.dumps(expected))
    page.locator('#accepted').check()
    page.locator('#password').fill(password)
    if archive is not None:
        page.locator('#archive').set_input_files({'name':'synthetic.family-history','mimeType':'application/octet-stream','buffer':archive})


def export_ui(a,url,expected,password,proof):
    a.goto(url+'/aggregate-history/')
    fill(a,expected,password)
    a.locator('#export').click()
    expect(a.locator('#save-archive')).to_be_visible(timeout=30000)
    assert a.locator('#password').input_value()=='' and a.locator('#archive').input_value()==''
    with a.expect_download() as event:a.locator('#save-archive').click()
    download=event.value;assert download.suggested_filename=='synthetic-aggregate.family-history'
    archive=Path(download.path()).read_bytes()
    assert len(archive)<6*1024*1024 and password.encode() not in archive
    assert a.locator('#messages li').count()==0
    proof['checks']['aggregate_history_dom_coherent_export_download_clears_transient_inputs']=True
    return archive


def reader_ui(a,b,url,expected,password,archive,pending_marker,proof,direct,config,commit):
    browser=b.context.browser
    context=browser.new_context(accept_downloads=True)
    context.add_cookies(a.context.cookies())
    context.add_init_script("window.liveBlobURLs=new Set();const make=URL.createObjectURL,drop=URL.revokeObjectURL;URL.createObjectURL=function(...args){const u=make.apply(this,args);liveBlobURLs.add(u);return u};URL.revokeObjectURL=function(u){liveBlobURLs.delete(u);return drop.call(this,u)}")
    requests=[];context.on('request',lambda request:requests.append((request.method,request.url)))
    p=context.new_page();p.goto(url+'/aggregate-history/')
    errors=[];p.on('pageerror',lambda e:errors.append(str(e)))
    def open_read(exp=expected,pw=password,raw=archive,ok=True):
        p.locator('#lock').click();fill(p,exp,pw,raw);p.locator('#read').click()
        if ok:expect(p.locator('#messages')).to_contain_text('synthetic second room 한글',timeout=30000)
        else:expect(p.locator('#status')).to_contain_text('확인',timeout=30000);expect(p.locator('#read')).to_be_enabled(timeout=30000);expect(p.locator('#result')).to_be_hidden()
        assert p.locator('#password').input_value()=='' and p.locator('#archive').input_value()==''
    try:
        assert p.locator('#expected').input_value()==''
        open_read()
        assert pending_marker not in p.locator('#messages').inner_text()
        assert 'not delivered from target' not in p.locator('#messages').inner_text()
        assert p.locator('#messages section').count()==2
        assert p.locator('#messages section').nth(0).get_attribute('data-room')=='family'
        assert p.locator('#messages section').nth(1).get_attribute('data-room')=='second'
        assert 'synthetic preceding old epoch' in p.locator('#messages').inner_text()
        assert p.locator('#messages img,iframe,video').count()==0 and p.locator('#send').count()==0
        p.evaluate("()=>{window.historyURLTimers=[];window.originalHistoryTimer=window.setTimeout;window.setTimeout=function(fn,ms,...args){if(ms===1000){historyURLTimers.push(()=>fn(...args));return 0}return originalHistoryTimer(fn,ms,...args)};window.historyFetches=0;const fetcher=window.fetch;window.fetch=function(...args){historyFetches++;return fetcher.apply(this,args)}}")
        with p.expect_download() as event:p.locator('#messages section[data-room=second] button').first.click()
        download=event.value;assert download.suggested_filename.startswith('history-second-app-') and download.suggested_filename.endswith('.bin')
        assert Path(download.path()).read_bytes()==bytes(range(256))*32
        with p.expect_download() as event:p.locator('#messages section[data-room=second] button').first.click()
        assert Path(event.value.path()).read_bytes()==bytes(range(256))*32
        assert p.evaluate('liveBlobURLs.size')==2
        before=p.evaluate('historyFetches')
        p.locator('#messages section[data-room=second] button').first.click()
        assert p.evaluate('historyFetches')==before and p.evaluate('liveBlobURLs.size')==2
        p.evaluate('()=>{window.setTimeout=originalHistoryTimer;for(const fn of historyURLTimers)fn();historyURLTimers=[]}')
        assert p.evaluate('liveBlobURLs.size')==0
        proof['checks']['aggregate_history_dom_download_urls_bounded_before_fresh_admission']=True
        proof['checks']['aggregate_history_dom_source_crash_readonly_text_file_integrity_pending_exclusion']=True
        p.locator('#lock').click()
        assert p.locator('#messages li').count()==0 and p.evaluate('liveBlobURLs.size')==0
        assert p.evaluate('async()=>await indexedDB.databases()')==[]
        # No source state exists here: export cannot create a database or sender.
        fill(p,expected,password);p.locator('#export').click()
        expect(p.locator('#read')).to_be_enabled(timeout=30000);expect(p.locator('#result')).to_be_hidden()
        assert p.evaluate('async()=>await indexedDB.databases()')==[]
        proof['checks']['aggregate_history_dom_lock_blob_cleanup_missing_export_no_profile_creation']=True
        open_read(pw=secrets.token_urlsafe(32),ok=False)
        changed=copy.deepcopy(expected);changed['rooms'][1]['pins'][1]['signing_key']='11'*32
        changed['rooms'][1]['pins'][1]['fingerprint']=hashlib.sha256(bytes.fromhex('11'*32)).hexdigest()
        open_read(exp=changed,ok=False)
        changed=copy.deepcopy(expected);changed['rooms'][1]['group_id']='11'*16
        open_read(exp=changed,ok=False)
        tampered=json.loads(archive);tampered['state']['revision']+=1
        open_read(raw=json.dumps(tampered,separators=(',',':')).encode(),ok=False)
        changed=copy.deepcopy(expected);changed['fork']['id']='context-wrong'
        open_read(exp=changed,ok=False)
        open_read(raw=archive[:-1],ok=False)
        assert p.locator('#messages section').count()==0
        proof['checks']['aggregate_history_dom_password_pins_target_group_fork_tamper_truncation_deny_both_rooms']=True
        # Check the file admission boundary before File.arrayBuffer is invoked.
        p.evaluate("()=>{window.historyFileReads=0;const read=File.prototype.arrayBuffer;File.prototype.arrayBuffer=function(){historyFileReads++;return read.call(this)}}")
        open_read(raw=b'x'*(6*1024*1024+1),ok=False)
        assert p.evaluate('historyFileReads')==0
        fill(p,expected,password,archive)
        oversized=copy.deepcopy(expected);oversized['database']='한'*1500
        p.locator('#expected').fill(json.dumps(oversized,ensure_ascii=False))
        assert len(p.locator('#expected').input_value())<4096
        p.locator('#read').click();expect(p.locator('#read')).to_be_enabled()
        expect(p.locator('#status')).to_contain_text('입력과 파일 크기')
        assert p.evaluate('historyFileReads')==0
        proof['checks']['aggregate_history_dom_oversized_file_and_utf8_binding_denied_before_arraybuffer']=True
        # Current signed actor cannot silently switch to a different archive owner.
        context.clear_cookies();context.add_cookies(b.context.cookies())
        open_read(ok=False)
        context.clear_cookies();context.add_cookies(a.context.cookies())
        open_read()
        p.route('**/v1/session',lambda route:route.fulfill(status=401,body='denied'))
        p.locator('#messages section[data-room=second] button').first.click()
        expect(p.locator('#result')).to_be_hidden(timeout=10000)
        assert p.evaluate('liveBlobURLs.size')==0
        p.unroute('**/v1/session')
        proof['checks']['aggregate_history_dom_actual_signed_actor_switch_and_denied_download_clear_view']=True
        # Hold KDF admission, then lock. A retired worker cannot publish late output.
        p.evaluate("()=>{window.kdfHeld=false;navigator.locks.request('family-native-vault-kdf',()=>new Promise(resolve=>{window.releaseKDF=resolve;window.kdfHeld=true}))}")
        p.wait_for_function('()=>kdfHeld')
        fill(p,expected,password,archive);p.locator('#read').click()
        p.wait_for_function("async()=>{const q=await navigator.locks.query();return q.pending.some(x=>x.name==='family-native-vault-kdf')}")
        p.locator('#lock').click();p.evaluate('()=>releaseKDF()')
        expect(p.locator('#result')).to_be_hidden();assert p.locator('#password').input_value()==''
        open_read()
        # Shared lock channel also clears the recovered DOM; no auto unlock.
        sibling=context.new_page();sibling.goto(url+'/aggregate-history/');sibling.locator('#lock').click()
        expect(p.locator('#result')).to_be_hidden();assert p.evaluate('liveBlobURLs.size')==0;sibling.close()
        proof['checks']['aggregate_history_dom_kdf_late_completion_and_sibling_lock_retirement']=True
        open_read()
        p.evaluate("()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});document.dispatchEvent(new Event('visibilitychange'))}")
        expect(p.locator('#result')).to_be_hidden();assert p.evaluate('liveBlobURLs.size')==0
        p.evaluate("()=>{delete document.hidden}")
        proof['checks']['aggregate_history_dom_hidden_view_clears_and_never_auto_reopens']=True
        # A late File read from a retired generation cannot clear a newer view.
        p.evaluate("()=>{const original=File.prototype.arrayBuffer;window.holdOneFile=true;File.prototype.arrayBuffer=function(){if(window.holdOneFile){window.holdOneFile=false;window.fileHeld=true;return new Promise(resolve=>{window.finishOldFile=()=>original.call(this).then(resolve)})}return original.call(this)}}")
        fill(p,expected,password,archive);p.locator('#read').click()
        p.wait_for_function('()=>window.fileHeld===true')
        p.locator('#lock').click();open_read()
        p.evaluate('()=>finishOldFile()')
        expect(p.locator('#messages')).to_contain_text('synthetic second room 한글')
        assert p.locator('#messages section').count()==2
        proof['checks']['aggregate_history_dom_late_file_completion_cannot_clear_newly_opened_view']=True
        # Reload carries no secret, automatically accepted pins, or open history.
        p.reload();assert p.locator('#password').input_value()==p.locator('#expected').input_value()==''
        expect(p.locator('#result')).to_be_hidden();open_read()
        assert p.evaluate('sessionStorage.length+localStorage.length')==0
        assert p.evaluate('async()=>await indexedDB.databases()')==[]
        assert all(method=='GET' and u.split('/v1/',1)[1]=='session' for method,u in requests if '/v1/' in u)
        assert not errors,errors
        proof['checks']['aggregate_history_dom_reload_no_secrets_no_native_delivery_or_idb_import']=True
        p.set_viewport_size({'width':390,'height':844})
        assert p.evaluate('document.documentElement.scrollWidth<=innerWidth')
        proof['checks']['aggregate_history_dom_390px_layout']=True
        config['devices'][1]['status']='revoked';config['devices'][1]['device_revision']=2
        commit(2,config['people'])
        # Offline historical keys remain valid; UI does not infer device enrollment.
        import time
        end=time.monotonic()+5
        while time.monotonic()<end:
            code,value=direct('owner','GET','/v1/rooms/family/devices')
            if code==200 and any(x['status']=='revoked' for x in value['devices']):break
            time.sleep(.05)
        else:raise AssertionError('device revocation reload')
        open_read()
        proof['checks']['aggregate_history_dom_device_revocation_does_not_erase_possessed_past_archive']=True
        config['devices'][0]['status']='revoked';config['devices'][0]['device_revision']=2
        commit(3,[])
        end=time.monotonic()+5
        while time.monotonic()<end:
            code,_=direct('owner','GET','/v1/session')
            if code==403:break
            time.sleep(.05)
        else:raise AssertionError('account revocation reload')
        p.locator('#messages section[data-room=second] button').first.click()
        expect(p.locator('#result')).to_be_hidden(timeout=10000)
        assert p.evaluate('liveBlobURLs.size')==0
        assert p.evaluate('indexedDB.databases()')==[]
        proof['checks']['aggregate_history_dom_actual_account_revocation_denies_download_and_clears_view']=True
    finally:context.close()



def history_checks(a,b,sa,sb,databases,rpc,init,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,intent):
    groups=[rpc(p,'status')['group_id'] for p in (a,sa)]
    expected={'database':databases[0],'identity':'alice','primary_room':'family',
        'rooms':[{'room':room,'group_id':group,'pins':pins} for room,group in zip(('family','second'),groups)],'fork':intent}
    prepare(a,'app-history-pending',b'not delivered from source')
    prepare(sa,'app-history-pending-target',b'not delivered from target')
    before=digest(a,0);other_before=digest(b,1)
    from urllib.parse import urlsplit
    part=urlsplit(a.url);url=part.scheme+'://'+part.netloc
    archive=export_ui(a,url,expected,passwords[0],proof)
    assert digest(a,0)==before
    other=copy.deepcopy(expected);other['database']=databases[1];other['identity']='bob'
    other_archive=export_ui(b,url,other,passwords[1],proof)
    assert other_archive and digest(b,1)==other_before
    proof['checks']['aggregate_history_dom_both_signed_clients_export_without_live_state_changes']=True
    crash(0);a=page(0);assert digest(a,0)==before
    reader_ui(a,b,url,expected,passwords[0],archive,'not delivered from source',proof,direct,config,commit)
    assert digest(a,0)==before and digest(b,1)==other_before
    proof['checks']['aggregate_history_dom_source_sigkill_and_all_reader_paths_preserve_exact_sealed_pending_state']=True
    proof['native_aggregate_history_ui']=True
