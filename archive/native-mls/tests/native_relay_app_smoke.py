#!/usr/bin/env python3
"""Human relay client smoke (#243 2-a): two browser contexts drive web/relay-app.html
against a real v2 relay that serves the client itself (-static-dir), access mode
disabled (loopback, no JWT), membership enforcement off. Proves the page's own
relay flow — create → key package → invite_with_commit → own-echo merge → targeted
Welcome → join → messages both ways → cursor ack — without any Python-side relay
calls: every /v2/* request below comes from the page. Also (#251 B) the relay is
stopped mid-session: 보내기 must raise the human-readable 연결 실패 dialog, keep the
input, show 연결 끊김 on the status line, and succeed again once the relay is back
on the same port and data dir.

  python3 archive/native-mls/tests/native_relay_app_smoke.py \
      --bundle artifacts/mls-pkg --relay-binary artifacts/native-mls-relay

Synthetic only (disposable keys, loopback). Receipt: archive/artifacts/native-relay-app-*/verification.json
"""
import argparse
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
WEB = HERE.parents[1] / 'experiments' / 'openmls-browser' / 'web'
ARCHIVE = HERE.parents[1]
ROOM = 'family-acc'


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class Relay:
    """The relay under test; start()/stop() so the flow can take it down and bring it
    back on the same port and data dir (rooms, events and cursors persist in SQLite)."""

    def __init__(self, binary, port, data, static, log):
        self.argv = [str(binary.resolve()), '-addr', f'127.0.0.1:{port}', '-data-dir', str(data),
                     '-access-mode', 'disabled', '-static-dir', str(static)]
        self.base = f'http://127.0.0.1:{port}'
        self.log = log
        self.proc = None

    def start(self):
        self.proc = subprocess.Popen(self.argv, stdout=open(self.log, 'ab'), stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                with urllib.request.urlopen(self.base + '/v2/health', timeout=2) as r:
                    if r.status == 200:
                        return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError('relay did not start: ' + self.log.read_text()[-800:])

    def stop(self):
        if self.proc is None:
            return
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        self.proc = None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bundle', required=True, type=Path)
    ap.add_argument('--relay-binary', required=True, type=Path)
    ap.add_argument('--keep', action='store_true')
    args = ap.parse_args()

    work = Path(tempfile.mkdtemp(prefix='relay-app-'))
    static = work / 'static'
    static.mkdir()
    for f in WEB.glob('*.js'):
        shutil.copy(f, static / f.name)
    for f in WEB.glob('*.html'):
        shutil.copy(f, static / f.name)
    (static / 'pkg').mkdir()
    for name in ('family_mls_browser_experiment.js', 'family_mls_browser_experiment_bg.wasm', 'custody.js'):
        shutil.copy(args.bundle / name, static / 'pkg' / name)
    port = free_port()
    data = work / 'data'
    data.mkdir(mode=0o700)
    relay = Relay(args.relay_binary, port, data, static, work / 'relay.log')
    base = relay.base
    receipt = {'synthetic_only': True, 'real_device_evidence': False, 'checks': {}, 'room': ROOM}
    out_dir = ARCHIVE / 'artifacts' / f'native-relay-app-{secrets.token_hex(4)}'
    try:
        relay.start()
        with urllib.request.urlopen(base + '/app/', timeout=5) as r:
            html = r.read().decode()
            assert '<title>독자 E2EE 인수검사 클라이언트' in html, html[:200]
            assert "'wasm-unsafe-eval'" in r.headers.get('Content-Security-Policy', ''), r.headers
        receipt['checks']['static_client_served_by_relay'] = True

        pages = []
        with sync_playwright() as p:
            browser = p.chromium.launch()
            receipt['browser'] = browser.version

            class Dev:
                def __init__(self, dev):
                    self.dev = dev
                    self.dialogs = []  # alert()/confirm() texts, captured before dismissal
                    self.ctx = browser.new_context()
                    self.page = self.ctx.new_page()
                    pages.append(self)
                    self.page.on('dialog', self.on_dialog)
                    self.page.goto(base + '/app/', timeout=20000)
                    self.page.wait_for_function('() => window.ready === true', timeout=30000)
                    self.page.fill('#room', ROOM)
                    self.page.fill('#device', dev)
                    self.page.fill('#database', f'family-mls-synthetic-app-{dev}')
                    self.page.fill('#passphrase', secrets.token_urlsafe(24))
                    self.page.click('#start')
                    self.page.wait_for_function("() => document.getElementById('state').textContent.includes('지문')", timeout=180000)

                def on_dialog(self, dialog):
                    self.dialogs.append(dialog.message)
                    dialog.dismiss()

                def state(self):
                    return self.page.text_content('#state')

                def wait_state(self, has=(), lacks=(), timeout=20000):
                    """Status line (#state) contains every `has` and none of `lacks`."""
                    self.page.wait_for_function(
                        "([has, lacks]) => { const s = document.getElementById('state').textContent;"
                        " return has.every(t => s.includes(t)) && lacks.every(t => !s.includes(t)); }",
                        arg=[list(has), list(lacks)], timeout=timeout)

                def loglen(self):
                    return self.page.evaluate("document.getElementById('log').textContent.length")

                def wait_log(self, text, before, timeout=60000):
                    self.page.wait_for_function(
                        "([t, n]) => { const s = document.getElementById('log').textContent; return s.length > n && s.includes(t); }",
                        arg=[text, before], timeout=timeout)

                def click(self, sel, expect, timeout=60000):
                    n = self.loglen()
                    self.page.click(sel)
                    self.wait_log(expect, n, timeout)

                def messages(self):
                    return self.page.eval_on_selector_all('#messages div', 'els => els.map(e => e.textContent)')

                def roster(self):
                    return self.page.text_content('#roster')

            def dump():
                for d in pages:
                    try:
                        print(f'--- page log {d.dev}:\n' + d.page.text_content('#log')[-1500:], file=sys.stderr)
                        print(f'--- state {d.dev}: ' + d.page.text_content('#state')[:300], file=sys.stderr)
                    except Exception as e:  # noqa: BLE001
                        print(f'--- page log {d.dev}: unavailable ({e})', file=sys.stderr)
            try:
                run_flow(Dev, receipt, base, relay)
            except Exception:
                dump()
                raise
            browser.close()
        receipt['relay_log_tail'] = (work / 'relay.log').read_text()[-1200:]
        out_dir.mkdir(parents=True, mode=0o700)
        (out_dir / 'verification.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=1))
        print(json.dumps(receipt['checks'], ensure_ascii=False))
        print(out_dir / 'verification.json')
    except Exception:
        print('--- relay log:\n' + (work / 'relay.log').read_text()[-1500:], file=sys.stderr)
        raise
    finally:
        relay.stop()
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)


def run_flow(Dev, receipt, base, relay):
            a, b = Dev('owner-pc'), Dev('owner-phone')
            receipt['checks']['two_durable_workers_started'] = True
            a.click('#create', '방(그룹) 생성')
            b.click('#keypackage', '키 패키지 게시')
            a.page.fill('#target', 'owner-phone')
            a.click('#invite', 'Welcome 전송', timeout=90000)   # commit 201 → own echo merge → welcome posted
            assert 'owner-phone' in a.roster() and 'owner-pc' in a.roster(), a.roster()
            b.click('#sync', '참여 완료', timeout=90000)
            assert 'owner-pc' in b.roster() and 'owner-phone' in b.roster(), b.roster()
            receipt['checks']['invite_with_commit_merge_on_echo_targeted_welcome_join'] = True

            a.page.fill('#msg', 'hello from pc')
            a.page.click('#send')  # no log line on success: the message row is the signal
            a.page.wait_for_function("() => document.getElementById('messages').textContent.includes('hello from pc')", timeout=30000)
            b.page.wait_for_function("() => document.getElementById('messages').textContent.includes('hello from pc')", timeout=30000)
            b.page.fill('#msg', 'hi from phone')
            b.page.click('#send')
            a.page.wait_for_function("() => document.getElementById('messages').textContent.includes('hi from phone')", timeout=30000)
            msgs_a, msgs_b = a.messages(), b.messages()
            assert any('owner-phone' in m and 'hi from phone' in m for m in msgs_a), msgs_a
            assert any('owner-pc' in m and 'hello from pc' in m for m in msgs_b), msgs_b
            receipt['checks']['messages_both_ways_with_authenticated_sender'] = True

            # The relay-side cursor advanced via ?ack= (reads alone never move it).
            with urllib.request.urlopen(base + f'/v2/rooms/{ROOM}/events?device=owner-phone&after=0', timeout=5) as r:
                view = json.load(r)
            assert view['cursor'] >= 3, view['cursor']
            receipt['checks']['relay_cursor_acked_by_page'] = True
            assert '동기화 ' in a.state(), a.state()   # last-sync clock on the status line (#251 A-4)

            # Network failure (#251 B): relay down → the quiet poll flags 연결 끊김 on the status
            # line (no dialog), 보내기 raises the 연결 실패 dialog and keeps the input; relay back
            # on the same port/data dir → the status line clears and the same text sends.
            relay.stop()
            a.wait_state(has=['연결 끊김'])
            dialogs_before = len(a.dialogs)
            a.page.fill('#msg', 'sent after the outage')
            a.click('#send', '연결 실패', timeout=20000)
            for _ in range(50):   # the dialog event lands right after the log line; give it a moment
                if len(a.dialogs) > dialogs_before:
                    break
                a.page.wait_for_timeout(100)
            assert any('연결 실패' in d for d in a.dialogs[dialogs_before:]), a.dialogs
            assert a.page.input_value('#msg') == 'sent after the outage', a.page.input_value('#msg')
            assert '연결 끊김' in a.state(), a.state()
            relay.start()
            a.wait_state(has=['동기화 '], lacks=['연결 끊김'])
            a.page.click('#send')
            a.page.wait_for_function("() => document.getElementById('messages').textContent.includes('sent after the outage')", timeout=30000)
            b.page.wait_for_function("() => document.getElementById('messages').textContent.includes('sent after the outage')", timeout=30000)
            assert a.page.input_value('#msg') == '', a.page.input_value('#msg')
            assert not any('연결 실패' in d for d in a.dialogs[dialogs_before + 1:]), a.dialogs
            receipt['checks']['network_failure_notice_input_kept_retry_after_relay_restart'] = True

            # Resume: reload the phone page, start again with the same DB/passphrase → state survives.
            pw = secrets.token_urlsafe(24)
            b.page.evaluate("() => window.stopWorker('device')")
            b.page.reload()
            b.page.wait_for_function('() => window.ready === true', timeout=30000)
            b.page.fill('#passphrase', pw)  # wrong passphrase must fail, not corrupt
            n = b.loglen(); b.page.click('#start')
            b.wait_log('실패', n, 180000)
            receipt['checks']['wrong_passphrase_rejected'] = True


if __name__ == '__main__':
    sys.exit(main())
