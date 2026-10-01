#!/usr/bin/env python3
"""실기기 수동 세션 키트(#177 M4, CI 밖·수동).

스모크가 프로그램으로 구동하는 동일한 durable 워커를 사람 손으로 구동할 수 있는
합성 세션 서버(/s/<토큰>/panel.html)와 최종 증거 JSON 검증기를 묶은 키트다.

- serve:    번들 + 패널을 LAN에 서빙(스모크와 동일한 엄격 헤더·CSP), 교환판·관찰 수집,
            종료 시 세션 스켈레톤을 archive/artifacts/ 아래 0700으로 저장.
- validate: 실기기 증거 JSON(#177 §4: 브라우저 3종 UA·백그라운드 복귀·저장소 축출
            rejoin 안내) 수용 기준 검사 — 하나라도 빠지면 실패(fail closed).
- selftest: 헤드리스 Chromium으로 패널 전체 흐름 리허설(생성→초대→참여→왕복→
            새로고침 이어하기→축출 재참여) + 검증기 단위 점검. 이 결과는
            실기기 증거가 아니다(headless 불인정, #177 §4).

합성 전용: 폐기 가능한 합성 키만 다룬다. 운영 server/ 코드 가져오기 없음(결정 E).
"""
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CSP = ("default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; "
       "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
KINDS = ('firefox', 'safari-ios', 'android-chrome')
WEB = Path(__file__).resolve().parents[2] / 'experiments' / 'openmls-browser' / 'web'
ARCHIVE = Path(__file__).resolve().parents[2]
ASSETS = ('/panel.html', '/panel.js', '/main.js', '/durable-worker.js', '/session-store.js',
          '/pkg/family_mls_browser_experiment.js', '/pkg/family_mls_browser_experiment_bg.wasm',
          '/pkg/custody.js')
TOKEN = re.compile(r'^/s/([0-9a-f]{8})(/|$)')
BOARD_MAX_ENTRIES, BOARD_MAX_BYTES, BODY_MAX = 32, 64 * 1024, 256 * 1024
LOG_MAX = 5000


def sha256_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def lan_ip():
    """발신 소켓 조회(패킷 없음). 실패하면 LAN 없이 로컬 전용."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(('10.255.255.255', 1))
        return probe.getsockname()[0]
    except OSError:
        return '127.0.0.1'
    finally:
        probe.close()


def load_assets(bundle):
    """스모크와 동일한 안전 규칙으로 정적 자산을 한 번 읽는다."""
    wanted = {route: (WEB / route.lstrip('/')) for route in ASSETS if not route.startswith('/pkg/')}
    for name in ['family_mls_browser_experiment.js', 'family_mls_browser_experiment_bg.wasm', 'custody.js']:
        wanted['/pkg/' + name] = Path(bundle) / name
    assets = {}
    for route, path in wanted.items():
        st = path.lstat()
        if not path.is_file() or path.is_symlink() or st.st_nlink != 1 or st.st_size > 32 * 1024 * 1024:
            raise RuntimeError(f'unsafe or oversized asset: {path}')
        assets[route] = path.read_bytes()
    return assets


class Session:
    """한 번의 serve 세션 상태: 교환판·기기 등록·관찰·요청 기록(전부 메모리)."""

    def __init__(self, assets, bundle):
        self.assets = assets
        self.bundle = {Path(route).name: sha256_file(Path(bundle) / Path(route).name)
                       for route in ASSETS if route.startswith('/pkg/')}
        self.token = secrets.token_hex(4)
        self.started = datetime.now(timezone.utc).isoformat(timespec='seconds')
        self.board, self.devices, self.observations, self.log = [], [], [], []

    def note(self, path, ua):
        if len(self.log) < LOG_MAX:
            self.log.append({'when': datetime.now(timezone.utc).isoformat(timespec='seconds'),
                             'path': path, 'ua': ua[:300]})

    def skeleton(self, lan_url):
        return {'synthetic_only': True, 'real_device_evidence': False,
                'session': {'started': self.started, 'lan_url': lan_url, 'bundle': self.bundle,
                            'requests': len(self.log), 'log': list(self.log)},
                'devices': list(self.devices), 'observations': list(self.observations)}


def make_handler(session, allowed_hosts):
    types = {'/panel.html': 'text/html; charset=utf-8', '/panel.js': 'text/javascript; charset=utf-8',
             '/main.js': 'text/javascript; charset=utf-8', '/durable-worker.js': 'text/javascript; charset=utf-8',
             '/session-store.js': 'text/javascript; charset=utf-8'}

    def _ctype(route):
        path = '/' + route
        if path in types:
            return types[path]
        if path.endswith('.js'):
            return 'text/javascript; charset=utf-8'
        if path.endswith('.wasm'):
            return 'application/wasm'
        return 'application/octet-stream'

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def _deny(self, code=404):
            self.send_response(code)
            self.send_header('Content-Length', '0')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', CSP)
            self.end_headers()
            return True

        def _guard(self):
            """토큰 경로·Host·Origin 검사. (거부됨, 토큰 뒤 경로)를 돌려준다."""
            origin = 'http://' + self.headers.get('Host', '')
            if self.headers.get('Host') not in allowed_hosts:
                return self._deny(), None
            if self.headers.get('Origin') not in (None, origin):
                return self._deny(), None
            match = TOKEN.match(self.path)
            if not match or match.group(1) != session.token:
                return self._deny(), None
            return None, self.path[match.end(1):].lstrip('/')

        def do_GET(self):
            session.note(self.path, self.headers.get('User-Agent', ''))
            denied, route = self._guard()
            if denied:
                return
            body = None
            ctype = 'application/json'
            if route.startswith('board/'):
                item = next((e for e in session.board if e['id'] == route[6:]), None)
                if item:
                    body = item
            elif route == 'board':
                body = [{'id': e['id'], 'label': e['label'], 'len': e['len'], 'when': e['when']}
                        for e in session.board]
            elif route == 'devices':
                body = session.devices
            elif route == 'evidence.json':
                body = session.skeleton('http://' + allowed_hosts[0] + f'/s/{session.token}/panel.html')
            elif ('/' + route) in session.assets:
                body = session.assets['/' + route]
                ctype = _ctype(route)
            if body is None:
                return self._deny()
            raw = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', CSP)
            self.end_headers()
            self.wfile.write(raw)

        def do_POST(self):
            session.note(self.path, self.headers.get('User-Agent', ''))
            denied, route = self._guard()
            if denied:
                return
            length = int(self.headers.get('Content-Length') or 0)
            if length <= 0 or length > BODY_MAX:
                return self._deny(413)
            try:
                payload = json.loads(self.rfile.read(length))
            except (ValueError, UnicodeDecodeError):
                return self._deny(400)
            if route == 'board':
                if not isinstance(payload, dict) or not isinstance(payload.get('label'), str) \
                        or not isinstance(payload.get('b64'), str) or len(payload['label']) > 80:
                    return self._deny(400)
                try:
                    raw = base64.b64decode(payload['b64'], validate=True)
                except (binascii.Error, ValueError):
                    return self._deny(400)
                if len(raw) > BOARD_MAX_BYTES or len(session.board) >= BOARD_MAX_ENTRIES:
                    return self._deny(len(raw) > BOARD_MAX_BYTES and 413 or 409)
                entry = {'id': secrets.token_hex(6), 'label': payload['label'], 'len': len(raw),
                         'when': datetime.now(timezone.utc).isoformat(timespec='seconds'), 'b64': payload['b64']}
                session.board.append(entry)
                return self._json(entry)
            if route == 'devices':
                if not isinstance(payload, dict) or payload.get('kind') not in KINDS \
                        or not isinstance(payload.get('ua'), str) or not payload['ua'] or len(payload['ua']) > 512:
                    return self._deny(400)
                payload['when'] = datetime.now(timezone.utc).isoformat(timespec='seconds')
                payload['request_ua'] = (self.headers.get('User-Agent', '') or '')[:300]
                session.devices[:] = [d for d in session.devices if d['kind'] != payload['kind']]
                session.devices.append(payload)
                return self._json({'kind': payload['kind']})
            if route == 'observations':
                if not isinstance(payload, dict) or len(json.dumps(payload)) > 8192:
                    return self._deny(400)
                payload['when'] = datetime.now(timezone.utc).isoformat(timespec='seconds')
                session.observations.append(payload)
                return self._json({'saved': True})
            return self._deny()

        def _json(self, body):
            raw = json.dumps(body).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', CSP)
            self.end_headers()
            self.wfile.write(raw)

    return Handler


def start_server(bundle, port=0, bind='0.0.0.0'):
    assets = load_assets(bundle)
    session = Session(assets, bundle)
    ip = lan_ip()
    # 포트는 바인드 후 확정된다 — 핸들러 클래스는 요청 시 읽히므로 그때 정확한
    # Host 허용 목록으로 교체한다(단 한 번 바인드한다).
    server = ThreadingHTTPServer((bind, port), make_handler(session, ['placeholder.invalid']))
    real_port = server.server_address[1]
    allowed = [f'{ip}:{real_port}', f'localhost:{real_port}', f'127.0.0.1:{real_port}']
    server.RequestHandlerClass = make_handler(session, allowed)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    urls = [f'http://{host}/s/{session.token}/panel.html' for host in allowed]
    return server, session, urls


def save_skeleton(session, lan_url):
    root = ARCHIVE / 'artifacts'
    root.mkdir(mode=0o700, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='real-device-', dir=root))
    os.chmod(out, 0o700)
    path = out / 'session-skeleton.json'
    path.write_text(json.dumps(session.skeleton(lan_url), ensure_ascii=False, indent=1))
    os.chmod(path, 0o600)
    return path


# ---------------------------------------------------------------- 검증기(§4 수용 기준)

def ua_ok(kind, ua):
    ua = ua or ''
    if 'Headless' in ua or not ua:
        return False
    if kind == 'firefox':
        return 'Firefox/' in ua and 'Focus' not in ua
    if kind == 'safari-ios':
        return ('iPhone' in ua or 'iPad' in ua) and 'Safari/' in ua and 'Chrome' not in ua
    if kind == 'android-chrome':
        return 'Android' in ua and 'Chrome/' in ua
    return False


def problems(evidence):
    """§4 수용 기준 위반 목록. 빈 목록이면 통과."""
    bad = []
    if evidence.get('schema') != 'real-device-evidence:v1':
        bad.append('schema != real-device-evidence:v1')
    if evidence.get('synthetic_only') is not True or evidence.get('ci') is not False:
        bad.append('synthetic_only=true·ci=false 필요')
    if not re.fullmatch(r'[0-9a-f]{7,40}', str(evidence.get('kit_git_sha', ''))):
        bad.append('kit_git_sha 없음')
    if not str(evidence.get('operated_by', '')).strip():
        bad.append('operated_by 없음')
    dates = evidence.get('dates')
    if not isinstance(dates, list) or not dates or not all(
            isinstance(d, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}', d) for d in dates):
        bad.append('dates(YYYY-MM-DD) 없음')
    if not re.fullmatch(r'[0-9a-f]{64}', str(evidence.get('session_log_sha256', ''))):
        bad.append('session_log_sha256 없음')
    if not isinstance(evidence.get('session'), dict) or not evidence['session'].get('lan_url'):
        bad.append('세션 스켈레톤(session) 없음')
    devices = evidence.get('devices')
    if not isinstance(devices, list) or {d.get('kind') for d in devices} != set(KINDS) or len(devices) != 3:
        bad.append(f'기기 3종({", ".join(KINDS)}) 정확히 필요')
    else:
        for device in devices:
            kind = device['kind']
            if not ua_ok(kind, device.get('ua')):
                bad.append(f'{kind}: UA가 종류와 맞지 않거나 headless')
            checks = device.get('checks')
            if not isinstance(checks, dict):
                bad.append(f'{kind}: checks 없음')
                continue
            for name in ['init', 'fingerprint_out_of_band', 'invite_join', 'encrypt_decrypt_roundtrip']:
                if checks.get(name) is not True:
                    bad.append(f'{kind}: {name} 미통과')
            bg = checks.get('background_return')
            if not isinstance(bg, dict) or bg.get('performed') is not True \
                    or not isinstance(bg.get('away_seconds'), int) or bg['away_seconds'] < 20 \
                    or bg.get('decrypted_after_return') is not True:
                bad.append(f'{kind}: 백그라운드 복귀 기록 부족(≥20초 이탈·복귀 후 해독)')
            eviction = checks.get('storage_eviction')
            if not isinstance(eviction, dict) or not isinstance(eviction.get('tested'), bool) \
                    or not isinstance(eviction.get('rejoined'), bool):
                bad.append(f'{kind}: 저장소 축출 기록(tested·rejoined) 없음')
            guidance = checks.get('rejoin_guidance')
            if not isinstance(guidance, str) or len(guidance) < 60 or '재참여' not in guidance:
                bad.append(f'{kind}: 저장소 축출 시 rejoin 안내(60자 이상, 재참여) 없음')
    return bad


# ---------------------------------------------------------------- selftest(헤드리스 리허설 — 실기기 증거 아님)

def selftest(bundle):
    import urllib.request

    def http(url, method='GET', body=None):
        request = urllib.request.Request(url, method=method, data=body)
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read())

    from playwright.sync_api import sync_playwright

    server, session, urls = start_server(bundle, 0, '127.0.0.1')
    entry = urls[2]  # http://127.0.0.1:<port>/s/<token>/panel.html
    base = entry.rsplit('/', 1)[0]
    receipt = {'real_device_evidence': False, 'headless_rehearsal': True, 'phases': {}}
    passphrase = secrets.token_urlsafe(24)
    dbs = [f'family-mls-synthetic-selftest-{secrets.token_hex(4)}' for _ in range(2)]
    dialogs = []
    js_sha = None
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        contexts = [browser.new_context() for _ in range(2)]
        pages = [context.new_page() for context in contexts]
        for page in pages:
            page.on('dialog', lambda dialog: (dialogs.append(dialog.type), dialog.accept()))

        def start(page, identity, db):
            page.goto(entry)
            page.wait_for_function('() => window.ready === true')
            page.fill('#identity', identity)
            page.fill('#database', db)
            page.fill('#passphrase', passphrase)
            page.click('#start')
            page.wait_for_function("() => /지문 [0-9a-f]{4}/.test(document.getElementById('state').textContent)",
                                   timeout=90000)
            return re.search(r'지문 ([0-9a-f ]+)', page.text_content('#state')).group(1)

        def pick_and_fetch(page, label_prefix):
            """교환판에서 해당 라벨의 가장 최신 항목을 가져온다(슬롯 표시 대기)."""
            page.click('#board-refresh')
            page.wait_for_function("() => document.querySelectorAll('input[name=board-item]').length > 0")
            entries = http(base + '/board')
            wanted = next(e for e in reversed(entries) if e['label'].startswith(label_prefix))
            page.check(f'input[name="board-item"][value="{wanted["id"]}"]')
            page.click('#fetch-item')
            page.wait_for_function(
                "len => document.getElementById('slots').textContent.includes(len + 'B')",
                arg=wanted['len'])

        def post_and_wait(page, button, done_text):
            """게시 버튼을 누르고 패널 로그에 완료 문구가 새로 찍힐 때까지 기다린다(POST 동기화)."""
            before = page.text_content('#log') or ''
            page.click(button)
            page.wait_for_function(
                "([text, prev]) => { const s = document.getElementById('log').textContent;"
                " return s.length > prev.length && s.includes(text); }",
                arg=[done_text, before])

        alice, bob = pages
        # 0) 표시용 SHA-256 차등 검증(해시lib 대조)
        alice.goto(entry)
        alice.wait_for_function('() => window.ready === true')
        js_sha = alice.evaluate("s => window.__panel.sha256(new TextEncoder().encode(s))", 'abc')
        assert js_sha == hashlib.sha256(b'abc').hexdigest(), js_sha
        receipt['phases']['sha256_differential'] = True

        # 1) 등록·시작·생성·키 패키지·초대·참여·양방향 왕복
        alice.select_option('#kind', 'firefox')
        alice.click('#register')
        alice.wait_for_function("() => document.getElementById('reg-out').textContent.length > 0")
        bob.goto(entry)
        bob.wait_for_function('() => window.ready === true')
        bob.select_option('#kind', 'android-chrome')
        bob.click('#register')
        fa = start(alice, 'owner', dbs[0])
        fb = start(bob, 'partner', dbs[1])
        assert fa != fb and re.fullmatch(r'[0-9a-f]{4}([ ][0-9a-f]{4}){15}', fa), (fa, fb)
        post_and_wait(alice, '#create', '그룹 생성 완료')
        post_and_wait(bob, '#keypackage', '키 패키지 게시 완료')
        pick_and_fetch(alice, 'keypackage:partner')
        post_and_wait(alice, '#invite', '초대 완료')
        pick_and_fetch(bob, 'welcome:owner')
        post_and_wait(bob, '#join', '참여 완료')
        alice.fill('#msg', '첫 실기기 합성 인사')
        post_and_wait(alice, '#encrypt', '암호문 게시 완료')
        pick_and_fetch(bob, 'ciphertext:owner')
        bob.click('#decrypt')
        bob.wait_for_function("() => document.getElementById('mail').textContent.includes('첫 실기기 합성 인사')")
        bob.fill('#msg', '반대 방향 답신')
        post_and_wait(bob, '#encrypt', '암호문 게시 완료')
        pick_and_fetch(alice, 'ciphertext:partner')
        alice.click('#decrypt')
        alice.wait_for_function("() => document.getElementById('mail').textContent.includes('반대 방향 답신')")
        receipt['phases']['roundtrip_both_directions'] = True
        receipt['fingerprints'] = {'owner': fa, 'partner': fb}

        # 2) 새로고침(탭 재시작) 후 IndexedDB 이어하기 → 다음 메시지 해독
        bob.reload()
        bob.wait_for_function('() => window.ready === true')
        assert bob.input_value('#database') == dbs[1], 'localStorage 미리채움 실패'
        bob.fill('#passphrase', passphrase)
        bob.click('#start')
        bob.wait_for_function("() => /지문/.test(document.getElementById('state').textContent)", timeout=90000)
        assert fb == re.search(r'지문 ([0-9a-f ]+)', bob.text_content('#state')).group(1), '재시작 지문 변경'
        alice.fill('#msg', '이어하기 후 메시지')
        post_and_wait(alice, '#encrypt', '암호문 게시 완료')
        pick_and_fetch(bob, 'ciphertext:owner')
        bob.click('#decrypt')
        bob.wait_for_function("() => document.getElementById('mail').textContent.includes('이어하기 후 메시지')")
        receipt['phases']['reload_resume_indexeddb'] = True

        # 3) 저장소 축출 → 재참여(새 지문 · 재초대)
        bob.click('#evict')  # confirm 대화는 자동 수락
        bob.wait_for_function("() => document.getElementById('state').textContent.includes('저장소 삭제 완료')")
        fb2 = start(bob, 'partner', dbs[1])
        assert fb2 != fb, '축출 후 지문이 그대로다'
        post_and_wait(bob, '#keypackage', '키 패키지 게시 완료')
        pick_and_fetch(alice, 'keypackage:partner')
        post_and_wait(alice, '#invite', '초대 완료')
        pick_and_fetch(bob, 'welcome:owner')
        post_and_wait(bob, '#join', '참여 완료')
        alice.fill('#msg', '재참여 후 메시지')
        post_and_wait(alice, '#encrypt', '암호문 게시 완료')
        pick_and_fetch(bob, 'ciphertext:owner')
        bob.click('#decrypt')
        bob.wait_for_function("() => document.getElementById('mail').textContent.includes('재참여 후 메시지')")
        receipt['phases']['eviction_rejoin'] = True
        receipt['fingerprints']['partner_after_eviction'] = fb2

        # 4) 관찰 전송 + 스켈레톤
        for page, kind in [(alice, 'firefox'), (bob, 'android-chrome')]:
            page.select_option('#kind', kind)
            page.fill('#bg-seconds', '30')
            page.check('#bg-ok')
            page.click('#observe')
            page.wait_for_function("() => document.getElementById('observe-out').textContent.length > 0")
        assert 'alert' not in dialogs, dialogs
        for page in (alice, bob):
            assert '실패:' not in (page.text_content('#log') or ''), '패널 로그에 실패 기록'
        skeleton = http(base + '/evidence.json')
        assert len(skeleton['devices']) == 2 and skeleton['session']['requests'] > 10, skeleton['session']['requests']
        assert skeleton['session']['bundle']['family_mls_browser_experiment_bg.wasm']
        receipt['phases']['skeleton_devices_observations'] = True
        receipt['bundle'] = skeleton['session']['bundle']
        contexts[0].close()
        browser.close()
    server.shutdown()

    # 5) 검증기 단위 점검: 통과 케이스 1개 + 위반 3개
    valid = {'schema': 'real-device-evidence:v1', 'synthetic_only': True, 'ci': False,
             'kit_git_sha': '0' * 40, 'operated_by': 'tester', 'dates': ['2026-10-01'],
             'session_log_sha256': '0' * 64, 'session': {'lan_url': 'http://lan/s/x/panel.html'},
             'devices': [{'kind': kind, 'ua': ua, 'platform': 'p',
                          'checks': {'init': True, 'fingerprint_out_of_band': True, 'invite_join': True,
                                     'encrypt_decrypt_roundtrip': True,
                                     'background_return': {'performed': True, 'away_seconds': 30,
                                                           'decrypted_after_return': True},
                                     'storage_eviction': {'tested': False, 'rejoined': False},
                                     'rejoin_guidance': '저장소가 축출되면 이 기기의 신원과 세션 상태는 소멸되어 되돌릴 수 없다. '
                                                        '같은 신원으로 다시 시작해도 새 지문의 새 기기가 되므로, 반대 기기가 새 키 패키지로 '
                                                        '재초대해야 재참여할 수 있고 과거 메시지는 읽을 수 없다.'}}
                         for kind, ua in [
                             ('firefox', 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0'),
                             ('safari-ios', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'),
                             ('android-chrome', 'Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36')]]}
    assert problems(valid) == [], problems(valid)
    broken = dict(valid)
    broken['devices'] = [dict(valid['devices'][0])]
    assert problems(broken)  # 기기 부족
    headless = json.loads(json.dumps(valid))
    headless['devices'][0]['ua'] = 'HeadlessChrome/140.0.0.0'
    headless['devices'][0]['kind'] = 'android-chrome'
    headless['devices'][1]['kind'] = 'safari-ios'
    headless['devices'][2]['kind'] = 'firefox'
    assert any('headless' in p for p in problems(headless))
    norejoin = json.loads(json.dumps(valid))
    norejoin['devices'][0]['checks']['rejoin_guidance'] = '짧다'
    assert any('rejoin 안내' in p for p in problems(norejoin))
    receipt['phases']['validator_units'] = True

    root = ARCHIVE / 'artifacts'
    root.mkdir(mode=0o700, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='real-device-selftest-', dir=root))
    os.chmod(out, 0o700)
    (out / 'rehearsal-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=1))
    print(json.dumps(receipt, ensure_ascii=False, indent=1))
    print(out / 'rehearsal-receipt.json')


# ---------------------------------------------------------------- 진입

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest='command', required=True)
    default_bundle = ARCHIVE.parent / 'artifacts' / 'mls-pkg'
    for name, help_text in [('serve', 'LAN 세션 서버'), ('validate', '증거 JSON 검사'), ('selftest', '헤드리스 리허설')]:
        sub = command.add_parser(name, help=help_text)
        sub.add_argument('--bundle', type=Path, default=default_bundle)
        if name == 'serve':
            sub.add_argument('--port', type=int, default=8765)
    command.choices['validate'].add_argument('evidence', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == 'serve':
        server, session, urls = start_server(args.bundle.resolve(strict=True), args.port)
        print('세션(합성 전용·폐기 가능). 각 실기기 브라우저에서 아래 URL을 연다:')
        for url in urls:
            print(' ', url)
        print('Ctrl-C로 종료 — 세션 스켈레톤을 archive/artifacts/ 아래 저장한다.')
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.shutdown()
            print('skeleton:', save_skeleton(session, urls[0]))
    elif args.command == 'validate':
        evidence = json.loads(args.evidence.read_text())
        bad = problems(evidence)
        for line in bad:
            print('위반:', line, file=sys.stderr)
        raise SystemExit(1 if bad else 0)
    else:
        selftest(args.bundle.resolve(strict=True))


if __name__ == '__main__':
    main()
