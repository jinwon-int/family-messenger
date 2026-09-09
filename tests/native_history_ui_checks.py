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
    a.goto(url+'/history/')
    fill(a,expected,password)
    a.locator('#export').click()
    expect(a.locator('#save-archive')).to_be_visible(timeout=30000)
    assert a.locator('#password').input_value()=='' and a.locator('#archive').input_value()==''
    with a.expect_download() as event:a.locator('#save-archive').click()
    download=event.value;assert download.suggested_filename=='synthetic-history.family-history'
    archive=Path(download.path()).read_bytes()
    assert len(archive)<6*1024*1024 and password.encode() not in archive
    assert a.locator('#messages li').count()==0
    proof['checks']['history_dom_coherent_export_download_clears_transient_inputs']=True
    return archive


def reader_ui(a,b,contexts,url,expected,password,archive,pending_marker,proof):
    browser=contexts[1].browser
    context=browser.new_context(accept_downloads=True)
    context.add_cookies(a.context.cookies())
    context.add_init_script("window.liveBlobURLs=new Set();const make=URL.createObjectURL,drop=URL.revokeObjectURL;URL.createObjectURL=function(...args){const u=make.apply(this,args);liveBlobURLs.add(u);return u};URL.revokeObjectURL=function(u){liveBlobURLs.delete(u);return drop.call(this,u)}")
    requests=[];context.on('request',lambda request:requests.append((request.method,request.url)))
    p=context.new_page();p.goto(url+'/history/')
    errors=[];p.on('pageerror',lambda e:errors.append(str(e)))
    def open_read(exp=expected,pw=password,raw=archive,ok=True):
        p.locator('#lock').click();fill(p,exp,pw,raw);p.locator('#read').click()
        if ok:expect(p.locator('#messages')).to_contain_text('synthetic UI 한글',timeout=30000)
        else:expect(p.locator('#status')).to_contain_text('확인',timeout=30000);expect(p.locator('#read')).to_be_enabled(timeout=30000);expect(p.locator('#result')).to_be_hidden()
        assert p.locator('#password').input_value()=='' and p.locator('#archive').input_value()==''
    try:
        assert p.locator('#expected').input_value()==''
        open_read()
        assert pending_marker not in p.locator('#messages').inner_text()
        assert p.locator('#messages img,iframe,video').count()==0 and p.locator('#send').count()==0
        p.evaluate("()=>{window.historyURLTimers=[];window.originalHistoryTimer=window.setTimeout;window.setTimeout=function(fn,ms,...args){if(ms===1000){historyURLTimers.push(()=>fn(...args));return 0}return originalHistoryTimer(fn,ms,...args)};window.historyFetches=0;const fetcher=window.fetch;window.fetch=function(...args){historyFetches++;return fetcher.apply(this,args)}}")
        with p.expect_download() as event:p.locator('#messages button').first.click()
        download=event.value;assert download.suggested_filename.startswith('history-app-') and download.suggested_filename.endswith('.bin')
        assert Path(download.path()).read_bytes()==bytes(range(256))*4
        with p.expect_download() as event:p.locator('#messages button').first.click()
        assert Path(event.value.path()).read_bytes()==bytes(range(256))*4
        assert p.evaluate('liveBlobURLs.size')==2
        before=p.evaluate('historyFetches')
        p.locator('#messages button').first.click()
        assert p.evaluate('historyFetches')==before and p.evaluate('liveBlobURLs.size')==2
        p.evaluate('()=>{window.setTimeout=originalHistoryTimer;for(const fn of historyURLTimers)fn();historyURLTimers=[]}')
        assert p.evaluate('liveBlobURLs.size')==0
        proof['checks']['history_dom_download_urls_bounded_before_fresh_admission']=True
        proof['checks']['history_dom_source_crash_readonly_text_file_integrity_pending_exclusion']=True
        p.locator('#lock').click()
        assert p.locator('#messages li').count()==0 and p.evaluate('liveBlobURLs.size')==0
        assert p.evaluate('async()=>await indexedDB.databases()')==[]
        # No source state exists here: export cannot create a database or sender.
        fill(p,expected,password);p.locator('#export').click()
        expect(p.locator('#read')).to_be_enabled(timeout=30000);expect(p.locator('#result')).to_be_hidden()
        assert p.evaluate('async()=>await indexedDB.databases()')==[]
        proof['checks']['history_dom_lock_blob_cleanup_missing_export_no_profile_creation']=True
        open_read(pw=secrets.token_urlsafe(32),ok=False)
        changed=copy.deepcopy(expected);changed['pins'][1]['signing_key']='11'*32
        changed['pins'][1]['fingerprint']=hashlib.sha256(bytes.fromhex('11'*32)).hexdigest()
        open_read(exp=changed,ok=False)
        changed=copy.deepcopy(expected);changed['room']='wrong'
        open_read(exp=changed,ok=False)
        tampered=json.loads(archive);tampered['state']['revision']+=1
        open_read(raw=json.dumps(tampered,separators=(',',':')).encode(),ok=False)
        proof['checks']['history_dom_password_independent_pins_room_and_tamper_denial']=True
        # Check the file admission boundary before File.arrayBuffer is invoked.
        p.evaluate("()=>{window.historyFileReads=0;const read=File.prototype.arrayBuffer;File.prototype.arrayBuffer=function(){historyFileReads++;return read.call(this)}}")
        open_read(raw=b'x'*(6*1024*1024+1),ok=False)
        assert p.evaluate('historyFileReads')==0
        fill(p,expected,password,archive)
        p.locator('#expected').fill(json.dumps(expected,ensure_ascii=False)[:-1]+',"extra":"'+('한'*1200)+'"}')
        assert len(p.locator('#expected').input_value())<4096
        p.locator('#read').click();expect(p.locator('#read')).to_be_enabled()
        expect(p.locator('#status')).to_contain_text('입력과 파일 크기')
        assert p.evaluate('historyFileReads')==0
        proof['checks']['history_dom_oversized_file_and_utf8_binding_denied_before_arraybuffer']=True
        # Current signed actor cannot silently switch to a different archive owner.
        context.clear_cookies();context.add_cookies(b.context.cookies())
        open_read(ok=False)
        context.clear_cookies();context.add_cookies(a.context.cookies())
        open_read()
        p.route('**/v1/session',lambda route:route.fulfill(status=401,body='denied'))
        p.locator('#messages button').first.click()
        expect(p.locator('#result')).to_be_hidden(timeout=10000)
        assert p.evaluate('liveBlobURLs.size')==0
        p.unroute('**/v1/session')
        proof['checks']['history_dom_actual_signed_actor_switch_and_denied_download_clear_view']=True
        # Hold KDF admission, then lock. A retired worker cannot publish late output.
        p.evaluate("()=>{window.kdfHeld=false;navigator.locks.request('family-native-vault-kdf',()=>new Promise(resolve=>{window.releaseKDF=resolve;window.kdfHeld=true}))}")
        p.wait_for_function('()=>kdfHeld')
        fill(p,expected,password,archive);p.locator('#read').click()
        p.wait_for_function("async()=>{const q=await navigator.locks.query();return q.pending.some(x=>x.name==='family-native-vault-kdf')}")
        p.locator('#lock').click();p.evaluate('()=>releaseKDF()')
        expect(p.locator('#result')).to_be_hidden();assert p.locator('#password').input_value()==''
        open_read()
        # Shared lock channel also clears the recovered DOM; no auto unlock.
        sibling=context.new_page();sibling.goto(url+'/history/');sibling.locator('#lock').click()
        expect(p.locator('#result')).to_be_hidden();assert p.evaluate('liveBlobURLs.size')==0;sibling.close()
        proof['checks']['history_dom_kdf_late_completion_and_sibling_lock_retirement']=True
        open_read()
        p.evaluate("()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});document.dispatchEvent(new Event('visibilitychange'))}")
        expect(p.locator('#result')).to_be_hidden();assert p.evaluate('liveBlobURLs.size')==0
        p.evaluate("()=>{delete document.hidden}")
        proof['checks']['history_dom_hidden_view_clears_and_never_auto_reopens']=True
        # Reload carries no secret, automatically accepted pins, or open history.
        p.reload();assert p.locator('#password').input_value()==p.locator('#expected').input_value()==''
        expect(p.locator('#result')).to_be_hidden();open_read()
        assert p.evaluate('sessionStorage.length+localStorage.length')==0
        assert p.evaluate('async()=>await indexedDB.databases()')==[]
        assert all(method=='GET' and u.split('/v1/',1)[1]=='session' for method,u in requests if '/v1/' in u)
        assert not errors,errors
        proof['checks']['history_dom_reload_no_secrets_no_native_delivery_or_idb_import']=True
        p.set_viewport_size({'width':390,'height':844})
        assert p.evaluate('document.documentElement.scrollWidth<=innerWidth')
        proof['checks']['history_dom_390px_layout']=True
    finally:context.close()
