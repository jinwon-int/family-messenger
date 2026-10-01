#!/usr/bin/env python3
"""실기기 수동 세션 키트(#177 M4, CI 밖·수동).

스모크가 프로그램으로 구동하는 동일한 durable 워커를 사람 손으로 구동할 수 있는
합성 세션 서버(/s/<토큰>/panel.html)와 최종 증거 JSON 검증기를 묶은 키트다.

- serve:    번들 + 패널을 LAN에 서빙(스모크와 동일한 엄격 헤더·CSP), 교환판·관찰 수집,
            종료 시 세션 스켈레톤을 archive/artifacts/ 아래 0700으로 저장.
- validate: 실기기 증거 JSON(#177 §4: 브라우저 3종 UA·백그라운드 복귀·저장소 축출
            rejoin 안내) 수용 기준 검사 — 서버가 저장한 세션 스켈레톤(--skeleton, 필수)과
            대조한다. 하나라도 빠지면 실패(fail closed).
- validate-selftest: 번들·Playwright 없이 검증기와 서버 등록 경로만 점검(CI·로컬용).
- selftest: 헤드리스 Chromium으로 패널 전체 흐름 리허설(생성→초대→참여→왕복→
            새로고침 이어하기→축출 재참여) + validate-selftest. 이 결과는
            실기기 증거가 아니다(headless 불인정, #177 §4).

검증기가 증명하는 것: 증거가 이 서버가 관측·저장한 스켈레톤(파일 sha256·session 원문·
등록 시 서버 관측 UA·클라이언트 힌트·관찰 기록)과 일치하고, 키트 커밋이 저장소 HEAD의
조상이라는 것. 증명하지 않는 것: 기기가 실제 물리 기기였는지(headless 배제는 UA 휴리스틱 +
운영자 서명 진술에 의존한다 — REAL-DEVICE.md 참조).

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
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
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
TOKEN = re.compile(r'^/s/([0-9a-f]{32})(/|$)')
BOARD_MAX_ENTRIES, BOARD_MAX_BYTES, BODY_MAX = 32, 64 * 1024, 256 * 1024
LOG_MAX = 5000
UA_MAX, PATH_MAX, HINT_MAX = 512, 200, 200
# 등록 시 서버가 관측해 스켈레톤에 남기는 UA 클라이언트 힌트(없으면 null로 기록).
CLIENT_HINTS = {'sec_ch_ua': 'Sec-CH-UA', 'sec_ch_ua_platform': 'Sec-CH-UA-Platform',
                'sec_ch_ua_mobile': 'Sec-CH-UA-Mobile'}
BG_MIN_SECONDS = 20
REQUIRED_CHECKS = ('init', 'fingerprint_out_of_band', 'invite_join', 'encrypt_decrypt_roundtrip')


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


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


def bundle_hashes(bundle):
    return {Path(route).name: sha256_file(Path(bundle) / Path(route).name)
            for route in ASSETS if route.startswith('/pkg/')}


class Session:
    """한 번의 serve 세션 상태: 교환판·기기 등록·관찰·요청 기록(전부 메모리)."""

    def __init__(self, assets, hashes):
        self.assets = assets
        self.bundle = hashes
        self.token = secrets.token_hex(16)
        self.started = datetime.now(timezone.utc).isoformat(timespec='seconds')
        self.board, self.devices, self.observations, self.log = [], [], [], []

    def note(self, path, ua):
        """토큰 검사를 통과한 요청만 기록한다. 경로는 /s/<토큰> 접두사를 뗀 형태."""
        if len(self.log) < LOG_MAX:
            self.log.append({'when': datetime.now(timezone.utc).isoformat(timespec='seconds'),
                             'path': path[:PATH_MAX], 'ua': ua[:300]})

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
            denied, route = self._guard()
            if denied:
                return
            session.note('/' + route, self.headers.get('User-Agent', ''))
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
            denied, route = self._guard()
            if denied:
                return
            session.note('/' + route, self.headers.get('User-Agent', ''))
            try:
                length = int(self.headers.get('Content-Length') or 0)
            except ValueError:
                return self._deny(400)
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
                        or not isinstance(payload.get('ua'), str) or not payload['ua'] or len(payload['ua']) > UA_MAX:
                    return self._deny(400)
                payload['when'] = datetime.now(timezone.utc).isoformat(timespec='seconds')
                # 서버 관측값: 클라이언트가 보낸 ua와 별도로 요청 헤더에서 직접 읽는다.
                # 검증기는 증거의 ua를 이 request_ua와 대조한다(클라이언트 자기신고 불인정).
                payload['request_ua'] = (self.headers.get('User-Agent') or '')[:UA_MAX]
                for key, header in CLIENT_HINTS.items():
                    value = self.headers.get(header)
                    payload['request_' + key] = None if value is None else value[:HINT_MAX]
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


def serve_session(session, port=0, bind='0.0.0.0'):
    """세션을 바인드하고 (server, urls)를 돌려준다. urls[0]이 스켈레톤의 lan_url이 된다."""
    primary = lan_ip() if bind in ('', '0.0.0.0') else bind
    # 포트는 바인드 후 확정된다 — 핸들러 클래스는 요청 시 읽히므로 그때 정확한
    # Host 허용 목록으로 교체한다(단 한 번 바인드한다).
    server = ThreadingHTTPServer((bind, port), make_handler(session, ['placeholder.invalid']))
    real_port = server.server_address[1]
    allowed = list(dict.fromkeys(f'{host}:{real_port}' for host in (primary, 'localhost', '127.0.0.1')))
    server.RequestHandlerClass = make_handler(session, allowed)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    urls = [f'http://{host}/s/{session.token}/panel.html' for host in allowed]
    return server, urls


def start_server(bundle, port=0, bind='0.0.0.0'):
    session = Session(load_assets(bundle), bundle_hashes(bundle))
    server, urls = serve_session(session, port, bind)
    return server, session, urls


def save_skeleton(session, lan_url, root=None):
    root = Path(root) if root else ARCHIVE / 'artifacts'
    root.mkdir(mode=0o700, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='real-device-', dir=root))
    os.chmod(out, 0o700)
    path = out / 'session-skeleton.json'
    path.write_text(json.dumps(session.skeleton(lan_url), ensure_ascii=False, indent=1))
    os.chmod(path, 0o600)
    return path


# ---------------------------------------------------------------- 검증기(§4 수용 기준)

def ua_problem(kind, ua, registration, allow_ipad_desktop_ua=False):
    """UA 문자열 휴리스틱. 위반 사유 문자열 또는 None.

    증명이 아니다: 'Headless' 부재는 headless가 아니라는 증거가 못 되며(UA는 위조 가능),
    headless 배제는 운영자 서명 진술이 담당한다(REAL-DEVICE.md). 여기서는 명백한
    불일치만 거른다.
    """
    ua = ua or ''
    if not ua:
        return 'UA 없음'
    if 'Headless' in ua:
        return "UA에 'Headless' 포함(휴리스틱)"
    if kind == 'firefox':
        ok = 'Firefox/' in ua and 'Focus' not in ua
    elif kind == 'safari-ios':
        ok = ('iPhone' in ua or 'iPad' in ua) and 'Safari/' in ua and 'Chrome' not in ua
        if not ok and 'Macintosh' in ua and 'Safari/' in ua and 'Chrome' not in ua:
            # iPadOS 13+는 데스크톱급 UA(Macintosh)를 보낸다. 구분 신호인 navigator.maxTouchPoints는
            # 패널 등록 본문에 없어 서버가 알 수 없다(panel.js 범위 밖, #177 후속). 따라서
            # platform=MacIntel + 클라이언트 힌트 부재(=Chromium 아님) + 운영자 명시 플래그일 때만 수용.
            if registration.get('platform') != 'MacIntel':
                return f"Macintosh UA인데 platform={registration.get('platform')!r} (MacIntel 필요)"
            if registration.get('request_sec_ch_ua_mobile') is not None:
                return 'Macintosh UA에 Sec-CH-UA-Mobile 헤더 존재(Chromium 계열) — iPad 데스크톱 UA 불인정'
            if not allow_ipad_desktop_ua:
                return 'iPad 데스크톱급 UA(Macintosh)는 --allow-ipad-desktop-ua 와 운영자 진술이 있어야 수용'
            ok = True
    elif kind == 'android-chrome':
        ok = 'Android' in ua and 'Chrome/' in ua
    else:
        ok = False
    return None if ok else f'UA가 종류({kind})와 맞지 않는다'


def hint_problems(kind, registration):
    """등록 시 서버가 관측한 UA 클라이언트 힌트와 종류의 정합성(헤더가 있을 때만 비교)."""
    bad = []
    brands = registration.get('request_sec_ch_ua')
    platform = registration.get('request_sec_ch_ua_platform')
    mobile = registration.get('request_sec_ch_ua_mobile')
    if kind == 'android-chrome':
        if mobile is not None and mobile.strip() != '?1':
            bad.append(f'{kind}: Sec-CH-UA-Mobile={mobile!r} (?1 필요)')
        if platform is not None and 'Android' not in platform:
            bad.append(f'{kind}: Sec-CH-UA-Platform={platform!r} (Android 필요)')
        if brands is not None and 'Chrom' not in brands:
            bad.append(f'{kind}: Sec-CH-UA={brands!r} (Chromium 브랜드 없음)')
    else:
        # Firefox·Safari는 UA 클라이언트 힌트를 보내지 않는다 — 있으면 Chromium 계열 등록이다.
        for key, header in CLIENT_HINTS.items():
            if registration.get('request_' + key) is not None:
                bad.append(f'{kind}: {header} 헤더 존재 — Chromium 계열 등록')
    return bad


def detect_repo():
    git = shutil.which('git')
    if not git:
        return None
    result = subprocess.run([git, '-C', str(Path(__file__).resolve().parent), 'rev-parse', '--show-toplevel'],
                            capture_output=True, text=True)
    return Path(result.stdout.strip()) if result.returncode == 0 and result.stdout.strip() else None


def ancestor_problem(sha, repo=None):
    """kit_git_sha가 repo HEAD의 조상인지 git으로 확인. 위반 사유 또는 None."""
    if repo is None:
        repo = detect_repo()
        if repo is None:
            return 'git 저장소를 찾지 못했다 — --repo 로 키트 저장소를 지정'
    git = shutil.which('git')
    if not git:
        return 'git 실행 파일 없음'
    result = subprocess.run([git, '-C', str(repo), 'merge-base', '--is-ancestor', sha, 'HEAD'],
                            capture_output=True, text=True)
    if result.returncode == 0:
        return None
    if result.returncode == 1:
        return f'{sha[:12]} 은 {repo} HEAD의 조상이 아니다'
    return f'git merge-base 실패(rc={result.returncode}): {result.stderr.strip()[:200]}'


def _background_ok(bg):
    return isinstance(bg, dict) and bg.get('performed') is True \
        and isinstance(bg.get('away_seconds'), int) and not isinstance(bg.get('away_seconds'), bool) \
        and bg['away_seconds'] >= BG_MIN_SECONDS and bg.get('decrypted_after_return') is True


def _observation_matches(observation, kind, away_seconds):
    seconds = observation.get('bg_seconds')
    return observation.get('kind') == kind and isinstance(seconds, (int, float)) \
        and not isinstance(seconds, bool) and seconds >= BG_MIN_SECONDS \
        and observation.get('bg_decrypted') is True and seconds == away_seconds


def problems(evidence, skeleton, skeleton_sha256, repo=None, allow_ipad_desktop_ua=False):
    """§4 수용 기준 위반 목록. 빈 목록이면 통과. 스켈레톤(서버 저장본) 대조가 필수다."""
    bad = []
    if evidence.get('schema') != 'real-device-evidence:v1':
        bad.append('schema != real-device-evidence:v1')
    if evidence.get('synthetic_only') is not True or evidence.get('ci') is not False:
        bad.append('synthetic_only=true·ci=false 필요')
    sha = str(evidence.get('kit_git_sha', ''))
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        bad.append('kit_git_sha: 40헥스 전체 커밋 SHA 필요')
    else:
        err = ancestor_problem(sha, repo)
        if err:
            bad.append('kit_git_sha: ' + err)
    if not str(evidence.get('operated_by', '')).strip():
        bad.append('operated_by 없음')
    dates = evidence.get('dates')
    if not isinstance(dates, list) or not dates or not all(
            isinstance(d, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}', d) for d in dates):
        bad.append('dates(YYYY-MM-DD) 없음')
    if evidence.get('session_log_sha256') != skeleton_sha256:
        bad.append(f'session_log_sha256가 스켈레톤 파일 sha256({skeleton_sha256[:12]}…)과 다르다')
    if skeleton.get('synthetic_only') is not True or skeleton.get('real_device_evidence') is not False:
        bad.append('스켈레톤 표식 이상(synthetic_only=true·real_device_evidence=false 필요)')
    skeleton_session = skeleton.get('session')
    if not isinstance(skeleton_session, dict) or not skeleton_session.get('lan_url') \
            or not isinstance(skeleton_session.get('bundle'), dict) \
            or not skeleton_session['bundle'].get('family_mls_browser_experiment_bg.wasm'):
        bad.append('스켈레톤 session(lan_url·bundle) 없음')
    elif skeleton_session.get('requests') != len(skeleton_session.get('log') or []):
        bad.append('스켈레톤 session.requests가 log 길이와 다르다')
    elif evidence.get('session') != skeleton_session:
        bad.append('evidence.session이 스켈레톤 session과 다르다(원문 그대로 복사해야 한다)')
    registrations = {d.get('kind'): d for d in skeleton.get('devices') or [] if isinstance(d, dict)}
    observations = [o for o in skeleton.get('observations') or [] if isinstance(o, dict)]
    devices = evidence.get('devices')
    if not isinstance(devices, list) or not all(isinstance(d, dict) for d in devices) \
            or {d.get('kind') for d in devices} != set(KINDS) or len(devices) != 3:
        bad.append(f'기기 3종({", ".join(KINDS)}) 정확히 필요')
        return bad
    for device in devices:
        kind = device['kind']
        registration = registrations.get(kind)
        if registration is None:
            bad.append(f'{kind}: 스켈레톤에 등록 기록 없음')
            continue
        observed = registration.get('request_ua')
        if not isinstance(device.get('ua'), str) or device['ua'] != observed:
            bad.append(f'{kind}: ua가 스켈레톤의 서버 관측 request_ua와 다르다')
        if registration.get('ua') != observed:
            bad.append(f'{kind}: 등록 시 클라이언트 ua와 서버 관측 request_ua 불일치')
        if 'platform' in device and device['platform'] != registration.get('platform'):
            bad.append(f'{kind}: platform이 등록 기록과 다르다')
        reason = ua_problem(kind, observed, registration, allow_ipad_desktop_ua)
        if reason:
            bad.append(f'{kind}: {reason}')
        bad.extend(hint_problems(kind, registration))
        checks = device.get('checks')
        if not isinstance(checks, dict):
            bad.append(f'{kind}: checks 없음')
            continue
        for name in REQUIRED_CHECKS:
            if checks.get(name) is not True:
                bad.append(f'{kind}: {name} 미통과')
        bg = checks.get('background_return')
        if not _background_ok(bg):
            bad.append(f'{kind}: 백그라운드 복귀 기록 부족(≥{BG_MIN_SECONDS}초 이탈·복귀 후 해독)')
        elif not any(_observation_matches(o, kind, bg['away_seconds']) for o in observations):
            bad.append(f'{kind}: 스켈레톤 observations에 일치하는 관찰 없음'
                       f'(kind={kind}·bg_seconds={bg["away_seconds"]}≥{BG_MIN_SECONDS}·bg_decrypted=true)')
        eviction = checks.get('storage_eviction')
        if not isinstance(eviction, dict) or not isinstance(eviction.get('tested'), bool) \
                or not isinstance(eviction.get('rejoined'), bool):
            bad.append(f'{kind}: 저장소 축출 기록(tested·rejoined) 없음')
        guidance = checks.get('rejoin_guidance')
        if not isinstance(guidance, str) or len(guidance) < 60 or '재참여' not in guidance:
            bad.append(f'{kind}: 저장소 축출 시 rejoin 안내(60자 이상, 재참여) 없음')
    return bad


def validate_files(evidence_path, skeleton_path, repo=None, allow_ipad_desktop_ua=False):
    evidence = json.loads(Path(evidence_path).read_text())
    skeleton = json.loads(Path(skeleton_path).read_text())
    return problems(evidence, skeleton, sha256_file(skeleton_path), repo, allow_ipad_desktop_ua)


# ---------------------------------------------------------------- validate-selftest(번들·Playwright 불필요)

REJOIN_GUIDANCE = ('저장소가 축출되면 이 기기의 신원과 세션 상태는 소멸되어 되돌릴 수 없다. '
                   '같은 신원으로 다시 시작해도 새 지문의 새 기기가 되므로, 반대 기기가 새 키 패키지로 '
                   '재초대해야 재참여할 수 있고 과거 메시지는 읽을 수 없다.')
FIXTURE_UA = {
    'firefox': 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0',
    'safari-ios': ('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
                   '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'),
    'android-chrome': ('Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/140.0.0.0 Mobile Safari/537.36'),
}
FIXTURE_PLATFORM = {'firefox': 'Linux x86_64', 'safari-ios': 'iPhone', 'android-chrome': 'Linux armv81'}
FIXTURE_HINTS = {'android-chrome': {'Sec-CH-UA': '"Google Chrome";v="140", "Chromium";v="140", "Not=A?Brand";v="24"',
                                    'Sec-CH-UA-Mobile': '?1', 'Sec-CH-UA-Platform': '"Android"'}}
FIXTURE_AWAY = {'firefox': 30, 'safari-ios': 25, 'android-chrome': 40}
IPAD_DESKTOP_UA = ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
                   '(KHTML, like Gecko) Version/18.0 Safari/605.1.15')


def _temp_git_repo(path):
    """HEAD의 진짜 조상 1개와 조상이 아닌 떠돌이 커밋 1개가 있는 임시 저장소. (조상, 떠돌이) SHA."""
    git = shutil.which('git')
    if not git:
        raise RuntimeError('validate-selftest에는 git이 필요하다')
    env = {**os.environ, 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1'}
    base = [git, '-C', str(path), '-c', 'user.name=kit', '-c', 'user.email=kit@example.invalid',
            '-c', 'commit.gpgsign=false']

    def run(*args):
        return subprocess.run(base + list(args), check=True, capture_output=True, text=True, env=env).stdout.strip()

    path.mkdir()
    run('init', '-q')
    run('commit', '-q', '--allow-empty', '-m', 'kit a')
    ancestor = run('rev-parse', 'HEAD')
    run('commit', '-q', '--allow-empty', '-m', 'kit b')
    stray = run('commit-tree', run('rev-parse', 'HEAD^{tree}'), '-m', 'stray root')  # 부모 없음 → 조상 아님
    return ancestor, stray


def evidence_from_skeleton(skeleton, skeleton_sha256, kit_sha):
    """스켈레톤 등록·관찰과 정확히 일치하는 통과 증거(운영자가 작성하는 형태)."""
    devices = []
    for registration in skeleton['devices']:
        kind = registration['kind']
        away = next(o['bg_seconds'] for o in skeleton['observations'] if o['kind'] == kind)
        devices.append({'kind': kind, 'ua': registration['request_ua'], 'platform': registration['platform'],
                        'checks': {**{name: True for name in REQUIRED_CHECKS},
                                   'background_return': {'performed': True, 'away_seconds': away,
                                                         'decrypted_after_return': True},
                                   'storage_eviction': {'tested': True, 'rejoined': True},
                                   'rejoin_guidance': REJOIN_GUIDANCE}})
    return {'schema': 'real-device-evidence:v1', 'synthetic_only': True, 'ci': False, 'kit_git_sha': kit_sha,
            'operated_by': 'tester', 'dates': ['2026-10-01'], 'session_log_sha256': skeleton_sha256,
            'session': json.loads(json.dumps(skeleton['session'])), 'devices': devices}


def validator_selftest():
    """검증기 + 서버 등록 경로 점검. 통과하면 케이스 dict, 아니면 AssertionError."""
    import urllib.error
    import urllib.request

    cases = {}

    def check(name, bad, *needles):
        """needles가 비면 통과(bad == [])를, 아니면 각 needle이 어떤 위반문에 들어 있음을 요구."""
        if not needles:
            assert bad == [], (name, bad)
        for needle in needles:
            assert any(needle in line for line in bad), (name, needle, bad)
        cases[name] = True

    def clone(obj):
        return json.loads(json.dumps(obj))

    with tempfile.TemporaryDirectory(prefix='real-device-validator-') as tmp:
        tmp = Path(tmp)
        ancestor, stray = _temp_git_repo(tmp / 'repo')
        repo = tmp / 'repo'

        # 1) 실제 HTTP 서버(자산 스텁)로 등록·관찰·가드·로그 경로를 점검한다.
        session = Session({'/panel.html': b'<!doctype html><title>stub</title>'},
                          {'family_mls_browser_experiment.js': 'a' * 64,
                           'family_mls_browser_experiment_bg.wasm': 'b' * 64, 'custody.js': 'c' * 64})
        server, urls = serve_session(session, 0, '127.0.0.1')
        base = urls[0].rsplit('/', 1)[0]

        def call(url, body=None, headers=None, method=None, raw=None):
            data = raw if raw is not None else (None if body is None else json.dumps(body).encode())
            request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    return response.status, json.loads(response.read())
            except urllib.error.HTTPError as error:
                return error.code, None

        try:
            for kind in KINDS:
                status, _ = call(base + '/devices',
                                 {'kind': kind, 'ua': FIXTURE_UA[kind], 'platform': FIXTURE_PLATFORM[kind]},
                                 {'User-Agent': FIXTURE_UA[kind], **FIXTURE_HINTS.get(kind, {})})
                assert status == 200, (kind, status)
                status, _ = call(base + '/observations',
                                 {'kind': kind, 'bg_seconds': FIXTURE_AWAY[kind], 'bg_decrypted': True, 'notes': ''},
                                 {'User-Agent': FIXTURE_UA[kind]})
                assert status == 200, (kind, status)
            status, _ = call(base + '/devices', raw=b'{}', method='POST',
                             headers={'Content-Length': 'abc', 'User-Agent': 'x'})
            assert status == 400, status
            cases['content_length_garbage_400'] = True
            bad_token = base.replace(session.token, '0' * 32)
            status, _ = call(bad_token + '/devices', headers={'User-Agent': 'intruder'})
            assert status == 404, status
            status, skeleton_live = call(base + '/evidence.json', headers={'User-Agent': 'reader'})
            assert status == 200
        finally:
            server.shutdown()
            server.server_close()
        assert all(not entry['path'].startswith('/s/') for entry in session.log), session.log
        assert all(entry['ua'] != 'intruder' for entry in session.log), '거부된 요청이 기록됐다'
        assert {'/devices', '/observations', '/evidence.json'} <= {e['path'] for e in session.log}
        cases['log_paths_stripped_and_denied_not_logged'] = True
        android = next(d for d in session.devices if d['kind'] == 'android-chrome')
        assert android['request_sec_ch_ua_mobile'] == '?1' and android['request_sec_ch_ua_platform'] == '"Android"'
        firefox = next(d for d in session.devices if d['kind'] == 'firefox')
        assert firefox['request_sec_ch_ua'] is None and firefox['request_ua'] == FIXTURE_UA['firefox']
        cases['client_hints_recorded'] = True

        skeleton_path = save_skeleton(session, urls[0], root=tmp / 'artifacts')
        skeleton = json.loads(skeleton_path.read_text())
        assert skeleton['session'] == skeleton_live['session'], '저장된 스켈레톤이 /evidence.json 응답과 다르다'
        sha = sha256_file(skeleton_path)
        valid = evidence_from_skeleton(skeleton, sha, ancestor)

        # 2) 통과 케이스: 파일 경로 기반 검증(실 CLI 경로)과 메모리 기반 검증 둘 다.
        evidence_path = tmp / 'evidence.json'
        evidence_path.write_text(json.dumps(valid, ensure_ascii=False))
        check('valid_with_matching_skeleton', validate_files(evidence_path, skeleton_path, repo))
        check('valid_in_memory', problems(valid, skeleton, sha, repo))

        # 3) 위반 케이스(각각 특정 사유 문구를 요구한다).
        forged = clone(valid)
        forged['devices'][0]['ua'] = FIXTURE_UA['firefox'].replace('143.0', '144.0')
        check('forged_ua', problems(forged, skeleton, sha, repo), 'request_ua와 다르다')
        wrong = clone(valid)
        wrong['session_log_sha256'] = '0' * 64
        check('wrong_sha_field', problems(wrong, skeleton, sha, repo), 'session_log_sha256')
        tampered_path = tmp / 'tampered-skeleton.json'
        tampered_path.write_text(skeleton_path.read_text() + '\n')
        check('tampered_skeleton_file', validate_files(evidence_path, tampered_path, repo), 'session_log_sha256')
        session_edit = clone(valid)
        session_edit['session']['requests'] += 1
        check('session_mismatch', problems(session_edit, skeleton, sha, repo), 'evidence.session')
        no_obs = clone(skeleton)
        no_obs['observations'] = [o for o in no_obs['observations'] if o['kind'] != 'safari-ios']
        check('missing_observation', problems(valid, no_obs, sha, repo), 'safari-ios: 스켈레톤 observations')
        short_obs = clone(skeleton)
        next(o for o in short_obs['observations'] if o['kind'] == 'firefox')['bg_seconds'] = 10
        check('observation_under_20s', problems(valid, short_obs, sha, repo), 'firefox: 스켈레톤 observations')
        away_edit = clone(valid)
        next(d for d in away_edit['devices'] if d['kind'] == 'android-chrome')['checks']['background_return']['away_seconds'] = 99
        check('away_seconds_mismatch', problems(away_edit, skeleton, sha, repo), 'android-chrome: 스켈레톤 observations')
        not_ancestor = clone(valid)
        not_ancestor['kit_git_sha'] = stray
        check('non_ancestor_sha', problems(not_ancestor, skeleton, sha, repo), 'HEAD의 조상이 아니다')
        unknown = clone(valid)
        unknown['kit_git_sha'] = 'f' * 40
        check('unknown_sha', problems(unknown, skeleton, sha, repo), 'git merge-base 실패')
        short = clone(valid)
        short['kit_git_sha'] = ancestor[:7]
        check('short_sha', problems(short, skeleton, sha, repo), '40헥스')
        flags = clone(valid)
        flags['synthetic_only'], flags['ci'] = False, True
        check('synthetic_ci_flags', problems(flags, skeleton, sha, repo), 'synthetic_only=true·ci=false')
        headless_skel, headless_ev = clone(skeleton), clone(valid)
        headless_ua = 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 HeadlessChrome/140.0.0.0 Mobile Safari/537.36'
        reg = next(d for d in headless_skel['devices'] if d['kind'] == 'android-chrome')
        reg['ua'] = reg['request_ua'] = headless_ua
        next(d for d in headless_ev['devices'] if d['kind'] == 'android-chrome')['ua'] = headless_ua
        check('headless_ua_heuristic', problems(headless_ev, headless_skel, sha, repo), 'Headless')
        hinted = clone(skeleton)
        next(d for d in hinted['devices'] if d['kind'] == 'firefox')['request_sec_ch_ua'] = '"Chromium";v="140"'
        check('firefox_with_client_hints', problems(valid, hinted, sha, repo), 'Sec-CH-UA 헤더 존재')
        ipad_skel, ipad_ev = clone(skeleton), clone(valid)
        reg = next(d for d in ipad_skel['devices'] if d['kind'] == 'safari-ios')
        reg['ua'] = reg['request_ua'] = IPAD_DESKTOP_UA
        reg['platform'] = 'MacIntel'
        dev = next(d for d in ipad_ev['devices'] if d['kind'] == 'safari-ios')
        dev['ua'], dev['platform'] = IPAD_DESKTOP_UA, 'MacIntel'
        check('ipad_desktop_ua_without_flag', problems(ipad_ev, ipad_skel, sha, repo), '--allow-ipad-desktop-ua')
        check('ipad_desktop_ua_with_flag', problems(ipad_ev, ipad_skel, sha, repo, allow_ipad_desktop_ua=True))
        reg['request_sec_ch_ua_mobile'] = '?0'
        check('ipad_desktop_ua_with_hints_rejected',
              problems(ipad_ev, ipad_skel, sha, repo, allow_ipad_desktop_ua=True), 'Sec-CH-UA-Mobile 헤더 존재')
        norejoin = clone(valid)
        norejoin['devices'][0]['checks']['rejoin_guidance'] = '짧다'
        check('no_rejoin_guidance', problems(norejoin, skeleton, sha, repo), 'rejoin 안내')
        two = clone(valid)
        two['devices'] = two['devices'][:2]
        check('two_devices_only', problems(two, skeleton, sha, repo), '기기 3종')
        unregistered = clone(skeleton)
        unregistered['devices'] = [d for d in unregistered['devices'] if d['kind'] != 'android-chrome']
        check('unregistered_kind', problems(valid, unregistered, sha, repo), 'android-chrome: 스켈레톤에 등록 기록 없음')
    return cases


# ---------------------------------------------------------------- selftest(헤드리스 리허설 — 실기기 증거 아님)

def selftest(bundle):
    import urllib.request

    def http(url, method='GET', body=None):
        request = urllib.request.Request(url, method=method, data=body)
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read())

    from playwright.sync_api import sync_playwright

    server, session, urls = start_server(bundle, 0, '127.0.0.1')
    entry = next(url for url in urls if '127.0.0.1' in url)  # http://127.0.0.1:<port>/s/<token>/panel.html
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
        # 헤드리스 등록도 서버 관측값을 남긴다 — 검증기는 이 UA를 'Headless' 휴리스틱으로 거른다.
        assert all(d['request_ua'] and d['ua'] == d['request_ua'] for d in skeleton['devices']), skeleton['devices']
        assert all(not e['path'].startswith('/s/') for e in skeleton['session']['log'])
        receipt['phases']['skeleton_devices_observations'] = True
        receipt['bundle'] = skeleton['session']['bundle']
        contexts[0].close()
        browser.close()
    server.shutdown()

    # 5) 검증기 단위 점검(validate-selftest와 동일)
    receipt['validator_cases'] = validator_selftest()
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
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    command = parser.add_subparsers(dest='command', required=True)
    default_bundle = ARCHIVE.parent / 'artifacts' / 'mls-pkg'
    serve = command.add_parser('serve', help='LAN 세션 서버')
    serve.add_argument('--bundle', type=Path, default=default_bundle)
    serve.add_argument('--port', type=int, default=8765)
    serve.add_argument('--bind', default='0.0.0.0',
                       help='바인드 주소. 기본 0.0.0.0(모든 인터페이스, 경고 출력) — 실기기와 같은 LAN IP 권장')
    validate = command.add_parser('validate', help='증거 JSON 검사(스켈레톤 대조 필수)')
    validate.add_argument('evidence', type=Path)
    validate.add_argument('--skeleton', type=Path, required=True,
                          help='serve 종료 시 저장된 session-skeleton.json(서버 관측본)')
    validate.add_argument('--repo', type=Path, default=None,
                          help='kit_git_sha 조상 검사용 git 저장소(기본: 키트 파일의 git 루트 자동 탐지)')
    validate.add_argument('--allow-ipad-desktop-ua', action='store_true',
                          help='safari-ios 등록이 iPadOS 데스크톱급 UA(Macintosh)일 때 운영자 진술 하에 수용')
    command.add_parser('validate-selftest', help='검증기·등록 경로 점검(번들·Playwright 불필요)')
    rehearsal = command.add_parser('selftest', help='헤드리스 리허설(증거 아님)')
    rehearsal.add_argument('--bundle', type=Path, default=default_bundle)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == 'serve':
        if args.bind in ('', '0.0.0.0'):
            print(f'경고: --bind 0.0.0.0 — 모든 인터페이스에 바인드한다. 실기기와 같은 LAN IP로 제한을 권장: '
                  f'--bind {lan_ip()}', file=sys.stderr)
        server, session, urls = start_server(args.bundle.resolve(strict=True), args.port, args.bind)
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
        bad = validate_files(args.evidence, args.skeleton, args.repo, args.allow_ipad_desktop_ua)
        for line in bad:
            print('위반:', line, file=sys.stderr)
        if not bad:
            print(f'통과: {args.evidence} ↔ {args.skeleton} (sha256 {sha256_file(args.skeleton)[:12]}…)')
            print('주의: 검증기는 스켈레톤 대조·커밋 조상만 증명한다. headless 배제는 운영자 진술에 의존한다.')
        raise SystemExit(1 if bad else 0)
    elif args.command == 'validate-selftest':
        cases = validator_selftest()
        print(json.dumps({'real_device_evidence': False, 'validator_selftest': True, 'cases': cases},
                         ensure_ascii=False, indent=1))
    else:
        selftest(args.bundle.resolve(strict=True))


if __name__ == '__main__':
    main()
