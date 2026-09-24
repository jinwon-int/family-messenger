#!/usr/bin/env python3
"""#177 M1 client smoke: browser MLS facade devices against the real v2 relay.

Four synthetic devices (a:1, a:2, b:1, b:2), each a memory-only OpenMLS worker in
its own browser context, exchange commits / targeted Welcomes / application
messages through the v2 relay binary (archive/native-mls/server) over HTTP.

Scope, stated plainly: MLS state and every encrypt/decrypt/commit/join runs in the
browser workers; the /v2 transport (fetch, cursors, retry decisions) is this Python
harness, because no browser /v2 client exists yet (device-worker is M2/M3). The
relay runs unauthenticated, as in M1. Only synthetic bytes; no people, keys or rooms.

Fault injections (client <-> relay):
  a  stale-epoch application -> 409 -> apply the missed commit -> re-encrypt -> 201
  b  lost POST response -> byte-equal retry after another commit -> 200 duplicate (K4)
  c  same client_id with different bytes -> 409 client_id_reuse, sender keeps going
  d  relay SIGKILL -> restart on the same data dir -> cursors resume; an offline
     device's unread events survive pruning; pruning advances once all have read
  e  targeted Welcome is only ever delivered to its targets (B4 filter, never 403)
  f  room byte cap 413 -> the sender device is not retired and the room stays live
  g  commit race: two members commit at the same epoch; the loser gets 409, drops its
     pending commit (clear_pending) and catches up; the winner first reads what the
     relay ordered before its commit, then merges (deferred merge)
"""
import argparse
import base64
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from playwright.sync_api import sync_playwright

ROOM = 'family'
BIG_PLAINTEXT = 12000  # < the facade's 16 KiB plaintext bound
CSP = ("default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; "
       "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")


class Relay:
    """The v2 relay binary on a loopback port; restartable over one data dir."""

    def __init__(self, binary, data_dir, log_dir, room_bytes_cap):
        self.binary, self.data_dir, self.log_dir = binary, data_dir, log_dir
        self.room_bytes_cap = room_bytes_cap
        self.proc = None
        self.starts = 0

    def start(self, app_event_ttl=None):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]
        argv = [str(self.binary), '-addr', f'127.0.0.1:{self.port}', '-data-dir', str(self.data_dir),
                '-room-bytes-cap', str(self.room_bytes_cap)]
        if app_event_ttl is not None:
            argv += ['-app-event-ttl-seconds', str(app_event_ttl)]
        self.starts += 1
        log = open(self.log_dir / f'relay-{self.starts}.log', 'wb')
        self.proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f'relay exited early: {self.proc.returncode}')
            try:
                if self.http('GET', '/v2/health')[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.1)
        raise RuntimeError('relay health deadline')

    def sigkill(self):
        self.proc.send_signal(signal.SIGKILL)
        self.proc.wait(timeout=10)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def http(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(f'http://127.0.0.1:{self.port}{path}', data=data, method=method,
                                     headers={'Content-Type': 'application/json'} if data else {})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, json.loads(resp.read() or b'{}')
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read() or b'{}')


def b64(data):
    return base64.b64encode(bytes(data)).decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--relay-binary', required=True, type=Path)
    parser.add_argument('--room-bytes-cap', type=int, default=64 * 1024)
    args = parser.parse_args()
    os.umask(0o077)
    repo = Path(__file__).resolve().parents[2]  # archive/
    (repo / 'artifacts').mkdir(mode=0o700, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='native-v2-relay-', dir=repo / 'artifacts'))
    paths = {'/': repo / 'experiments/openmls-browser/web/index.html'}
    for name in ['main.js', 'worker.js', 'durable-worker.js']:
        paths['/' + name] = repo / 'experiments/openmls-browser/web' / name
    for name in ['family_mls_browser_experiment.js', 'family_mls_browser_experiment_bg.wasm']:
        paths['/pkg/' + name] = args.bundle / name
    assets = {}
    for route, path in paths.items():
        st = path.lstat()
        if not path.is_file() or path.is_symlink() or st.st_nlink != 1 or st.st_size > 32 * 1024 * 1024:
            raise RuntimeError('unsafe or oversized asset')
        assets[route] = path.read_bytes()
    receipt = {'synthetic_only': True, 'durable_state': False, 'checks': {},
               'transport': 'python harness HTTP to the v2 relay; MLS state and operations in browser workers',
               'relay_auth': 'none (M1 relay is unauthenticated; device is self-declared)',
               'room_bytes_cap': args.room_bytes_cap}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.headers.get('Host') != expected_host or self.path not in assets:
                self.send_error(404)
                return
            body = assets[self.path]
            self.send_response(200)
            self.send_header('Content-Type', 'application/wasm' if self.path.endswith('.wasm') else
                             'text/javascript' if self.path.endswith('.js') else 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', CSP)
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    expected_host = f'127.0.0.1:{server.server_port}'
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    relay_dir = Path(tempfile.mkdtemp(prefix='relay-', dir=evidence))
    relay = Relay(args.relay_binary.resolve(), relay_dir / 'data', evidence, args.room_bytes_cap)
    try:
        relay.start()  # default app-event TTL (30 days): no time-based pruning before phase d
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            receipt['browser'] = browser.version

            class Device:
                def __init__(self, dev):
                    self.dev = dev
                    self.context = browser.new_context()
                    self.page = self.context.new_page()
                    self.page.goto('http://' + expected_host)
                    self.page.wait_for_function('window.ready === true')
                    self.page.evaluate("spawn('main')")
                    self.cursor = 0
                    self.joined = False
                    self.pending = False  # a commit we created, not yet merged
                    self.epoch = 0
                    self.serial = 0
                    self.call('init', dev)

                def call(self, method, argument=None, reject=False):
                    value = self.page.evaluate('([m, a]) => call("main", m, a)', [method, argument])
                    if reject:
                        assert value['ok'] is False and 'result' not in value, (self.dev, method, value)
                        return None
                    assert value['ok'] is True, (self.dev, method, value)
                    return value.get('result')

                def client_id(self, label):
                    self.serial += 1
                    return f'{self.dev}-{self.serial}-{label}'

                def post(self, kind, data, client_id, epoch=None, targets=None):
                    body = {'device': self.dev, 'client_id': client_id, 'kind': kind,
                            'epoch': self.epoch if epoch is None else epoch, 'bytes': b64(data)}
                    if targets:
                        body['targets'] = targets
                    return relay.http('POST', f'/v2/rooms/{ROOM}/events', body)

                def post_ok(self, kind, data, label, targets=None):
                    status, body = self.post(kind, data, self.client_id(label), targets=targets)
                    assert status == 201, (self.dev, kind, status, body)
                    self.epoch = body['epoch']
                    return body

                def raw_events(self, after=0):
                    status, body = relay.http('GET', f'/v2/rooms/{ROOM}/events?device={self.dev}&after={after}')
                    assert status == 200, (self.dev, status, body)
                    return body

                def sync(self):
                    """Apply every new event in total order; return decrypted application plaintexts."""
                    body = self.raw_events(self.cursor)
                    plain = []
                    for ev in body['events']:
                        self.cursor = max(self.cursor, ev['seq'])
                        if ev['device'] == self.dev:
                            # Own echo: OpenMLS never processes its own messages. Reaching our
                            # own commit means every event the relay ordered before it has
                            # been processed at the old epoch: only now merge it.
                            if ev['kind'] == 'commit' and self.pending:
                                self.call('merge_pending')
                                self.pending = False
                            continue
                        data = list(base64.b64decode(ev['bytes']))
                        if not self.joined:
                            if ev['kind'] == 'welcome':
                                self.call('join', data)
                                self.joined = True
                            continue  # anything before our Welcome is not ours to read
                        if ev['kind'] == 'welcome':
                            raise AssertionError(f'{self.dev} was delivered a Welcome not targeted at it: {ev}')
                        if ev['kind'] == 'commit':
                            self.call('commit', data)
                        else:
                            plain.append(bytes(self.call('decrypt', data)))
                    self.epoch = body['epoch']
                    return plain

                def publish_key_package(self):
                    package = self.call('key_package')
                    status, body = relay.http('POST', f'/v2/rooms/{ROOM}/keypackages',
                                              {'device': self.dev, 'packages': [{'ref': 'kp-1', 'bytes': b64(package)}]})
                    assert status == 201, (self.dev, status, body)

                def commit_ok(self, commit, label):
                    """POST a pending commit; on 201 catch up to it (merging there)."""
                    self.pending = True
                    self.post_ok('commit', commit, label)
                    plain = self.sync()
                    assert not self.pending, (self.dev, 'own commit not reached')
                    return plain

                def add(self, target):
                    """Consume target's KeyPackage, commit the add, send the targeted Welcome."""
                    status, kp = relay.http('GET', f'/v2/rooms/{ROOM}/keypackages?device={target.dev}&consumer={self.dev}')
                    assert status == 200, (target.dev, status, kp)
                    framed = bytes(self.call('invite_with_commit', list(base64.b64decode(kp['bytes']))))
                    size = int.from_bytes(framed[:4], 'little')
                    commit, welcome = framed[4:4 + size], framed[4 + size:]
                    self.commit_ok(commit, 'add-' + target.dev)
                    self.post_ok('welcome', welcome, 'welcome-' + target.dev, targets=[target.dev])
                    return len(commit), len(welcome)

            a1, a2, b1, b2 = (Device(d) for d in ['a:1', 'a:2', 'b:1', 'b:2'])
            everyone = [a1, a2, b1, b2]

            def expect(device, *messages):
                got = device.sync()
                assert got == [m.encode() for m in messages], (device.dev, got, messages)

            # --- group setup: a:1 creates; a:1 adds b:1, then its own second device a:2.
            for device in [a2, b1, b2]:
                device.publish_key_package()
            a1.call('create')
            a1.joined = True
            add_sizes = a1.add(b1)
            b1.sync()
            assert b1.joined and b1.epoch == 1
            a1.post_ok('application', a1.call('encrypt', list(b'hello b1')), 'm')
            expect(b1, 'hello b1')
            a1.add(a2)
            expect(b1)  # b:1 applies the a:2 add commit; the a:2 Welcome must not reach it
            a2.sync()
            assert a2.joined and a2.epoch == b1.epoch == a1.epoch == 2
            receipt['checks']['n_member_group_via_commit_and_targeted_welcome'] = True

            # --- a: stale-epoch application -> 409 -> apply commit -> re-encrypt -> 201.
            stale_plain = list('epoch-2 draft 재암호화'.encode())
            stale = a1.call('encrypt', stale_plain)
            stale_id = a1.client_id('stale')
            b1.add(b2)  # any member commits (not only the creator); room -> epoch 3
            status, body = a1.post('application', stale, stale_id)
            assert status == 409 and body['error'] == 'cas_mismatch' and body['epoch'] == 3, (status, body)
            assert a1.sync() == []  # applies b:1's commit; b:2's Welcome is filtered
            assert a1.epoch == 3
            fresh = a1.call('encrypt', stale_plain)
            status, body = a1.post('application', fresh, stale_id)  # the 409'd id was never stored
            assert status == 201 and body['epoch'] == 3, (status, body)
            # b:2 joins from b:1's Welcome (a non-creator Welcome must carry the tree)
            # and, in the same pass, reads the re-encrypted epoch-3 message.
            assert b2.sync() == [bytes(stale_plain)] and b2.joined
            for device in [a2, b1]:
                assert device.sync() == [bytes(stale_plain)], device.dev
            receipt['checks']['a_stale_epoch_409_apply_commit_reencrypt_delivered_once'] = True

            # --- b: lost response -> byte-equal retry after a concurrent commit -> 200 duplicate,
            # --- g: commit race: a:1 and b:1 both commit b:2's removal at epoch 3.
            lost = a2.call('encrypt', list(b'lost response'))
            lost_id = a2.client_id('lost')
            status, first = a2.post('application', lost, lost_id)
            assert status == 201, (status, first)  # ...and the response is "lost"
            b2_key = b2.call('public_key')
            losing = a1.call('remove_pending', b2_key)
            winning = b1.call('remove_pending', b2_key)
            # b:1 wins; the relay ordered a:2's epoch-3 message BEFORE b:1's commit, so b:1
            # must read it at epoch 3 and only then merge (deferred merge).
            assert b1.commit_ok(winning, 'remove-b2') == [b'lost response']
            assert b1.epoch == 4
            status, body = a1.post('commit', losing, a1.client_id('remove-b2'))
            assert status == 409 and body['error'] == 'cas_mismatch' and body['epoch'] == 4, (status, body)
            a1.call('clear_pending')  # stay at epoch 3, catch up, and find the goal already met
            expect(a1, 'lost response')
            assert a1.epoch == 4
            receipt['checks']['g_commit_race_loser_409_clear_pending_catch_up'] = True
            receipt['checks']['committer_reads_events_ordered_before_its_commit'] = True
            status, retry = a2.post('application', lost, lost_id, epoch=3)
            assert status == 200 and retry['duplicate'] is True and retry['seq'] == first['seq'], (status, retry)
            receipt['checks']['b_lost_response_retry_after_commit_is_200_duplicate'] = True

            # b:2 reads the message sent before its removal, then applies its own removal.
            expect(b2, 'lost response')
            assert a2.sync() == [] and a2.epoch == 4

            # --- c: same client_id, different bytes -> 409 client_id_reuse; sender keeps going.
            other = a2.call('encrypt', list(b'different bytes'))
            status, body = a2.post('application', other, lost_id)
            assert status == 409 and body['error'] == 'client_id_reuse', (status, body)
            a2.post_ok('application', a2.call('encrypt', list(b'after reuse')), 'after-reuse')
            expect(a1, 'after reuse')
            expect(b1, 'after reuse')
            receipt['checks']['c_client_id_reuse_409_sender_not_retired_gap_tolerated'] = True
            removed_view = b2.raw_events(b2.cursor)
            b2.cursor = max([b2.cursor] + [ev['seq'] for ev in removed_view['events']])
            [after_removal] = [ev for ev in removed_view['events'] if ev['kind'] == 'application']
            b2.call('decrypt', list(base64.b64decode(after_removal['bytes'])), reject=True)
            receipt['checks']['removed_device_cannot_read_next_epoch'] = True

            # --- e: every Welcome reached exactly its target and nobody else.
            welcomes = {d.dev: sum(ev['kind'] == 'welcome' for ev in d.raw_events()['events']) for d in everyone}
            assert welcomes == {'a:1': 0, 'a:2': 1, 'b:1': 1, 'b:2': 1}, welcomes
            receipt['checks']['e_targeted_welcome_filtered_for_every_non_target'] = True
            receipt['welcomes_visible'] = welcomes

            # --- f: room byte cap 413; the sender is not retired and the room stays live.
            big_sent = []
            for i in range(32):
                big = a1.call('encrypt', list(bytes([i]) * BIG_PLAINTEXT))
                status, body = a1.post('application', big, a1.client_id('big'))
                if status == 413:
                    break
                assert status == 201, (status, body)
                big_sent.append(bytes([i]) * BIG_PLAINTEXT)
            else:
                raise AssertionError('room byte cap never reached')
            assert body['error'] == 'room_bytes_cap', body
            remaining = body['cap_bytes'] - body['used_bytes']
            receipt['cap_413'] = {'used_bytes': body['used_bytes'], 'cap_bytes': body['cap_bytes'],
                                  'accepted_big_messages': len(big_sent)}
            assert remaining >= 600, f'tune --room-bytes-cap: only {remaining} bytes left after 413'
            a1.post_ok('application', a1.call('encrypt', list(b'after cap')), 'after-cap')
            for device in [a2, b1]:
                assert device.sync() == big_sent + [b'after cap'], device.dev
            receipt['checks']['f_room_cap_413_sender_not_retired_room_live'] = True

            # --- d: SIGKILL the relay; b:1 is offline across the restart.
            a1.post_ok('application', a1.call('encrypt', list(b'before kill')), 'before-kill')
            relay.sigkill()
            relay.start(app_event_ttl=1)  # same data dir; every application event is soon stale
            time.sleep(2.2)  # created_at is whole seconds
            expect(a2, 'before kill')
            a1.sync()
            b2.cursor = max([b2.cursor] + [ev['seq'] for ev in b2.raw_events(b2.cursor)['events']])
            a1.post_ok('application', a1.call('encrypt', list(b'after restart')), 'after-restart')  # prunes
            expect(b1, 'before kill', 'after restart')  # unread by b:1 -> must have survived
            receipt['checks']['d_sigkill_restart_cursor_resume_offline_unread_kept'] = True

            for device in [a2, b1]:
                device.sync()
            a1.sync()
            b2.raw_events(b2.cursor)
            before = [ev['seq'] for ev in a1.raw_events()['events'] if ev['kind'] == 'application']
            time.sleep(2.2)
            a1.post_ok('application', a1.call('encrypt', list(b'prune trigger')), 'prune-trigger')
            after = [ev['seq'] for ev in a1.raw_events()['events'] if ev['kind'] == 'application']
            assert len(after) == 1 and after[0] > max(before), (before, after)
            expect(a2, 'prune trigger')
            expect(b1, 'prune trigger')
            receipt['checks']['d_pruning_advances_once_every_known_reader_read'] = True
            receipt['pruned_application_events'] = len(before)

            receipt['wire_bytes'] = {'add_commit': add_sizes[0], 'welcome': add_sizes[1],
                                     'stale_app': len(stale), 'reencrypted_app': len(fresh)}
            for device in everyone:
                device.context.close()
            browser.close()
        receipt['passed'] = True
    finally:
        relay.stop()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        (evidence / 'verification.json').write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n')
        print(evidence / 'verification.json', flush=True)


if __name__ == '__main__':
    main()
