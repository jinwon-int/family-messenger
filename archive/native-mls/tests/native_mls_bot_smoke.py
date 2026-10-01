#!/usr/bin/env python3
"""M5 acceptance smoke (#177 §4): the native MLS bot as a third leaf.

Go v2 relay + two real browser contexts (a-1, b-1) + one bot process
(bot-1) in one MLS room, with the device policy chain ON (roster enforced on
every commit) but caller auth OFF (-access-mode disabled: the bot has no CF
Access identity yet — tracked as a separate ops task).

Proven here:
  b. bot publishes a key package; the browser creator consumes it and adds the
     bot in the room's CREATION commit (an actor roster seeds there, so a new
     actor must be in it), sends the targeted Welcome; the bot joins from it
     like any other leaf.
  c. text round-trips: a-1 → bot echo → b-1, b-1 → bot echo → a-1. The bot
     encrypts with client_id == its device identity (review H1: the pinless
     receivers enforce AAD client_id == MLS-authenticated sender device) and
     the browsers accept its messages — attribution holds for a non-browser
     leaf speaking the exact same facade.
  d. one 256 KiB attachment crosses as a single MLS application message in
     each direction (b-1 → bot → a-1); the wire cost is measured and reported
     (facade bound raised from 16 KiB this slice).
  e. negative control: the bot is told to watch a second room it is never
     invited to ('family-private'). It must never receive a Welcome, never
     join, never decrypt, and never POST there — the relay shows zero
     bot-authored events in that room.

Transport is the harness (python HTTP to the relay); MLS state lives in the
browser workers and in the bot process — same split as the v2 relay smoke.

Usage:
  python archive/native-mls/tests/native_mls_bot_smoke.py \
      --bundle artifacts/mls-pkg --relay-binary artifacts/native-mls-relay \
      --devices-binary artifacts/native-devices \
      --bot-binary archive/native-mls/bot/target/debug/native-mls-bot
"""
import argparse
import base64
import hashlib
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
PRIVATE = 'family-private'  # the room the bot must never enter
ATTACHMENT_BYTES = 262144  # the M5 acceptance bound: one 256 KiB attachment
CSP = ("default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; "
       "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")


# §3.6 binding frames: encrypt = u32 LE len ‖ room ‖ u32 LE len ‖ client ‖
# plaintext; decrypt = u32 LE len ‖ room ‖ ciphertext. The worker is a byte
# passthrough, so the harness frames per message (same as the relay smoke).
def bound(client, plaintext, room=ROOM):
    out = bytearray()
    for part in (room.encode(), client.encode()):
        out += len(part).to_bytes(4, 'little') + part
    return list(out + bytes(plaintext))


def sealed(ciphertext, room=ROOM):
    part = room.encode()
    return list(len(part).to_bytes(4, 'little') + part + bytes(ciphertext))


def b64(data):
    return base64.b64encode(bytes(data)).decode()


class Relay:
    """The v2 relay binary on a loopback port (policy on, caller auth off)."""

    def __init__(self, binary, data_dir, log_dir, device_state):
        self.binary, self.data_dir, self.log_dir = binary, data_dir, log_dir
        self.device_state = device_state
        self.proc = None

    def start(self):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]
        argv = [str(self.binary), '-addr', f'127.0.0.1:{self.port}', '-data-dir', str(self.data_dir),
                '-device-state', str(self.device_state), '-access-mode', 'disabled']
        log = open(self.log_dir / 'relay.log', 'wb')
        self.proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f'relay exited early: {(self.log_dir / "relay.log").read_text(errors="replace")[-800:]}')
            try:
                if self.http('GET', '/v2/health')[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.1)
        raise RuntimeError('relay health deadline')

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
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, json.loads(resp.read() or b'{}')
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read() or b'{}')


class Policy:
    """The owner CLI (native-devices) over one policy chain directory."""

    def __init__(self, binary, state_dir, work_dir):
        self.binary, self.state_dir, self.work_dir = binary, state_dir, work_dir
        self.revision = 0

    def run(self, args):
        run = subprocess.run([str(self.binary), '-device-state', str(self.state_dir), *args],
                             capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, (args, run.stderr)
        return json.loads(run.stdout)

    def mutate(self, args, expected):
        view = self.run([*args, '-expected-revision', str(expected)])
        assert view['revision'] == expected + 1, (args, view)
        self.revision = view['revision']
        return view

    def evidence_file(self, payload):
        path = self.work_dir / f'candidate-{secrets_hex()}.json'
        path.write_text(json.dumps(payload))
        path.chmod(0o600)
        return path


def secrets_hex():
    return os.urandom(6).hex()


class Bot:
    """The bot process; its stdout is a JSON-line protocol (session.rs)."""

    def __init__(self, binary, relay, room, device, watch_room):
        argv = [str(binary), f'http://127.0.0.1:{relay.port}', 'session', room, device, watch_room, '--watch']
        self.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lines = []
        self.lock = threading.Condition()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for raw in self.proc.stdout:
            try:
                line = json.loads(raw)
            except json.JSONDecodeError:
                line = {'event': 'bad_line', 'raw': raw.decode(errors='replace')}
            with self.lock:
                self.lines.append(line)
                self.lock.notify_all()

    def wait_for(self, predicate, timeout=60):
        deadline = time.monotonic() + timeout
        with self.lock:
            while True:
                for line in self.lines:
                    if predicate(line):
                        return line
                if self.proc.poll() is not None:
                    stderr = self.proc.stderr.read().decode(errors='replace')[-500:]
                    raise AssertionError(
                        f'bot exited {self.proc.returncode} while waiting; stderr: {stderr}; got {self.lines}')
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f'bot line timeout; got {self.lines}')
                self.lock.wait(remaining)

    def latest_status(self, room):
        with self.lock:
            statuses = [line for line in self.lines if line.get('event') == 'status']
        for line in reversed(statuses):
            for entry in line['rooms']:
                if entry['room'] == room:
                    return entry
        raise AssertionError(f'no bot status for {room}; got {self.lines}')

    def assert_clean(self):
        """No contract violations over the whole session."""
        with self.lock:
            lines = list(self.lines)
        bad = [line for line in lines if line.get('event') in
               ('bad_line', 'echo_dropped', 'undecryptable', 'echo_conflict')]
        assert not bad, bad
        return lines

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        stderr = self.proc.stderr.read().decode(errors='replace')
        assert 'panic' not in stderr, stderr[-800:]
        return self.proc.returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--relay-binary', required=True, type=Path)
    parser.add_argument('--devices-binary', required=True, type=Path)
    parser.add_argument('--bot-binary', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    repo = Path(__file__).resolve().parents[2]  # archive/
    (repo / 'artifacts').mkdir(mode=0o700, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='native-v2-bot-', dir=repo / 'artifacts'))
    paths = {'/': repo / 'experiments/openmls-browser/web/index.html'}
    for name in ['main.js', 'worker.js', 'durable-worker.js', 'enroll.js']:
        paths['/' + name] = repo / 'experiments/openmls-browser/web' / name
    for name in ['family_mls_browser_experiment.js', 'family_mls_browser_experiment_bg.wasm']:
        paths['/pkg/' + name] = args.bundle / name
    assets = {}
    for route, path in paths.items():
        st = path.lstat()
        if not path.is_file() or path.is_symlink() or st.st_nlink != 1 or st.st_size > 32 * 1024 * 1024:
            raise RuntimeError('unsafe or oversized asset')
        assets[route] = path.read_bytes()
    receipt = {'synthetic_only': True, 'durable_state': False,
               'transport': 'python harness HTTP to the v2 relay; MLS state in browser workers and the bot process',
               'relay_auth': 'device policy ON (-device-state): commits replicate the post-commit member list; '
                             'caller auth OFF (-access-mode disabled): the bot has no CF Access identity yet',
               'checks': {}, 'attachment': {}}

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
    threading.Thread(target=server.serve_forever, daemon=True).start()

    relay_dir = evidence / 'relay-data'
    policy_state = evidence / 'device-policy'
    policy_state.mkdir(mode=0o700)
    policy = Policy(args.devices_binary.resolve(), policy_state, evidence)
    view = policy.run(['-init'])
    assert view['revision'] == 1 and view['devices'] == [], view
    policy.revision = 1
    relay = Relay(args.relay_binary.resolve(), relay_dir, evidence, policy_state)

    def member_wire(devices):
        return [{'device': d, 'actor': d.split('-')[0]} for d in sorted(devices)]

    try:
        relay.start()
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            receipt['browser'] = browser.version

            class Browser:
                """A real chromium context doing MLS in its worker; per-room
                cursor/epoch/joined like a real multi-room client."""

                def __init__(self, dev):
                    self.dev = dev
                    self.context = browser.new_context()
                    self.page = self.context.new_page()
                    self.page.goto('http://' + expected_host)
                    # predicate must be a function: bare expressions are compiled
                    # by playwright into the page, where CSP blocks them.
                    self.page.wait_for_function('() => window.ready === true')
                    self.page.evaluate("spawn('main')")
                    self.cursor = {}
                    self.epoch = {}
                    self.joined = {}
                    self.serial = 0
                    self.call('init', dev)
                    self.key_hex = bytes(self.call('public_key')).hex()

                def call(self, method, argument=None):
                    value = self.page.evaluate('([m, a]) => call("main", m, a)', [method, argument])
                    assert value['ok'] is True, (self.dev, method, value)
                    return value.get('result')

                def client_id(self, label):
                    self.serial += 1
                    return f'{self.dev}-{self.serial}-{label}'

                def publish_key_package(self, room=ROOM):
                    package = self.call('key_package')
                    status, body = relay.http('POST', f'/v2/rooms/{room}/keypackages',
                                              {'device': self.dev, 'packages': [{'ref': 'kp-1', 'bytes': b64(package)}]})
                    assert status == 201, (self.dev, status, body)

                def post(self, kind, data, client_id, room, targets=None, members=None):
                    body = {'device': self.dev, 'client_id': client_id, 'kind': kind,
                            'epoch': self.epoch.get(room, 0), 'bytes': b64(data)}
                    if targets:
                        body['targets'] = targets
                    if members is not None:
                        body['members'] = members
                    return relay.http('POST', f'/v2/rooms/{room}/events', body)

                def post_ok(self, kind, data, label, room, targets=None, members=None):
                    status, body = self.post(kind, data, self.client_id(label), room, targets, members)
                    assert status == 201, (self.dev, kind, status, body)
                    self.epoch[room] = body['epoch']
                    return body

                def sync(self, room=ROOM):
                    """Apply the room's new events in total order; return the
                    application plaintexts decrypted along the way."""
                    status, body = relay.http('GET', f'/v2/rooms/{room}/events?device={self.dev}'
                                              f'&after={self.cursor.get(room, 0)}')
                    assert status == 200, (self.dev, room, status, body)
                    plain = []
                    for ev in body['events']:
                        self.cursor[room] = max(self.cursor.get(room, 0), ev['seq'])
                        if ev['device'] == self.dev:
                            # Own echo: MLS never processes own messages; our own
                            # commit echo is where the pending commit merges.
                            if ev['kind'] == 'commit' and self.joined.get(room) == 'pending':
                                self.call('merge_pending')
                                self.joined[room] = True
                            continue
                        data = list(base64.b64decode(ev['bytes']))
                        if not self.joined.get(room):
                            if ev['kind'] == 'welcome':
                                self.call('join', data)
                                self.joined[room] = True
                            continue  # pre-Welcome events are not ours to read
                        if ev['kind'] == 'commit':
                            self.call('commit', data)
                        elif ev['kind'] == 'welcome':
                            raise AssertionError(f'{self.dev} got a Welcome not targeted at it: {ev}')
                        else:
                            plain.append(bytes(self.call('decrypt', sealed(data, room=room))))
                    self.epoch[room] = body['epoch']
                    return plain

                def add(self, target, room, roster):
                    """Consume target's key package, commit the add, send the
                    targeted Welcome (the v2 relay invite flow)."""
                    status, kp = relay.http('GET', f'/v2/rooms/{room}/keypackages?device={target.dev}&consumer={self.dev}')
                    assert status == 200, (target.dev, status, kp)
                    framed = bytes(self.call('invite_with_commit', list(base64.b64decode(kp['bytes']))))
                    size = int.from_bytes(framed[:4], 'little')
                    commit, welcome = framed[4:4 + size], framed[4 + size:]
                    self.joined[room] = 'pending'
                    self.post_ok('commit', list(commit), f'add-{target.dev}', room, members=member_wire(roster))
                    plain = self.sync(room)
                    assert self.joined[room] is True, (self.dev, 'own commit echo not reached')
                    self.post_ok('welcome', list(welcome), f'welcome-{target.dev}', room, targets=[target.dev])
                    return plain

            a1, b1 = Browser('a-1'), Browser('b-1')

            # --- enrollment: one device per actor, owner CLI alone (no UI
            # --- approvals needed for first devices; the bot joins the same way).
            for dev_obj, actor in [(a1, 'a'), (b1, 'b')]:
                policy.mutate(['-enroll-first', '-input', str(policy.evidence_file(
                    {'device_id': dev_obj.dev, 'actor': actor, 'subject': f'person-{actor}',
                     'signing_key': dev_obj.key_hex}))], policy.revision)

            # --- the bot session starts before anyone invites it: it publishes
            # --- its key package and waits.
            bot = Bot(args.bot_binary, relay, ROOM, 'bot-1', PRIVATE)
            identity = bot.wait_for(lambda line: line.get('event') == 'identity')
            assert identity['room'] == ROOM and identity['watch_room'] == PRIVATE, identity
            policy.mutate(['-enroll-first', '-input', str(policy.evidence_file(
                {'device_id': 'bot-1', 'actor': 'bot', 'subject': 'person-bot',
                 'signing_key': identity['public_key']}))], policy.revision)
            ready = bot.wait_for(lambda line: line.get('event') == 'ready')
            assert ready['key_ref'], ready

            # --- b. creation commit: a-1 adds b-1 AND bot-1 in one commit — an
            # --- actor roster seeds from the room's first commit, so the bot's
            # --- new actor 'bot' must be in it — then one multi-target Welcome.
            b1.publish_key_package()
            a1.call('create')
            a1.joined[ROOM] = True
            roster = ['a-1', 'b-1', 'bot-1']
            status, kp_bot = relay.http('GET', f'/v2/rooms/{ROOM}/keypackages?device=bot-1&consumer=a-1')
            assert status == 200 and kp_bot['bytes'], (status, kp_bot)
            status, kp_b1 = relay.http('GET', f'/v2/rooms/{ROOM}/keypackages?device=b-1&consumer=a-1')
            assert status == 200 and kp_b1['bytes'], (status, kp_b1)
            both = base64.b64decode(kp_b1['bytes']) + base64.b64decode(kp_bot['bytes'])
            framed = bytes(a1.call('invite_with_commit', list(both)))
            size = int.from_bytes(framed[:4], 'little')
            commit, welcome = framed[4:4 + size], framed[4 + size:]
            a1.joined[ROOM] = 'pending'
            a1.post_ok('commit', list(commit), 'add-b1-bot', ROOM, members=member_wire(roster))
            a1.sync(ROOM)
            assert a1.joined[ROOM] is True, 'own commit echo not reached'
            a1.post_ok('welcome', list(welcome), 'welcome-b1-bot', ROOM, targets=['b-1', 'bot-1'])
            receipt['checks']['bot_added_in_creation_commit_and_welcomed'] = True

            plain = b1.sync()
            assert plain == [] and b1.joined.get(ROOM), (plain, b1.joined)
            assert b1.epoch[ROOM] == 1, b1.epoch
            joined = bot.wait_for(lambda line: line.get('event') == 'joined' and line.get('room') == ROOM)
            assert joined['epoch'] == 1, joined
            receipt['checks']['bot_joins_from_targeted_welcome'] = True

            # --- c. text round-trips through the bot's echo, both directions.
            text_a, text_b = '안녕 봇'.encode(), 'ping from b1'.encode()
            a1.post_ok('application', a1.call('encrypt', bound(a1.dev, list(text_a))), a1.client_id('t1'), ROOM)
            b1.post_ok('application', b1.call('encrypt', bound(b1.dev, list(text_b))), b1.client_id('t2'), ROOM)
            bot.wait_for(lambda line: line.get('event') == 'echo' and line.get('bytes') == len(text_a))
            bot.wait_for(lambda line: line.get('event') == 'echo' and line.get('bytes') == len(text_b))
            seen_b1 = b1.sync()
            assert seen_b1 == [text_a, text_a, text_b], seen_b1  # a-1's text, its echo, own echo
            seen_a1 = a1.sync()
            assert seen_a1 == [text_b, text_a, text_b], seen_a1  # b-1's text, echoes of both
            receipt['checks']['three_leaf_text_roundtrip_with_bot_echo'] = True

            # --- d. one 256 KiB attachment: b-1 → bot echo → a-1, in a single
            # --- MLS application message each hop.
            attachment = bytearray(os.urandom(ATTACHMENT_BYTES))
            ciphertext = bytes(b1.call('encrypt', bound(b1.dev, list(attachment))))
            assert len(ciphertext) > ATTACHMENT_BYTES, len(ciphertext)
            status, posted = relay.http('POST', f'/v2/rooms/{ROOM}/events',
                                        {'device': 'b-1', 'client_id': b1.client_id('attach'),
                                         'kind': 'application', 'epoch': b1.epoch[ROOM], 'bytes': b64(ciphertext)})
            assert status == 201, (status, posted)
            bot.wait_for(lambda line: line.get('event') == 'application' and line.get('bytes') == ATTACHMENT_BYTES)
            bot.wait_for(lambda line: line.get('event') == 'echo' and line.get('bytes') == ATTACHMENT_BYTES)
            echo_seen = a1.sync()
            assert echo_seen[-1] == bytes(attachment), 'a-1 must read the bot-echoed attachment byte-exact'
            assert a1.sync() == [], 'no duplicate delivery'
            receipt['attachment'] = {
                'plaintext': ATTACHMENT_BYTES,
                'browser_ciphertext': len(ciphertext),
                'mls_overhead': len(ciphertext) - ATTACHMENT_BYTES,
                'relay_event_b64_chars': len(b64(ciphertext)),
                'echo_verified_sha256': hashlib.sha256(echo_seen[-1]).hexdigest(),
            }
            receipt['checks']['attachment_256kib_single_mls_message_roundtrip'] = True

            # --- e. negative control: the bot watches a room it is never
            # --- invited to while its two members build it and talk inside.
            # --- Fresh browsers: one facade Device belongs to exactly one MLS
            # --- group, so a-1/b-1 cannot enter a second room (the same reason
            # --- the relay smoke uses fresh devices for its second room).
            c1, d1 = Browser('c-1'), Browser('d-1')
            for dev_obj, actor in [(c1, 'c'), (d1, 'd')]:
                policy.mutate(['-enroll-first', '-input', str(policy.evidence_file(
                    {'device_id': dev_obj.dev, 'actor': actor, 'subject': f'person-{actor}',
                     'signing_key': dev_obj.key_hex}))], policy.revision)
            d1.publish_key_package(PRIVATE)
            c1.call('create')
            c1.joined[PRIVATE] = True
            c1.add(d1, PRIVATE, ['c-1', 'd-1'])
            c1.post_ok('application', c1.call('encrypt', bound(c1.dev, list(b'private hello'), room=PRIVATE)),
                       c1.client_id('p1'), PRIVATE)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                time.sleep(0.3)
            private_view = relay.http('GET', f'/v2/rooms/{PRIVATE}/events?device=c-1&after=0')
            assert private_view[0] == 200 and private_view[1]['events'], private_view
            assert all(ev['device'] != 'bot-1' for ev in private_view[1]['events']), 'bot must never POST to the private room'
            watch = bot.latest_status(PRIVATE)
            assert watch['joined'] is False and watch['echoes'] == 0, watch
            main_room = bot.latest_status(ROOM)
            assert main_room['joined'] is True and main_room['echoes'] == 3, main_room
            receipt['checks']['uninvited_room_no_join_no_decrypt_no_posts'] = True

            lines = bot.assert_clean()
            bot.stop()
            receipt['bot_events'] = len(lines)
            receipt['checks']['bot_session_clean_exit'] = True
    finally:
        relay.stop()
        server.shutdown()

    out = evidence / 'verification.json'
    out.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n')
    print(out, flush=True)
    print(json.dumps(receipt['attachment'], indent=2), flush=True)


if __name__ == '__main__':
    main()
