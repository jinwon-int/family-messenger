#!/usr/bin/env python3
"""Synthetic-only CF-style header injection; never a deployable auth proxy."""
import argparse
import base64
import hashlib
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zlib

from playwright.sync_api import sync_playwright, expect, Error as BrowserError


def main():
    args = argparse.ArgumentParser()
    args.add_argument('--binary', required=True, type=Path)
    args.add_argument('--policy-binary', required=True, type=Path)
    args = args.parse_args()
    binary, policy = args.binary.resolve(strict=True), args.policy_binary.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    work = Path(tempfile.mkdtemp(prefix='native-signed-browser-', dir=root / 'artifacts'))
    state, auth, proposals = [work / n for n in ('state', 'auth', 'proposals')]
    for d in (state, auth, proposals):
        d.mkdir(mode=0o700)
    proof = {'synthetic_only': True, 'production_cf_gate': False, 'e2ee': False,
             'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    key = proposals / 'synthetic-private.pem'
    key.write_bytes(subprocess.check_output(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048'], stderr=subprocess.DEVNULL))
    key.chmod(0o600)
    modulus = subprocess.check_output(['openssl', 'rsa', '-in', str(key), '-noout', '-modulus'], stderr=subprocess.DEVNULL).decode().strip().split('=', 1)[1]
    b64 = lambda b: base64.urlsafe_b64encode(b).decode().rstrip('=')
    config = {'version': 1, 'issuer': 'https://synthetic.cloudflareaccess.com', 'audience': 'synthetic-app',
              'keys': [{'kid': 'test-key', 'n': b64(bytes.fromhex(modulus)), 'e': 65537}],
              'people': [{'subject': 'owner', 'actor': 'alice', 'owner': True}, {'subject': 'family', 'actor': 'bob', 'owner': False}]}
    tokens = {}
    for subject in ('owner', 'family'):
        for expired in (False, True):
            now = int(time.time())
            claims = {'iss': config['issuer'], 'aud': [config['audience']], 'sub': subject, 'type': 'app',
                      'iat': now - 60, 'nbf': now - 60, 'exp': now - 1 if expired else now + 900, 'role': 'owner'}
            raw = b64(json.dumps({'alg': 'RS256', 'typ': 'JWT', 'kid': 'test-key'}).encode()) + '.' + b64(json.dumps(claims).encode())
            tokens[subject, expired] = raw + '.' + b64(subprocess.check_output(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=raw.encode()))
    def commit(revision, people):
        candidate = proposals / f'candidate-{revision}.json'
        candidate.write_text(json.dumps({**config, 'people': people}))
        candidate.chmod(0o600)
        r = subprocess.run([str(policy), '--synthetic-only', '--auth-state', str(auth), '--input', str(candidate), '--expected-revision', str(revision)], capture_output=True, text=True, timeout=5)
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout)['revision'] == revision + 1
    commit(0, config['people'])
    process = output = proxy = None
    address = '127.0.0.1:0'
    def start():
        nonlocal process, output, address
        log = work / 'server.log'
        output = log.open('ab')
        offset = log.stat().st_size
        process = subprocess.Popen([str(binary), '--synthetic-only', '--state', str(state), '--auth-state', str(auth), '--listen', address], stderr=output, stdout=subprocess.DEVNULL)
        until = time.monotonic() + 10
        while time.monotonic() < until:
            assert process.poll() is None, 'server exited'
            match = re.search(r'listening (127\.0\.0\.1:\d+)', log.read_bytes()[offset:].decode())
            if match:
                address = match[1]
                return
            time.sleep(.02)
        raise AssertionError('server startup timeout')
    def stop():
        if process and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        if output:
            output.close()
    def direct(subject, method, path, body=None):
        r = urllib.request.Request('http://' + address + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                   headers={'Cf-Access-Jwt-Assertion': tokens[subject, False], 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(r, timeout=5) as response:
                data = response.read()
                return response.status, json.loads(data) if data else None
        except urllib.error.HTTPError as e:
            e.close()
            return e.code, None

    # These opaque HttpOnly cookies model an already verified upstream identity.
    # There is deliberately no login, control, token-issuing or account route.
    bindings = {secrets.token_hex(16): 'owner', secrets.token_hex(16): 'family'}
    cookies = list(bindings)
    expired = set()
    lock = threading.Lock()
    requests = []
    class Proxy(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            self.forward()
        def do_POST(self):
            self.forward()
        def do_PUT(self):
            self.forward()
        def do_DELETE(self):
            self.forward()
        def forward(self):
            if self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}' or not self.path.startswith('/') or self.path.startswith('//'):
                self.send_error(400)
                return
            if any(k.lower() == 'authorization' or k.lower().startswith('cf-') for k in self.headers):
                self.send_error(400)
                return
            c = SimpleCookie()
            c.load(self.headers.get('Cookie', ''))
            cookie = c.get('synthetic_edge')
            credential = cookie.value if cookie else None
            with lock:
                subject = bindings.get(credential)
                is_expired = credential in expired
                requests.append({'path': self.path, 'actor': self.headers.get('X-Family-Actor'), 'subject': subject})
            size = int(self.headers.get('Content-Length', '0'))
            if size < 0 or size > 8 * 1024 * 1024:
                self.send_error(413)
                return
            body = self.rfile.read(size) if size else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in ('cookie', 'connection', 'host', 'content-length', 'transfer-encoding')}
            headers['Host'] = f'127.0.0.1:{self.server.server_port}'
            if subject:
                headers['Cf-Access-Jwt-Assertion'] = tokens[subject, is_expired]
            upstream = http.client.HTTPConnection(address, timeout=40)
            try:
                upstream.request(self.command, self.path, body=body, headers=headers)
                response = upstream.getresponse()
                self.send_response(response.status)
                for k, v in response.getheaders():
                    if k.lower() not in ('connection', 'transfer-encoding', 'server', 'date'):
                        self.send_header(k, v)
                self.end_headers()
                while True:
                    data = response.read1(32768)
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
            except (OSError, http.client.HTTPException):
                pass
            finally:
                upstream.close()
    try:
        start()
        assert direct('owner', 'POST', '/v1/rooms', {'id': 'family', 'members': ['bob']})[0] == 201
        assert direct('owner', 'POST', '/v1/rooms', {'id': 'private', 'members': []})[0] == 201
        proxy = ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
        proxy.daemon_threads = False
        thread = threading.Thread(target=proxy.serve_forever, daemon=True)
        thread.start()
        url = f'http://127.0.0.1:{proxy.server_port}'
        with sync_playwright() as p:
            browser = p.chromium.launch()
            expect.set_options(timeout=15000)
            contexts = [browser.new_context(viewport={'width': 1100, 'height': 900}) for _ in cookies]
            for ctx, cookie in zip(contexts, cookies):
                ctx.add_cookies([{'name': 'synthetic_edge', 'value': cookie, 'url': url, 'httpOnly': True, 'sameSite': 'Strict'}])
                ctx.add_init_script("sessionStorage.setItem('family-synthetic-pending-v1:alice:family',JSON.stringify({actor:'alice',room:'family',client_id:'fixture-only',payload:'eA=='}))")
                ctx.add_init_script('''(()=>{window.liveBlobs=new Set();const make=URL.createObjectURL.bind(URL),drop=URL.revokeObjectURL.bind(URL);URL.createObjectURL=b=>{const u=make(b);window.liveBlobs.add(u);return u};URL.revokeObjectURL=u=>{window.liveBlobs.delete(u);drop(u)}})()''')
            a,b = [ctx.new_page() for ctx in contexts]
            errors = []
            for page in (a,b):
                page.on('pageerror', lambda e: errors.append(str(e)))
                page.goto(url)
                expect(page.locator('#room-title')).to_have_text('family')
                expect(page.locator('#actor')).to_be_hidden()
                expect(page.locator('#actor')).to_be_disabled()
                assert page.evaluate('document.cookie') == ''
            expect(a.locator('#identity-name')).to_have_text('앨리스')
            expect(a.locator('#retry')).to_be_hidden()
            expect(b.locator('#identity-name')).to_have_text('밥')
            assert b.locator('[data-room="private"]').count() == 0
            who = b.evaluate("async()=>await(await fetch('/v1/session',{credentials:'same-origin'})).json()")
            assert who == {'mode': 'signed', 'actor': 'bob', 'owner': False}
            spoof = b.evaluate("async()=> (await fetch('/v1/session',{headers:{'Cf-Access-Jwt-Assertion':'spoof'}})).status")
            assert spoof == 400
            assert b.evaluate("async()=> (await fetch('/v1/rooms/private/messages',{headers:{'X-Family-Actor':'bob'}})).status") == 403
            proof['two_principals_bound_without_fixture_or_unsigned_owner_promotion'] = True

            anonymous = browser.new_context()
            unverified = anonymous.new_page()
            unverified.goto(url)
            expect(unverified.locator('#identity-name')).to_have_text('계정 확인 필요')
            expect(unverified.locator('#actor')).to_be_hidden()
            expect(unverified.locator('#send')).to_be_disabled()
            assert unverified.locator('#rooms button').count() == 0
            anonymous.close()
            # A late response for the previous upstream identity must not replace
            # a newer successful bootstrap (or revive aborted protected fetches).
            held = []
            def late_session(route):
                if not held:
                    response = route.fetch()
                    assert response.json()['actor'] == 'bob'
                    held.append((route, response))
                else:
                    route.continue_()
            b.route('**/v1/session', late_session)
            b.locator('#authenticate').click()
            until = time.monotonic() + 5
            while not held:
                assert time.monotonic() < until
                b.wait_for_timeout(20)
            with lock:
                bindings[cookies[1]] = 'owner'
            b.locator('#authenticate').click()
            expect(b.locator('#identity-name')).to_have_text('앨리스')
            try:
                held[0][0].fulfill(response=held[0][1])
            except BrowserError:
                pass  # Browser aborting the superseded request is also correct.
            b.wait_for_timeout(100)
            expect(b.locator('#identity-name')).to_have_text('앨리스')
            b.unroute('**/v1/session')
            with lock:
                bindings[cookies[1]] = 'family'
            b.locator('#authenticate').click()
            expect(b.locator('#identity-name')).to_have_text('밥')
            expect(b.locator('#room-title')).to_have_text('family')
            proof['missing_identity_and_late_bootstrap_do_not_fallback_or_override'] = True

            a.locator('#message').fill('synthetic signed hello')
            a.locator('#send').click()
            expect(b.locator('#messages')).to_contain_text('synthetic signed hello')
            def chunk(kind,data):
                return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
            png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\0\x80\xff'*2)*2))+chunk(b'IEND',b'')
            mp4 = (root/'tests/fixtures/native-media/blue.mp4').read_bytes()
            def card(page,name):
                return page.locator('.attachment').filter(has=page.locator('strong',has_text=name))
            def send_file(page,name,kind,data):
                page.locator('#file').set_input_files({'name':name,'mimeType':kind,'buffer':data})
                page.locator('#send').click()
                expect(page.locator('#send-status')).to_have_text('전송을 확인했습니다.')
            send_file(a,'signed.png','image/png',png)
            expect(card(b,'signed.png')).to_have_count(1)
            card(b,'signed.png').locator('.open-media').click()
            b.wait_for_function("()=>document.querySelector('.preview img')?.naturalWidth===2")
            send_file(b,'signed.mp4','video/mp4',mp4)
            expect(card(a,'signed.mp4')).to_have_count(1)
            card(a,'signed.mp4').locator('.open-media').click()
            a.wait_for_function("()=>document.querySelector('video')?.readyState>=2")
            a.locator('video').evaluate('async v=>{v.muted=true;await v.play()}')
            a.wait_for_function("()=>document.querySelector('video')?.ended===true")
            with b.expect_download() as d:
                card(b,'signed.mp4').locator('.download-media').click()
            assert Path(d.value.path()).read_bytes()==mp4
            proof['signed_text_png_decode_mp4_playback_and_download'] = True

            # Commit followed by lost response and reload; SSE cannot acknowledge
            # the request behind the test's back while its pending ID is checked.
            a.route('**/events?*',lambda route:route.abort())
            a.locator('#reconnect').click()
            sent=[]
            def lost(route):
                sent.append(json.loads(route.request.post_data)['client_id'])
                result=route.fetch()
                assert result.status==201
                route.abort()
            a.route('**/messages',lost)
            a.locator('#message').fill('synthetic lost response')
            a.locator('#send').click()
            expect(a.locator('#retry')).to_be_visible()
            expect(a.locator('#send-status')).to_contain_text('확인하지 못했습니다')
            pending=a.evaluate("JSON.parse(sessionStorage.getItem('family-signed-pending-v1:alice:family'))")
            assert pending['client_id']==sent[0]
            a.reload()
            expect(a.locator('#retry')).to_be_visible()
            a.unroute('**/messages')
            a.locator('#retry').click()
            expect(a.locator('#retry')).to_be_hidden()
            assert sum(x['client_id']==sent[0] for x in direct('owner','GET','/v1/rooms/family/messages')[1])==1
            a.unroute('**/events?*')
            a.locator('#reconnect').click()
            expect(a.locator('#messages')).to_contain_text('synthetic lost response')
            proof['signed_lost_response_reload_retry_keeps_exact_id'] = True

            # An uncommitted Alice pending request must never become Bob's send
            # when the upstream identity changes while this tab stays open.
            a.route('**/messages',lambda route:route.abort())
            a.locator('#message').fill('synthetic account switch pending')
            a.locator('#send').click()
            expect(a.locator('#retry')).to_be_visible()
            expect(a.locator('#send-status')).to_contain_text('확인하지 못했습니다')
            pending=a.evaluate("JSON.parse(sessionStorage.getItem('family-signed-pending-v1:alice:family'))")
            a.unroute('**/messages')
            with lock:
                bindings[cookies[0]]='family'
            a.locator('#retry').click()
            expect(a.locator('#identity-name')).to_have_text('계정 확인 필요')
            expect(a.locator('#send')).to_be_disabled()
            assert a.locator('#messages li').count()==0
            assert not any(x['client_id']==pending['client_id'] for x in direct('owner','GET','/v1/rooms/family/messages')[1])
            a.locator('#authenticate').click()
            expect(a.locator('#identity-name')).to_have_text('밥')
            expect(a.locator('#room-title')).to_have_text('family')
            expect(a.locator('#retry')).to_be_hidden()
            with lock:
                bindings[cookies[0]]='owner'
            a.locator('#authenticate').click()
            expect(a.locator('#identity-name')).to_have_text('앨리스')
            expect(a.locator('#retry')).to_be_visible()
            a.locator('#retry').click()
            expect(a.locator('#retry')).to_be_hidden()
            rows=[x for x in direct('owner','GET','/v1/rooms/family/messages')[1] if x['client_id']==pending['client_id']]
            assert len(rows)==1 and rows[0]['actor']=='alice'
            proof['upstream_actor_switch_cannot_rebind_pending_send'] = True

            # Revoke the account in actual durable policy, with a decoded image
            # still visible. Any signed denial conservatively clears the view.
            card(b,'signed.png').locator('.open-media').click()
            b.wait_for_function("()=>document.querySelector('.preview img')?.naturalWidth===2")
            commit(1,config['people'][:1])
            until=time.monotonic()+5
            while direct('family','GET','/v1/session')[0]!=401:
                assert time.monotonic()<until
                time.sleep(.05)
            b.locator('#refresh').click()
            expect(b.locator('#identity-name')).to_have_text('계정 확인 필요')
            assert b.locator('#rooms button').count()==0 and b.locator('#messages li').count()==0
            assert b.evaluate('window.liveBlobs.size')==0
            expect(b.locator('#send')).to_be_disabled()
            commit(2,config['people'])
            until=time.monotonic()+5
            while direct('family','GET','/v1/session')[0]!=200:
                assert time.monotonic()<until
                time.sleep(.05)
            b.locator('#authenticate').click()
            expect(b.locator('#identity-name')).to_have_text('밥')
            expect(b.locator('#room-title')).to_have_text('family')
            card(b,'signed.png').locator('.open-media').click()
            b.wait_for_function("()=>document.querySelector('.preview img')?.naturalWidth===2")
            with lock:
                expired.add(cookies[1])
            b.locator('#refresh').click()
            expect(b.locator('#identity-name')).to_have_text('계정 확인 필요')
            assert b.evaluate('window.liveBlobs.size')==0
            b.reload()
            expect(b.locator('#identity-name')).to_have_text('계정 확인 필요')
            expect(b.locator('#actor')).to_be_hidden()
            expect(b.locator('#send')).to_be_disabled()
            with lock:
                expired.clear()
            b.locator('#authenticate').click()
            expect(b.locator('#identity-name')).to_have_text('밥')
            expect(b.locator('#room-title')).to_have_text('family')
            proof['durable_revocation_and_expired_bootstrap_clear_blobs_without_fallback'] = True

            # Actual server SIGKILL/restart leaves upstream identity/port stable;
            # browsers reauthenticate on reload and recover stored history.
            stop();start()
            for page,name in ((a,'앨리스'),(b,'밥')):
                page.reload()
                expect(page.locator('#identity-name')).to_have_text(name)
                expect(page.locator('#messages')).to_contain_text('synthetic account switch pending')
                assert page.evaluate('JSON.stringify(sessionStorage)+JSON.stringify(localStorage)').find('eyJ')==-1
            b.set_viewport_size({'width':390,'height':844})
            assert b.evaluate('document.documentElement.scrollWidth<=window.innerWidth')
            a.screenshot(path=str(work/'signed-desktop.png'),full_page=True)
            b.screenshot(path=str(work/'signed-mobile.png'),full_page=True)
            assert not errors,errors
            # Browser API requests bind their established actor. /v1/session is
            # intentionally the only unbound bootstrap call in app code.
            with lock:
                assert any(r['actor']=='alice' and r['subject']=='family' for r in requests)
            proof['actual_restart_history_390px_no_js_tokens_or_page_errors'] = True
            proof['ok']=True
            browser.close()
    finally:
        if proxy:
            proxy.shutdown()
        stop()  # End every retained upstream stream before joining proxy workers.
        if proxy:
            proxy.server_close()
            thread.join(timeout=2)
            assert not thread.is_alive()
        (work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n')
    print(work/'verification.json')

if __name__=='__main__':
    os.umask(0o077)
    main()
