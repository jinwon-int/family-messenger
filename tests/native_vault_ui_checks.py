"""Additional DOM custody checks with disposable passwords and encrypted bytes."""
import json
import time
import re
from playwright.sync_api import expect


def checks(a,b,contexts,pages,url,open_page,click_open,passwords,proof):
    # Public ciphertext only; never read decoded private provider/cache in page.
    def snapshot(p):
        return p.evaluate('''async()=>{const d=await new Promise((r,j)=>{const q=indexedDB.open('family-mls-vault-synthetic-ui-alice-family');q.onsuccess=()=>r(q.result);q.onerror=j});const v=await new Promise((r,j)=>{const q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();return {keys:Object.keys(v).sort(),capsule:Array.from(v.capsule),header:Array.from(v.header),cipher:Array.from(v.cipher),revision:v.revision}}''')
    before=snapshot(a)
    assert before['keys']==sorted(['v','identity','room','vault','revision','capsule','header','cipher'])
    for i,p in enumerate(pages):
        values=p.evaluate('Object.values(sessionStorage).concat(Object.values(localStorage))')
        assert all(passwords[i] not in v and 'crypto' not in v for v in values)
        assert p.locator('#vault-password').input_value()==''
    proof['checks']['vault_ui_encrypted_whole_idb_and_no_persisted_password']=True
    # Explicit lock retires an active same-actor/same-DB sibling and clears DOM.
    sibling=contexts[0].new_page();sibling.goto(url);open_page(sibling)
    expect(sibling.locator('#messages li')).not_to_have_count(0)
    a.locator('#lock').click()
    for p in [a,sibling]:
        expect(p.locator('#device')).to_be_hidden();expect(p.locator('#messages li')).to_have_count(0)
        assert p.evaluate('window.liveBlobURLs.size')==0
    assert snapshot(a)==before
    # Missing password does not reopen; wrong password is denied without changes.
    a.locator('#open').click();expect(a.locator('#device')).to_be_hidden()
    a.locator('#vault-password').fill('wrong-synthetic-password-'+'x'*20);a.locator('#open').click()
    expect(a.locator('#status')).to_contain_text('연결 또는 기기 확인',timeout=25000)
    assert snapshot(a)==before
    open_page(a)
    assert a.locator('#fingerprint').inner_text()
    proof['checks']['explicit_sibling_lock_wrong_password_and_exact_state_preservation']=True
    # Delayed signed bootstrap cannot resurrect a locked page or retain input.
    held=[]
    a.route('**/v1/session',lambda route:held.append(route))
    click_open(a)
    expect(a.locator('#status')).to_contain_text('시험 계정 확인 중')
    deadline=time.monotonic()+5
    while not held and time.monotonic()<deadline:a.wait_for_timeout(25)
    assert held
    a.locator('#lock').click()
    for route in held:
        try:route.continue_()
        except Exception:pass  # AbortController may already have canceled request.
    a.unroute('**/v1/session')
    expect(a.locator('#status')).to_contain_text('잠겼습니다')
    expect(a.locator('#device')).to_be_hidden()
    assert a.locator('#vault-password').input_value()==''
    open_page(a)
    proof['checks']['late_bootstrap_after_lock_cannot_unlock_or_restore_protected_view']=True
    # Corruption in the actual UI database, not merely another namespace.
    a.locator('#lock').click()
    a.evaluate('''async()=>{const d=await new Promise(r=>{const q=indexedDB.open('family-mls-vault-synthetic-ui-alice-family');q.onsuccess=()=>r(q.result)});await new Promise((r,j)=>{const t=d.transaction('device','readwrite'),s=t.objectStore('device'),q=s.get('state');q.onsuccess=()=>{window.savedEncryptedVault=q.result;const v=structuredClone(q.result);v.cipher[v.cipher.length-1]^=1;s.put(v,'state')};t.oncomplete=r;t.onabort=j});d.close()}''')
    damaged=snapshot(a);click_open(a)
    expect(a.locator('#status')).to_contain_text('연결 또는 기기 확인',timeout=25000)
    assert snapshot(a)==damaged
    a.evaluate('''async()=>{const d=await new Promise(r=>{const q=indexedDB.open('family-mls-vault-synthetic-ui-alice-family');q.onsuccess=()=>r(q.result)});await new Promise((r,j)=>{const t=d.transaction('device','readwrite');t.objectStore('device').put(window.savedEncryptedVault,'state');t.oncomplete=r;t.onabort=j});d.close()}''')
    open_page(a)
    proof['checks']['ui_corrupt_record_retained_and_denied_no_plaintext_or_reset_fallback']=True
    # Force structured-clone failure at init. New worker must retire immediately;
    # its old request timer must not close the next successfully unlocked session.
    before=snapshot(a)
    a.evaluate('''()=>{const post=Worker.prototype.postMessage,stop=Worker.prototype.terminate;Worker.prototype.terminate=function(...args){window.cloneWorkerStopped=true;return stop.apply(this,args)};Worker.prototype.postMessage=function(data,...args){if(data.method==='init'){Worker.prototype.postMessage=post;window.cloneWorkerStopped=false;throw new DOMException('synthetic clone failure','DataCloneError')}return post.call(this,data,...args)}}''')
    click_open(a);expect(a.locator('#status')).to_contain_text('연결 또는 기기 확인',timeout=5000)
    assert a.evaluate('window.cloneWorkerStopped') is True and snapshot(a)==before
    assert a.locator('#vault-password').input_value()==''
    open_page(a)
    a.evaluate('''()=>{window.idleSyncCalls=0;const post=Worker.prototype.postMessage;Worker.prototype.postMessage=function(data,...args){if(data.method==='sync')window.idleSyncCalls++;return post.call(this,data,...args)};setTimeout(()=>document.documentElement.dataset.idleProof='done',32000)}''')
    expect(a.locator('html')).to_have_attribute('data-idle-proof','done',timeout=35000)
    assert 1<=a.evaluate('window.idleSyncCalls')<=5
    expect(a.locator('#chat')).to_be_visible()
    proof['checks']['clone_failure_retires_immediately_old_deadline_does_not_lock_new_session']=True
    proof['checks']['idle_poll_backoff_bounds_sync_work_without_expanding_worker_quota']=True

    # Hold native polling after the worker has begun an async sync operation.
    polls=[]
    poll_route=re.compile(r'/v1/mls/rooms/family/log\?after=\d+$')
    a.route(poll_route,lambda route:polls.append(route))
    a.locator('#refresh').click()
    deadline=time.monotonic()+5
    while not polls and time.monotonic()<deadline:a.wait_for_timeout(25)
    assert polls
    expect(a.locator('#send')).to_be_disabled();expect(a.locator('#refresh')).to_be_disabled()
    a.locator('#text').fill('synthetic send after busy poll')
    for route in polls:route.continue_()
    a.unroute(poll_route)
    expect(a.locator('#send')).to_be_enabled(timeout=10000)
    assert a.locator('#text').input_value()=='synthetic send after busy poll'
    a.locator('#send').click()
    for p in [a,b]:expect(p.locator('#messages')).to_contain_text('synthetic send after busy poll',timeout=25000)
    proof['checks']['async_poll_disables_actions_synchronously_and_preserves_unsent_composer']=True
