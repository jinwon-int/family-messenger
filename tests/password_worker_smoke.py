#!/usr/bin/env python3
"""Owned disposable Chromium/password-container feasibility, not a live vault."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import stat
import tempfile
import threading
import time
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
CSP = "default-src 'none'; script-src 'self'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"


def safe_bytes(path, limit):
    for parent in path.parents:
        s = parent.lstat()
        assert stat.S_ISDIR(s.st_mode) and not s.st_mode & 0o022
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        s = os.fstat(fd)
        assert stat.S_ISREG(s.st_mode) and s.st_uid == os.geteuid() and s.st_nlink == 1
        assert not s.st_mode & 0o022 and s.st_size <= limit
        data = os.read(fd, limit + 1)
        assert len(data) == s.st_size
        return data
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--synthetic-only', action='store_true')
    args = parser.parse_args()
    assert args.synthetic_only, 'explicit generated-data acknowledgement required'
    artifacts = ROOT / 'artifacts'
    for path in [artifacts, *artifacts.parents]:
        s = path.lstat()
        assert stat.S_ISDIR(s.st_mode) and not s.st_mode & 0o022
    out = Path(tempfile.mkdtemp(prefix='password-worker-', dir=artifacts))
    out.chmod(0o700)
    assets = {'/': b'<!doctype html><title>Synthetic worker archive only</title><script type="module" src="/password-page.js"></script>'}
    for name, directory in [('password-page.js', ''), ('password-worker.js', 'bundle')]:
        assets['/' + name] = safe_bytes(ROOT / 'experiments/device-keystore' / directory / name, 1024*1024)
    inventory = json.loads(safe_bytes(ROOT / 'experiments/device-keystore/password-inventory.json', 65536))
    assert hashlib.sha256(assets['/password-worker.js']).hexdigest() == inventory['sha256']
    proof = {'synthetic_only': True, 'human_key_protection': False, 'native_integration': False,
             'mobile_qualified': False, 'checks': {}, 'timings_ms': {},
             'asset_sha256': {k: hashlib.sha256(v).hexdigest() for k, v in assets.items()}}
    # Aggregate RSS includes shared pages counted repeatedly and Playwright's Node
    # driver. It is a process-tree observation, not isolated worker heap or PSS.
    stop = threading.Event()
    peak = [0]
    def sample():
        while not stop.wait(.1):
            rows = {}
            for p in Path('/proc').glob('[0-9]*/status'):
                try:
                    fields = dict(line.split(':', 1) for line in p.read_text().splitlines() if ':' in line)
                    rows[int(p.parent.name)] = (int(fields['PPid']), int(fields.get('VmRSS', '0 kB').split()[0]))
                except (OSError, ValueError, KeyError):
                    continue
            descendants = {os.getpid()}
            while True:
                new = {pid for pid, (ppid, _) in rows.items() if ppid in descendants}
                if new <= descendants:
                    break
                descendants |= new
            peak[0] = max(peak[0], sum(rows.get(pid, (0,0))[1] for pid in descendants if pid != os.getpid()))
    monitor = threading.Thread(target=sample, daemon=True)
    class Server(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            host = f'localhost:{self.server.server_port}'
            if self.path not in assets or self.headers.get('Host') != host or self.headers.get('Origin') not in (None, 'http://' + host):
                self.send_error(403)
                return
            data = assets[self.path]
            self.send_response(200)
            for name, value in [('Content-Type', 'text/html' if self.path == '/' else 'text/javascript'),
                                ('Content-Length', str(len(data))), ('Content-Security-Policy', CSP),
                                ('X-Content-Type-Options', 'nosniff'), ('Cache-Control', 'no-store')]:
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(data)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    monitor.start()
    password = secrets.token_urlsafe(32)  # Memory only, never serialized in receipt/profile.
    started = time.monotonic()
    try:
        with sync_playwright() as pw:
            profile = out / 'synthetic-profile'
            profile.mkdir(mode=0o700)
            def launch():
                return pw.chromium.launch_persistent_context(str(profile), headless=True)
            context = launch()
            def page_open():
                page = context.new_page()
                page.goto(f'http://localhost:{server.server_port}')
                for _ in range(100):
                    if page.evaluate('Boolean(window.passwordProbe)'):
                        return page
                    page.wait_for_timeout(20)
                raise AssertionError('page bootstrap')
            def call(page, op, cipher=None, secret=None):
                return page.evaluate('x => passwordProbe.command(x.op,x.password,x.cipher)',
                                     {'op':op,'password':secret or password,'cipher':cipher})
            a = page_open()
            proof['browser'] = context.browser.version if context.browser else 'persistent Chromium'
            created = call(a, 'create')
            cipher = created['ciphertext']
            assert created['kdf'] and 2048 < len(cipher) < 8192
            opened = call(a, 'unlock', cipher)
            assert opened['matched'] and opened['kdf'] and set(opened) == {'type','matched','ms','kdf'}
            proof['timings_ms'].update(encrypt=created['ms'], decrypt=opened['ms'])
            proof['checks']['worker_default_password_roundtrip_no_plaintext_reply'] = True
            wrong = call(a, 'unlock', cipher, secrets.token_urlsafe(32))
            assert wrong == {'denied':True, 'kdf':True}
            proof['checks']['wrong_password_denied_after_kdf'] = True
            bad = cipher.copy(); bad[-1] ^= 1
            for variant in [bad, cipher[:-1]]:
                assert call(a, 'unlock', variant) == {'denied':True, 'kdf':True}
            assert call(a, 'unlock', cipher)['matched']
            proof['checks']['tamper_truncation_denied_original_preserved'] = True
            wire = bytes(cipher)
            assert b' 18\n' in wire[:200]
            for factor in [b'20', b'19', b'17', b'018', b'999', b'+18', b'\xc2\xb9\xe2\x81\xb8']:
                variant = list(wire.replace(b' 18\n', b' '+factor+b'\n', 1))
                assert call(a, 'unlock', variant) == {'denied':True, 'kdf':False}
            proof['checks']['nondefault_work_factors_denied_before_kdf'] = True
            for variant in [[], [0]*8193, [1.5], list(b'not an age file'), list(wire[:30])]:
                assert call(a, 'unlock', variant) == {'denied':True, 'kdf':False}
            lines = wire.split(b'\n', 3)
            duplicate = lines[0]+b'\n'+lines[1]+b'\n'+lines[2]+b'\n'+lines[1]+b'\n'+lines[2]+b'\n'+lines[3]
            for variant in [duplicate, wire.replace(b'-> scrypt ', b'-> X25519 ', 1)]:
                assert call(a, 'unlock', list(variant)) == {'denied':True, 'kdf':False}
            proof['checks']['bounds_and_malformed_header_deny_before_kdf'] = True
            newer = call(a, 'create')['ciphertext']
            assert newer != cipher and call(a, 'unlock', cipher)['matched']
            proof['checks']['fresh_random_ciphertext_old_valid_archive_still_readable'] = True
            a.evaluate('c => passwordProbe.archive(c)', cipher)
            assert a.evaluate('() => passwordProbe.load()') == cipher
            assert a.evaluate('async c => {try {await passwordProbe.archive(c);return false} catch{return true}}', newer)
            proof['checks']['write_once_ciphertext_archive_refuses_replacement'] = True
            a.reload()
            for _ in range(100):
                if a.evaluate('Boolean(window.passwordProbe)'): break
                a.wait_for_timeout(20)
            assert a.evaluate('() => passwordProbe.load()') == cipher
            assert call(a, 'unlock', cipher)['matched']
            proof['checks']['page_reload_same_encrypted_archive'] = True
            # Test lock during actual synchronous KDF; a worker message cannot
            # interrupt it, so page ownership terminates the worker instead.
            def begin(page):
                page.evaluate('x => {window.pending=passwordProbe.command("unlock",x.password,x.cipher);}', {'password':password,'cipher':cipher})
                for _ in range(1000):
                    if page.evaluate('passwordProbe.active()?.kdf === true'): return
                    page.wait_for_timeout(2)
                raise AssertionError('KDF never began')
            begin(a)
            a.evaluate('passwordProbe.lock()')
            assert a.evaluate('() => window.pending') == {'denied':True,'locked':True,'kdf':True}
            assert a.evaluate('passwordProbe.active()') is None
            proof['checks']['terminate_during_kdf_denies_late_result'] = True
            b = page_open()
            begin(a)
            b.evaluate('passwordProbe.lock()')
            assert a.evaluate('() => window.pending') == {'denied':True,'locked':True,'kdf':True}
            assert a.evaluate('() => passwordProbe.load()') == cipher
            proof['checks']['cooperating_tab_lock_retires_inflight_candidate'] = True
            context.close()
            context = launch()
            a = page_open()
            assert a.evaluate('() => passwordProbe.load()') == cipher
            assert call(a, 'unlock', cipher)['matched']
            proof['checks']['actual_browser_close_restart_same_ciphertext_unlock'] = True
            context.close()
            proof['passed'] = True
    finally:
        stop.set(); monitor.join(timeout=2)
        server.shutdown(); server.server_close()
        proof['timing_seconds'] = round(time.monotonic()-started, 3)
        proof['aggregate_descendant_rss_peak_kib'] = peak[0]
        path = out / 'verification.json'
        path.write_text(json.dumps(proof, indent=2)+'\n'); path.chmod(0o600)
        print(path)

if __name__ == '__main__':
    main()
