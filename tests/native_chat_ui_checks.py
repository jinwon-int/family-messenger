"""DOM-driven generated-data checks for the isolated native chat page."""
import hashlib
import json
import time
import secrets
from pathlib import Path
from playwright.sync_api import sync_playwright, expect


def run_ui(work,url,cookies,config,commit,direct,proof,hold_next,arrived,release,tamper,page_url=None,restart=None,vault=False,history=False,history_ui=False,history_embedded=False,aggregate=False,aggregate_history_embedded=False):
    passwords=[secrets.token_urlsafe(32),secrets.token_urlsafe(32)]
    initialized=set();draft_prefix='family-aggregate-ui-draft-v1' if aggregate else 'family-vault-ui-draft-v1' if vault else 'family-native-ui-draft-v1'
    with sync_playwright() as pw:
        profiles=[work/'ui-alice',work/'ui-bob']
        for p in profiles:p.mkdir(mode=0o700)
        contexts=[pw.chromium.launch_persistent_context(str(p),accept_downloads=True) for p in profiles]
        try:
            def configure(c,i):
                c.add_cookies([{'name':'synthetic_edge','value':cookies[i],'url':url,'httpOnly':True,'sameSite':'Strict'}])
                c.add_init_script("window.liveBlobURLs=new Set();const make=URL.createObjectURL,drop=URL.revokeObjectURL;URL.createObjectURL=function(...a){const u=make.apply(this,a);window.liveBlobURLs.add(u);return u};URL.revokeObjectURL=function(u){window.liveBlobURLs.delete(u);return drop.call(this,u)}")
            for i,c in enumerate(contexts):configure(c,i)
            pages=[c.new_page() for c in contexts]
            for p in pages:p.goto(page_url or url)
            if vault:
                errors=[]
                for p in pages:p.on('pageerror',lambda error:errors.append(str(error)));p.locator('#refresh').click();p.evaluate('()=>true')
                assert not errors,errors
                proof['checks']['refresh_before_unlock_is_safe']=True
            proof['browser']=contexts[0].browser.version
            def crash_page(i):
                import os,signal
                cdp=contexts[i].browser.new_browser_cdp_session()
                pid=next(int(x['id']) for x in cdp.send('SystemInfo.getProcessInfo')['processInfo'] if x['type']=='browser')
                assert ('--user-data-dir='+str(profiles[i])).encode() in Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                os.kill(pid,signal.SIGKILL)
                try:contexts[i].close()
                except Exception:pass
                contexts[i]=pw.chromium.launch_persistent_context(str(profiles[i]),accept_downloads=True);configure(contexts[i],i)
                pages[i]=contexts[i].new_page();pages[i].goto(page_url or url);return pages[i]
            def click_open(p,i=None):
                if vault:
                    if i is None:i=next(i for i,c in enumerate(contexts) if p.context==c)
                    p.locator('#vault-password').fill(passwords[i]);p.locator('#vault-create').set_checked(i not in initialized)
                p.locator('#open').click()
            def open_page(p):
                click_open(p);expect(p.locator('#device')).to_be_visible(timeout=25000)
                if vault:
                    initialized.add(next(i for i,c in enumerate(contexts) if p.context==c))
                    assert p.locator('#vault-password').input_value()==''

            for p in pages:open_page(p)
            a,b=pages
            pins=[]
            for actor,p in zip(('alice','bob'),pages):
                key=p.locator('#fingerprint').get_attribute('data-public-key')
                fingerprint=p.locator('#fingerprint').inner_text()
                assert len(key)==64 and fingerprint==hashlib.sha256(bytes.fromhex(key)).hexdigest()
                pins.append({'device_id':actor+'-first','actor':actor,'signing_key':key,'fingerprint':fingerprint,'device_revision':1})
            assert a.locator('#join').is_disabled() and b.locator('#join').is_disabled()
            config['devices']=[{**p,'subject':sub,'status':'active','acceptance':'out-of-band-fingerprint'} for p,sub in zip(pins,('owner','family'))]
            commit(1,config['people'])
            until=time.monotonic()+5
            while time.monotonic()<until:
                code,data=direct('owner','GET','/v1/rooms/family/devices')
                if code==200 and len(data['devices'])==2:break
                time.sleep(.05)
            else:raise AssertionError('directory reload')
            def pin(p,bad=False):
                p.locator('#alice-pin').fill(pins[0]['fingerprint']);p.locator('#bob-pin').fill('0'*64 if bad else pins[1]['fingerprint']);p.locator('#pin-form button').click()
            pin(a,True);expect(a.locator('#device')).to_be_hidden(timeout=10000);assert a.locator('#fingerprint').inner_text()==''
            open_page(a);assert a.locator('#fingerprint').get_attribute('data-public-key')==pins[0]['signing_key']
            for p in pages:pin(p);expect(p.locator('#join')).to_be_enabled()
            proof['checks']['signed_bootstrap_explicit_independent_fingerprints_and_wrong_pin_denial']=True
            a.locator('#join').click();expect(a.locator('#join')).to_be_hidden(timeout=10000);b.locator('#join').click()
            for p in pages:expect(p.locator('#phase')).to_contain_text('암호화 연결됨',timeout=20000)
            proof['checks']['dom_native_initial_handshake_ready']=True
            def send(p,text):p.locator('#text').fill(text);p.locator('#send').click()
            message='synthetic UI 한글 <img src=x onerror=alert(1)>'
            send(a,message)
            for p in pages:expect(p.locator('#messages')).to_contain_text(message,timeout=25000)
            assert a.locator('#messages img').count()==b.locator('#messages img').count()==0
            proof['checks']['two_browser_dom_encrypted_text_safe_render']=True
            payload=bytes(range(256))*4
            b.locator('#file').set_input_files({'name':'../synthetic.html','mimeType':'text/html','buffer':payload});b.locator('#send').click()
            expect(a.locator('#messages button')).to_have_count(1,timeout=25000)
            with a.expect_download() as download_info:a.locator('#messages button').click()
            download=download_info.value;assert download.suggested_filename.startswith('synthetic-app-') and download.suggested_filename.endswith('.bin')
            assert Path(download.path()).read_bytes()==payload
            assert a.locator('iframe,img,video').count()==0
            open_page(a);assert a.evaluate('window.liveBlobURLs.size')==0
            proof['checks']['reopen_releases_download_blob_urls']=True
            proof['checks']['encrypted_opaque_file_authenticated_download_integrity_no_active_preview']=True
            # Drop the first prepare command in the disposable page only. The
            # metadata draft exists, but bytes never reach the worker/IDB.
            b.evaluate("()=>{window.heldPrepare=false;const post=Worker.prototype.postMessage;Worker.prototype.postMessage=function(data,...rest){if(data.method==='prepare'&&!window.heldPrepare){window.heldPrepare=true;setTimeout(()=>document.documentElement.dataset.syntheticHeldPrepare='true',150);return}return post.call(this,data,...rest)}}")
            reselect=b'synthetic exact reselection'
            b.locator('#file').set_input_files({'name':'reselect.bin','mimeType':'application/octet-stream','buffer':reselect});b.locator('#send').click()
            # A delayed DOM marker exercises async waiting without page-side eval
            # (wait_for_function string predicates can violate the real CSP).
            expect(b.locator('html')).to_have_attribute('data-synthetic-held-prepare','true')
            metadata=json.loads(b.evaluate('key=>sessionStorage.getItem(key)',draft_prefix+':bob:family'))
            assert metadata['size']==len(reselect) and metadata['sha256']==hashlib.sha256(reselect).hexdigest()
            retry_id=metadata['id'];b.reload();open_page(b)
            expect(b.locator('#pending')).to_contain_text('다시 선택');expect(b.locator('#file')).to_be_enabled();expect(b.locator('#text')).to_be_enabled()
            b.locator('#file').set_input_files({'name':'wrong.bin','mimeType':'application/octet-stream','buffer':b'wrong bytes'});b.locator('#send').click()
            expect(b.locator('#chat')).to_be_hidden(timeout=10000);open_page(b)
            b.locator('#file').set_input_files({'name':'renamed.bin','mimeType':'application/octet-stream','buffer':reselect});b.locator('#send').click()
            expect(a.locator(f'#messages li[data-message-id="{retry_id}"]')).to_have_count(1,timeout=25000)
            # Peer delivery can precede the sender's ordered self-echo/render.
            # Only the sender's own committed history permits draft cleanup.
            expect(b.locator(f'#messages li[data-message-id="{retry_id}"]')).to_have_count(1,timeout=25000)
            assert b.evaluate('key=>sessionStorage.getItem(key)',draft_prefix+':bob:family') is None
            proof['checks']['interrupted_before_stage_requires_exact_reselection_and_same_id']=True
            # UI rejects too-large files before creating another durable draft.
            b.locator('#file').set_input_files({'name':'large.bin','mimeType':'application/octet-stream','buffer':b'x'*8193});b.locator('#send').click()
            expect(b.locator('#chat')).to_be_hidden(timeout=10000)
            assert b.evaluate('key=>sessionStorage.getItem(key)',draft_prefix+':bob:family') is None
            open_page(b)
            proof['checks']['ui_small_file_limit_denies_before_draft_creation']=True
            # Native accepts, but no successful flush reply reaches the page.
            hold_next[0]=True;arrived.clear();release.clear();lost='synthetic UI lost response'
            send(a,lost);assert arrived.wait(4)
            expect(a.locator('#pending')).to_contain_text('암호화 저장됨')
            expect(a.locator('#text')).to_be_disabled();expect(a.locator('#file')).to_be_disabled()
            proof['checks']['pending_send_freezes_composer_without_blocking_metadata_reselection']=True
            pending_id=a.locator('#pending').get_attribute('data-client-id');assert pending_id.startswith('app-')
            assert a.locator(f'#messages li[data-message-id="{pending_id}"]').count()==0
            saved=a.evaluate('Object.values(sessionStorage)');assert saved and all(lost not in s and 'eyJ' not in s for s in saved)
            if vault:a=crash_page(0)
            else:a.reload()
            release.set();open_page(a)
            expect(a.locator(f'#messages li[data-message-id="{pending_id}"]')).to_have_count(1,timeout=25000)
            expect(b.locator(f'#messages li[data-message-id="{pending_id}"]')).to_have_count(1,timeout=25000)
            assert a.locator('#fingerprint').get_attribute('data-public-key')==pins[0]['signing_key']
            proof['checks']['lost_native_reply_actual_browser_sigkill_exact_id_no_early_display' if vault else 'lost_native_reply_reload_reconciles_exact_id_no_early_display']=True
            before=b.locator('#messages li').count();b.reload();open_page(b);expect(b.locator('#messages li')).to_have_count(before,timeout=25000)
            proof['checks']['receiver_reload_restores_committed_history_without_duplicates']=True
            if restart:
                restart()
                for i,p in enumerate(pages):
                    open_page(p);expect(p.locator('#messages')).to_contain_text(lost,timeout=25000)
                    assert p.locator('#fingerprint').get_attribute('data-public-key')==pins[i]['signing_key']
                proof['checks']['compiled_server_restart_preserves_identity_and_encrypted_history']=True
            if aggregate:
                from native_aggregate_ui_checks import checks as aggregate_checks
                a=aggregate_checks(a,b,contexts,pages,url,open_page,click_open,passwords,pins,proof,direct,crash_page,hold_next,arrived,release,restart=restart)
            tamper[0]='cipher';send(a,'synthetic UI altered wire')
            for p in pages:expect(p.locator('#chat')).to_be_hidden(timeout=25000)
            tamper[0]=None
            for p in pages:open_page(p);expect(p.locator('#messages')).to_contain_text('synthetic UI altered wire',timeout=25000)
            proof['checks']['tampered_native_log_hides_view_then_original_reconciles']=True
            # An upstream account change cannot reuse the tab's expected actor or
            # silently initialize the other registered device in this profile.
            contexts[0].add_cookies([{'name':'synthetic_edge','value':cookies[1],'url':url,'httpOnly':True,'sameSite':'Strict'}])
            expect(a.locator('#chat')).to_be_hidden(timeout=25000)
            click_open(a);expect(a.locator('#status')).to_contain_text('연결 또는 기기 확인',timeout=25000)
            assert a.locator('#fingerprint').inner_text()=='' and a.locator('#messages li').count()==0
            contexts[0].add_cookies([{'name':'synthetic_edge','value':cookies[0],'url':url,'httpOnly':True,'sameSite':'Strict'}]);open_page(a)
            expect(a.locator('#messages')).to_contain_text(message,timeout=25000)
            proof['checks']['account_switch_clears_protected_ui_no_registered_key_regeneration']=True
            a.locator('#room').fill('different-room');expect(a.locator('#chat')).to_be_hidden();assert a.locator('#messages li').count()==0
            a.locator('#room').fill('family');open_page(a);expect(a.locator('#messages')).to_contain_text(message,timeout=25000)
            proof['checks']['editing_room_retires_old_view_before_next_admission']=True
            a.set_viewport_size({'width':390,'height':844})
            assert a.evaluate('document.documentElement.scrollWidth<=innerWidth')
            a.screenshot(path=str(work/'synthetic-ui-390.png'),full_page=True)
            proof['checks']['mobile_width_layout_only']=True
            if history:
                if history_embedded:
                    from native_history_ui_checks import native_checks
                    a=native_checks(a,b,contexts,url,passwords,pins,proof,crash_page,open_page,direct)
                else:
                    from native_history_checks import checks as history_checks
                    a=history_checks(a,b,contexts,pages,url,passwords,pins,proof,crash_page,open_page,direct,history_ui=history_ui)
            if vault:
                from native_vault_ui_checks import checks
                checks(a,b,contexts,pages,page_url or url,open_page,click_open,passwords,proof,database='family-mls-device-vault-synthetic-ui-alice' if aggregate else 'family-mls-vault-synthetic-ui-alice-family')
            recovered_after_revocation=None
            if aggregate_history_embedded:
                from native_aggregate_history_embedded_checks import native_checks
                a,recovered_after_revocation=native_checks(a,b,contexts,url,passwords,pins,proof,crash_page,open_page,direct,restart,config,commit)
            config['devices'][1]['status']='revoked';config['devices'][1]['device_revision']=2;commit(2,config['people'])
            for p in pages:
                expect(p.locator('#chat')).to_be_hidden(timeout=25000)
                assert p.locator('#messages li').count()==0 and p.locator('#fingerprint').inner_text()==''
                click_open(p);expect(p.locator('#status')).to_contain_text('연결 또는 기기 확인',timeout=25000)
            proof['checks']['durable_revocation_clears_ui_and_denies_reopen']=True
            if recovered_after_revocation:recovered_after_revocation()
            if aggregate:proof['native_aggregate_ui']=True
            elif vault:proof['native_vault_ui']=True
            proof['native_encrypted_ui']=True
            proof['ui_packaging']='isolated exact-allowlist test proxy; not Go embedded or deployed'
        finally:
            if not proof.get('native_encrypted_ui'):
                for p in pages:
                    try:
                        labels=[p.locator('#'+key).inner_text(timeout=500) if p.locator('#'+key).count() else '' for key in ('status','phase','pending')]
                        print('UI diagnostic:',*labels,flush=True)
                    except Exception:pass  # Never mask the actual failure after navigation/close.
            release.set()
            for c in contexts:c.close()
