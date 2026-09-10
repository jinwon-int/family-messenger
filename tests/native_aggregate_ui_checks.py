"""Generated DOM clients for the complete native adapter, not generic admission."""
import hashlib
import json
from pathlib import Path
from playwright.sync_api import expect


def checks(a,b,contexts,pages,url,open_page,click_open,passwords,pins,proof,direct,crash_page,hold_next,arrived,release):
    def select(p,room):
        p.locator('#room').fill(room);expect(p.locator('#chat')).to_be_hidden();open_page(p)
    def prepare(p,i):
        p.locator('#target-room').fill('second')
        p.locator('#context-id').fill('context-ui-'+str(i))
        p.locator('#prepare-password').fill(passwords[i]);p.locator('#prepare-room').click()
    def accepted(p):
        expect(p.locator('#preparation-status')).to_contain_text('서버 준비 접수 완료',timeout=25000)
        assert p.locator('#prepare-password').input_value()==''
        expect(p.locator('#chat')).to_be_hidden()
    # Stage a source message but lose the page-to-worker flush command. The
    # encrypted outbox must survive preparation and switching without auto-send.
    a.evaluate("()=>{const post=Worker.prototype.postMessage;Worker.prototype.postMessage=function(data,...rest){if(data.method==='flush'){Worker.prototype.postMessage=post;setTimeout(()=>document.documentElement.dataset.sourcePending='true',150);return}return post.call(this,data,...rest)}}")
    source_text='synthetic pending before second context'
    a.locator('#text').fill(source_text);a.locator('#send').click()
    expect(a.locator('html')).to_have_attribute('data-source-pending','true')
    pending_id=a.locator('#pending').get_attribute('data-client-id')
    assert pending_id.startswith('app-')
    a.locator('#lock').click();open_page(a)
    assert a.locator('#pending').get_attribute('data-client-id')==pending_id
    # A locally committed context and accepted declaration survive a lost reply.
    # Old conversation drafts remain namespaced and no target bind occurs here.
    hold_next[0]=True;arrived.clear();release.clear();prepare(a,0)
    assert arrived.wait(8)
    assert a.locator('#messages li').count()==0 and a.locator('#vault-password').input_value()==''
    code,descriptor=direct('owner','GET','/v1/mls/rooms/second/preparation')
    assert code==200 and len(descriptor['prepared'])==1
    assert direct('owner','GET','/v1/mls/rooms/second')[0]!=200
    a=crash_page(0);release.set();open_page(a);prepare(a,0);accepted(a)
    code,retry=direct('owner','GET','/v1/mls/rooms/second/preparation')
    assert code==200 and retry==descriptor
    proof['checks']['dom_preparation_commit_lost_reply_sigkill_exact_intent_retry']=True
    select(a,'second')
    assert a.locator('#fingerprint').get_attribute('data-public-key')==pins[0]['signing_key']
    a.locator('#join').click()
    expect(a.locator('#status')).to_contain_text('상대 기기의 준비를 기다립니다')
    expect(a.locator('#join')).to_be_visible();expect(a.locator('#join')).to_be_enabled()
    assert a.locator('#messages li').count()==0
    assert direct('owner','GET','/v1/mls/rooms/second')[0]!=200
    proof['checks']['dom_one_preparation_does_not_create_bind_or_claim_mls_ready']=True
    prepare(b,1);accepted(b)
    expect(b.locator('#preparation-status')).to_contain_text('양쪽 기기 준비 완료')
    select(b,'second')
    a.locator('#join').click();expect(a.locator('#join')).to_be_hidden(timeout=10000)
    b.locator('#join').click()
    for i,p in enumerate(pages):
        expect(p.locator('#phase')).to_contain_text('암호화 연결됨',timeout=25000)
        assert p.locator('#fingerprint').get_attribute('data-public-key')==pins[i]['signing_key']
        assert p.locator('#messages li').count()==0
    proof['checks']['dom_both_committed_preparations_then_fresh_group_ack_same_enrolled_keys']=True
    text='synthetic second-room only'
    a.locator('#text').fill(text);a.locator('#send').click()
    for p in pages:expect(p.locator('#messages')).to_contain_text(text,timeout=25000)
    payload=bytes(range(256))*32
    b.locator('#file').set_input_files({'name':'synthetic-second.bin','mimeType':'application/octet-stream','buffer':payload});b.locator('#send').click()
    expect(a.locator('#messages button')).to_have_count(1,timeout=25000)
    with a.expect_download() as download:a.locator('#messages button').click()
    assert hashlib.sha256(Path(download.value.path()).read_bytes()).digest()==hashlib.sha256(payload).digest()
    proof['checks']['dom_second_room_text_and_actual_8kib_encrypted_download']=True
    for p in pages:
        select(p,'family');expect(p.locator('#messages')).to_contain_text('synthetic UI lost response',timeout=25000)
        assert text not in p.locator('#messages').inner_text()
        assert p.evaluate('window.liveBlobURLs.size')==0
        select(p,'second');expect(p.locator('#messages')).to_contain_text(text,timeout=25000)
    proof['checks']['dom_explicit_password_room_switch_preserves_isolated_committed_histories']=True
    select(a,'family')
    assert a.locator('#pending').get_attribute('data-client-id')==pending_id
    assert a.locator(f'#messages li[data-message-id="{pending_id}"]').count()==0
    a.locator('#retry').click()
    expect(a.locator(f'#messages li[data-message-id="{pending_id}"]')).to_have_count(1,timeout=25000)
    assert a.locator(f'#messages li[data-message-id="{pending_id}"]').inner_text().endswith(source_text)
    proof['checks']['dom_original_pending_survives_preparation_room_switch_until_exact_explicit_retry']=True
    # Conflicting target input cannot overwrite the committed immutable intent.
    select(a,'family')
    before=a.evaluate('()=>sessionStorage.getItem("family-aggregate-ui-intent-v1:alice")')
    # SIGKILL may discard sessionStorage, but the exact retried intent was saved again.
    assert json.loads(before)['target']=='second'
    a.locator('#target-room').fill('third');a.locator('#context-id').fill('context-ui-other')
    a.locator('#prepare-password').fill(passwords[0]);a.locator('#prepare-room').click()
    expect(a.locator('#chat')).to_be_hidden()
    assert a.evaluate('()=>sessionStorage.getItem("family-aggregate-ui-intent-v1:alice")')==before
    assert direct('owner','GET','/v1/mls/rooms/third/preparation')[0]!=200
    select(a,'second');expect(a.locator('#messages')).to_contain_text(text,timeout=25000)
    proof['checks']['dom_conflicting_target_retains_original_intent_and_complete_context']=True
    # Reopen both original rooms for the shared identity/revocation/custody suite.
    for p in pages:select(p,'family')
    return a
