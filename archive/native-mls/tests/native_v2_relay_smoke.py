#!/usr/bin/env python3
"""#177 M3c client smoke: enrolled browser MLS facade devices against the v2 relay.

Seven synthetic devices (a-1, a-2, a-3, b-1, b-2, c-1, c-2), each a memory-only
OpenMLS worker in its own browser context, exchange commits / targeted
Welcomes / application messages through the v2 relay binary
(archive/native-mls/server) over HTTP.

M3c enrollment switch: the relay runs WITH -device-state (policy v4 enforcement).
The policy chain is built through the real owner CLI (native-devices): E1
enroll-first for a-1 and b-1, then E2 add-device for a-2 and b-2 — where the
approval evidence is signed INSIDE the browser by the trusting device's facade
(Rust canonical bytes + "family-mls-v2/<action>\\0" domain separation) and
verified by the Go CLI against independently reconstructed payload bytes. The
fingerprint comparison runs through the page UI (new-device screen and
trusted-device screen); the real out-of-band comparison remains a human step.
Every commit POST replicates the post-commit member list (§3.3) and the sending
device verifies outer list == facade roster after merge. E2/E3 evidence, E4
revoke-all and the read-only old-room behavior are exercised at the end.

Scope, stated plainly: MLS state and every encrypt/decrypt/commit/join run in the
browser workers; the /v2 transport (fetch, cursors, retry decisions) is this Python
harness. Only synthetic bytes.

Caller identity (#177 review C1): the relay runs in -access-mode required. This
harness stands in for Cloudflare Access with one ES256 key published as a JWKS
file; every request carries Cf-Access-Jwt-Assertion minted for the SUBJECT of the
device it acts as (sub = the device's policy `subject`, "person-<actor>"). The
relay binds the claimed device id to that subject: no token is 401, a token for
another person, an unknown device or a revoked device is one 403
device_subject_mismatch — on GET as well, so the revoked-device checks below are
identity checks, not the old POST-only policy deny.

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
  h  revoke a-2 plainly: it is E2-enrolled, so its approval evidence was written
     once at enrollment and a signed -input revoke is REFUSED; every request of
     the revoked device (both POST kinds and GET) is 403 device_subject_mismatch
     at the identity binding; the MLS removal moves the others to a new epoch and
     the revoked device cannot decrypt it
  i  total device loss: E4 revoke-all locks a-1; a replacement device only gets
     in through E1 (unknown before that: 403 device_subject_mismatch), finds the
     old room read-only (commit 403 commit_sender_not_member, history
     undecryptable) and creates a new room instead. E3 the other way round:
     actor c exists for exactly this — c-1 is E1-enrolled with no evidence yet,
     c-2 joins through E2, and then c-1 IS revoked with evidence signed by c-2;
     approved_by is written exactly once, at revoke time
  j  caller identity: no token 401; a token of another person acting as a-1 403
     device_subject_mismatch; /close by a non-member 403 not_a_member, by a
     member 200 and the room answers 410 afterwards
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from playwright.sync_api import sync_playwright

ROOM = 'family'
ROOM2 = 'family-2'  # the replacement room after total device loss (phase i)
BIG_PLAINTEXT = 12000  # < the facade's 16 KiB plaintext bound
CSP = ("default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; "
       "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")


# §3.6 binding frames (M4): the main worker is a byte passthrough, so this driver
# frames per message. encrypt = u32 LE len ‖ room ‖ u32 LE len ‖ client ‖ plaintext;
# decrypt = u32 LE len ‖ room ‖ ciphertext.
def bound(client, plaintext, room=ROOM):
    out = bytearray()
    for part in (room.encode(), client.encode()):
        out += len(part).to_bytes(4, 'little') + part
    return list(out + bytes(plaintext))


def sealed(ciphertext, room=ROOM):
    part = room.encode()
    return list(len(part).to_bytes(4, 'little') + part + bytes(ciphertext))


def b64url(data):
    return base64.urlsafe_b64encode(bytes(data)).rstrip(b'=').decode()


class Access:
    """Stand-in for Cloudflare Access: one ES256 key, the JWKS file the relay is
    pointed at (-access-jwks), and per-subject JWT minting with the claims the
    relay verifies (iss, aud, sub, exp/nbf). The private key never leaves this
    process; the relay only ever sees the public JWKS."""

    ISSUER = 'https://family-smoke.cloudflareaccess.com'
    AUDIENCE = 'native-mls-v2-relay-smoke'
    KID = 'smoke-es256'

    def __init__(self, work_dir):
        self.key = ec.generate_private_key(ec.SECP256R1())
        numbers = self.key.public_key().public_numbers()
        jwks = {'keys': [{'kty': 'EC', 'crv': 'P-256', 'kid': self.KID, 'alg': 'ES256', 'use': 'sig',
                          'x': b64url(numbers.x.to_bytes(32, 'big')), 'y': b64url(numbers.y.to_bytes(32, 'big'))}]}
        self.jwks_path = work_dir / 'access-jwks.json'
        self.jwks_path.write_text(json.dumps(jwks))
        self.jwks_path.chmod(0o600)

    def token(self, subject, ttl=600):
        now = int(time.time())
        header = {'alg': 'ES256', 'typ': 'JWT', 'kid': self.KID}
        claims = {'iss': self.ISSUER, 'aud': [self.AUDIENCE], 'sub': subject, 'iat': now, 'nbf': now, 'exp': now + ttl}
        signing_input = b64url(json.dumps(header).encode()) + '.' + b64url(json.dumps(claims).encode())
        r, s = decode_dss_signature(self.key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256())))
        return signing_input + '.' + b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))


class Relay:
    """The v2 relay binary on a loopback port; restartable over one data dir."""

    def __init__(self, binary, data_dir, log_dir, room_bytes_cap, device_state, access):
        self.binary, self.data_dir, self.log_dir = binary, data_dir, log_dir
        self.room_bytes_cap, self.device_state, self.access = room_bytes_cap, device_state, access
        self.proc = None
        self.starts = 0

    def start(self, app_event_ttl=None):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]
        argv = [str(self.binary), '-addr', f'127.0.0.1:{self.port}', '-data-dir', str(self.data_dir),
                '-room-bytes-cap', str(self.room_bytes_cap), '-device-state', str(self.device_state),
                '-access-mode', 'required', '-access-issuer', Access.ISSUER,
                '-access-audience', Access.AUDIENCE, '-access-jwks', str(self.access.jwks_path)]
        if app_event_ttl is not None:
            argv += ['-app-event-ttl-seconds', str(app_event_ttl)]
        self.starts += 1
        log = open(self.log_dir / f'relay-{self.starts}.log', 'wb')
        self.proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f'relay exited early: {self.returncode_log()}')
            try:
                if self.http('GET', '/v2/health')[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.1)
        raise RuntimeError('relay health deadline')

    def returncode_log(self):
        tail = ''
        try:
            tail = (self.log_dir / f'relay-{self.starts}.log').read_text(errors='replace')[-800:]
        except OSError:
            pass
        return f'{self.proc.returncode}: {tail}'

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

    def http(self, method, path, body=None, subject=None):
        """One request; subject selects whose CF Access assertion travels with it
        (None = no token, which every contract route must answer with 401)."""
        data = None if body is None else json.dumps(body).encode()
        headers = {'Content-Type': 'application/json'} if data else {}
        if subject is not None:
            headers['Cf-Access-Jwt-Assertion'] = self.access.token(subject)
        req = urllib.request.Request(f'http://127.0.0.1:{self.port}{path}', data=data, method=method,
                                     headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
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

    def refuse(self, args, expected):
        """A mutation that must be rejected; returns stderr for message matching."""
        run = subprocess.run([str(self.binary), '-device-state', str(self.state_dir), *args,
                              '-expected-revision', str(expected)],
                             capture_output=True, text=True, timeout=30)
        assert run.returncode != 0, (args, run.stdout)
        return run.stderr

    def mutate(self, args, expected):
        """One CAS mutation; asserts the chain advanced by exactly one revision."""
        view = self.run([*args, '-expected-revision', str(expected)])
        assert view['revision'] == expected + 1, (args, view)
        self.revision = view['revision']
        return view

    def evidence_file(self, payload):
        """Private candidate file (0600 in this 0700 dir), as the CLI requires."""
        path = self.work_dir / f'candidate-{secrets.token_hex(6)}.json'
        path.write_text(json.dumps(payload))
        path.chmod(0o600)
        return path


def b64(data):
    return base64.b64encode(bytes(data)).decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--relay-binary', required=True, type=Path)
    parser.add_argument('--devices-binary', required=True, type=Path)
    parser.add_argument('--room-bytes-cap', type=int, default=64 * 1024)
    args = parser.parse_args()
    os.umask(0o077)
    repo = Path(__file__).resolve().parents[2]  # archive/
    (repo / 'artifacts').mkdir(mode=0o700, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='native-v2-relay-', dir=repo / 'artifacts'))
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
    receipt = {'synthetic_only': True, 'durable_state': False, 'checks': {},
               'transport': 'python harness HTTP to the v2 relay; MLS state and operations in browser workers',
               'relay_auth': 'CF Access stand-in: ES256 JWT per request (Cf-Access-Jwt-Assertion), sub bound to the '
                             'device policy subject of the claimed device; device policy v4 via -device-state: '
                             'active devices only, commits must replicate the post-commit member list',
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
    policy_state = evidence / 'device-policy'
    policy_state.mkdir(mode=0o700)
    policy = Policy(args.devices_binary.resolve(), policy_state, evidence)
    # -init BEFORE the relay starts: the relay replays the chain at startup and
    # fails closed when it cannot (empty dir = "unreadable").
    view = policy.run(['-init'])
    assert view['revision'] == 1 and view['devices'] == [], view
    policy.revision = 1
    access = Access(evidence)
    relay = Relay(args.relay_binary.resolve(), relay_dir / 'data', evidence, args.room_bytes_cap, policy_state, access)
    try:
        relay.start()  # default app-event TTL (30 days): no time-based pruning before phase d
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            receipt['browser'] = browser.version

            rosters = {ROOM: ['a-1'], ROOM2: []}

            def member_wire(devices):
                return [{'device': d, 'actor': d.split('-')[0]} for d in sorted(devices)]

            def subject_of(dev):
                """The policy `subject` every device of an actor is enrolled with — the
                CF Access sub of that person; the JWT for a device carries exactly it."""
                return f"person-{dev.split('-')[0]}"

            class Device:
                def __init__(self, dev):
                    self.dev = dev
                    self.subject = subject_of(dev)
                    self.context = browser.new_context()
                    self.page = self.context.new_page()
                    self.page.goto('http://' + expected_host)
                    # predicate는 반드시 () => ... 형태: bare expression은 playwright가
                    # 페이지 eval로 컴파일해 이 CSP(script-src 'self' 'wasm-unsafe-eval')에 막힌다.
                    self.page.wait_for_function('() => window.ready === true')
                    self.page.evaluate("spawn('main')")
                    self.cursor = 0
                    self.joined = False
                    self.pending = False  # a commit we created, not yet merged
                    self.epoch = 0
                    self.serial = 0
                    self.call('init', dev)
                    # Enrollment hands the owner the Ed25519 PUBLIC key (DEVICES-V4.md
                    # signing_key column); the fingerprint is sha256 of these bytes.
                    self.key_hex = bytes(self.call('public_key')).hex()
                    # 새 기기 화면: every device renders its own fingerprint for the
                    # out-of-band comparison; the harness only checks renderability here.
                    self.page.evaluate(f"window.enroll.show_own('{dev}')")
                    self.page.wait_for_function(
                        "() => document.getElementById('own-fingerprint').textContent.length === 64")

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

                def post(self, kind, data, client_id, epoch=None, targets=None, members=None, room=ROOM):
                    body = {'device': self.dev, 'client_id': client_id, 'kind': kind,
                            'epoch': self.epoch if epoch is None else epoch, 'bytes': b64(data)}
                    if targets:
                        body['targets'] = targets
                    if members is not None:
                        body['members'] = members
                    return relay.http('POST', f'/v2/rooms/{room}/events', body, subject=self.subject)

                def post_ok(self, kind, data, label, targets=None, members=None, room=ROOM):
                    status, body = self.post(kind, data, self.client_id(label), targets=targets,
                                             members=members, room=room)
                    assert status == 201, (self.dev, kind, status, body)
                    self.epoch = body['epoch']
                    return body

                def raw_events(self, after=0, room=ROOM):
                    status, body = relay.http('GET', f'/v2/rooms/{room}/events?device={self.dev}&after={after}',
                                              subject=self.subject)
                    assert status == 200, (self.dev, status, body)
                    return body

                def members(self, room=ROOM):
                    """The facade roster, parsed from the framed members() output."""
                    framed = bytes(self.call('members'))
                    count = int.from_bytes(framed[:4], 'little')
                    at, out = 4, []
                    for _ in range(count):
                        length = int.from_bytes(framed[at:at + 4], 'little')
                        at += 4
                        identity = framed[at:at + length].decode()
                        at += length + 32
                        out.append(identity)
                    assert at == len(framed), (self.dev, 'members frame trailing bytes')
                    return out

                def sync(self, room=ROOM):
                    """Apply every new event in total order; return decrypted application plaintexts."""
                    body = self.raw_events(self.cursor, room)
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
                            plain.append(bytes(self.call('decrypt', sealed(data, room=room))))
                    self.epoch = body['epoch']
                    return plain

                def publish_key_package(self, room=ROOM):
                    package = self.call('key_package')
                    status, body = relay.http('POST', f'/v2/rooms/{room}/keypackages',
                                              {'device': self.dev, 'packages': [{'ref': 'kp-1', 'bytes': b64(package)}]},
                                              subject=self.subject)
                    assert status == 201, (self.dev, status, body)

                def commit_ok(self, commit, label, devices, room=ROOM):
                    """POST a pending commit with the replicated member list; on 201
                    catch up to it (merging there) and verify §3.3: the outer list the
                    relay enforced equals the post-commit MLS roster the facade sees."""
                    expected = member_wire(devices)
                    self.pending = True
                    self.post_ok('commit', commit, label, members=expected, room=room)
                    plain = self.sync(room)
                    assert not self.pending, (self.dev, 'own commit not reached')
                    assert sorted(self.members(room)) == sorted(w['device'] for w in expected), \
                        (self.dev, 'outer member list disagrees with the facade roster')
                    return plain

                def add(self, target, room=ROOM):
                    """Consume target's KeyPackage, commit the add, send the targeted Welcome."""
                    status, kp = relay.http('GET', f'/v2/rooms/{room}/keypackages?device={target.dev}&consumer={self.dev}',
                                            subject=self.subject)  # the consumer is the bound identity
                    assert status == 200, (target.dev, status, kp)
                    framed = bytes(self.call('invite_with_commit', list(base64.b64decode(kp['bytes']))))
                    size = int.from_bytes(framed[:4], 'little')
                    commit, welcome = framed[4:4 + size], framed[4 + size:]
                    plain = self.commit_ok(commit, 'add-' + target.dev, rosters[room] + [target.dev], room)
                    rosters[room] = sorted(rosters[room] + [target.dev])
                    self.post_ok('welcome', welcome, 'welcome-' + target.dev, targets=[target.dev], room=room)
                    return len(commit), len(welcome), plain

            def expect(device, *messages):
                got = device.sync()
                assert got == [m.encode() for m in messages], (device.dev, got, messages)

            devices = {}
            a1, a2, b1, b2 = (Device(d) for d in ['a-1', 'a-2', 'b-1', 'b-2'])
            devices.update({'a-1': a1, 'a-2': a2, 'b-1': b1, 'b-2': b2})
            everyone = [a1, a2, b1, b2]

            # --- enrollment: policy chain via the owner CLI (chain -init'd before
            # --- the relay started); E2 approvals signed in the browser (Rust
            # --- canonical bytes, verified by the Go CLI).
            for first in ['a-1', 'b-1']:
                actor = first.split('-')[0]
                policy.mutate(['-enroll-first', '-input', str(policy.evidence_file(
                    {'device_id': first, 'actor': actor, 'subject': f'person-{actor}',
                     'signing_key': devices[first].key_hex}))], policy.revision)

            def approve_via_ui(approver, candidate, base_revision):
                """The trusted-device screen: fingerprint rendered, compared (synthetic
                here, human in real life), denied once to prove the gate, then approved.
                Returns the evidence the harness hands to the owner CLI."""
                offer = {'device_id': candidate.dev, 'actor': candidate.dev.split('-')[0],
                         'subject': f"person-{candidate.dev.split('-')[0]}",
                         'signing_key': candidate.key_hex, 'base_revision': base_revision}
                shown = candidate.page.eval_on_selector('#own-fingerprint', 'el => el.textContent')
                assert hashlib.sha256(bytes.fromhex(candidate.key_hex)).hexdigest() == shown, \
                    'new-device screen must show sha256(signing key)'
                approver.page.evaluate('c => window.enroll.offer(c)', offer)
                approver.page.wait_for_function(
                    "() => document.getElementById('candidate-fingerprint').textContent.length === 64")
                rendered = approver.page.eval_on_selector('#candidate-fingerprint', 'el => el.textContent')
                assert rendered == shown, 'the two screens must show the identical fingerprint'
                approver.page.click('#deny')
                approver.page.wait_for_function('() => window.enroll.denied === true')
                assert approver.page.evaluate('window.enroll.evidence') is None, 'deny must not sign'
                approver.page.evaluate('c => window.enroll.offer(c)', offer)
                approver.page.click('#approve')
                approver.page.wait_for_function('() => window.enroll.evidence !== null')
                return approver.page.evaluate('window.enroll.evidence')

            evidence_a2 = approve_via_ui(a1, a2, policy.revision)
            view = policy.mutate(['-add-device', '-input', str(policy.evidence_file(
                {'device_id': 'a-2', 'actor': 'a', 'subject': 'person-a', 'signing_key': a2.key_hex,
                 'base_revision': policy.revision, 'signature': evidence_a2['signature']}))], policy.revision)
            by_id = {d['device_id']: d for d in view['devices']}
            assert by_id['a-2']['status'] == 'active' and by_id['a-2']['device_revision'] == 1, view
            assert by_id['a-2']['approved_by']['device_id'] == 'a-1', view
            assert by_id['a-2']['fingerprint'] == evidence_a2['fingerprint'] == \
                hashlib.sha256(bytes.fromhex(a2.key_hex)).hexdigest(), 'fingerprint agreement'
            receipt['checks']['e2_rust_approval_bytes_verified_by_go_cli'] = True
            receipt['checks']['fingerprint_screens_agree_with_cli_fingerprint'] = True

            evidence_b2 = approve_via_ui(b1, b2, policy.revision)
            policy.mutate(['-add-device', '-input', str(policy.evidence_file(
                {'device_id': 'b-2', 'actor': 'b', 'subject': 'person-b', 'signing_key': b2.key_hex,
                 'base_revision': policy.revision, 'signature': evidence_b2['signature']}))], policy.revision)
            receipt['checks']['policy_chain_enrolled_four_devices'] = True

            # --- group setup: a-1 creates; a-1 adds b-1, then its own second device a-2.
            for device in [a2, b1, b2]:
                device.publish_key_package()
            a1.call('create')
            a1.joined = True
            add_commit_size, welcome_size, _ = a1.add(b1)
            b1.sync()
            assert b1.joined and b1.epoch == 1
            a1.post_ok('application', a1.call('encrypt', bound(a1.dev, list(b'hello b1'))), 'm')
            expect(b1, 'hello b1')
            a1.add(a2)
            expect(b1)  # b-1 applies the a-2 add commit; the a-2 Welcome must not reach it
            a2.sync()
            assert a2.joined and a2.epoch == b1.epoch == a1.epoch == 2
            receipt['checks']['n_member_group_via_commit_and_targeted_welcome'] = True

            # --- j (part 1): caller identity. No token is 401 on every contract
            # --- route; person-b's token acting as a-1 is one 403 that does not say why.
            for method, path, body in [('GET', f'/v2/rooms/{ROOM}/events?device=a-1', None),
                                       ('POST', f'/v2/rooms/{ROOM}/events', {'device': 'a-1', 'client_id': 'a1-no-token',
                                                                              'kind': 'application', 'epoch': a1.epoch,
                                                                              'bytes': b64(b'x')}),
                                       ('GET', f'/v2/rooms/{ROOM}/keypackages?device=b-1&consumer=a-1', None),
                                       ('POST', f'/v2/rooms/{ROOM}/close?device=a-1', None)]:
                status, body = relay.http(method, path, body)
                assert status == 401 and body == {'error': 'unauthorized'}, (method, path, status, body)
            status, body = relay.http('GET', f'/v2/rooms/{ROOM}/events?device=a-1', subject='person-b')
            assert status == 403 and body == {'error': 'device_subject_mismatch'}, (status, body)
            status, body = relay.http('POST', f'/v2/rooms/{ROOM}/events',
                                      {'device': 'a-1', 'client_id': 'a1-foreign-subject', 'kind': 'application',
                                       'epoch': a1.epoch, 'bytes': b64(b'never stored')}, subject='person-b')
            assert status == 403 and body == {'error': 'device_subject_mismatch'}, (status, body)
            assert all(ev['client_id'] != 'a1-foreign-subject' for ev in a1.raw_events()['events']), 'denied POST must not land'
            receipt['checks']['j_no_token_401_every_route'] = True
            receipt['checks']['j_foreign_subject_403_device_subject_mismatch'] = True

            # --- a: stale-epoch application -> 409 -> apply commit -> re-encrypt -> 201.
            stale_plain = list('epoch-2 draft 재암호화'.encode())
            stale = a1.call('encrypt', bound(a1.dev, stale_plain))
            stale_id = a1.client_id('stale')
            _, _, _ = b1.add(b2)  # any member commits (not only the creator); room -> epoch 3
            status, body = a1.post('application', stale, stale_id)
            assert status == 409 and body['error'] == 'cas_mismatch' and body['epoch'] == 3, (status, body)
            assert a1.sync() == []  # applies b-1's commit; b-2's Welcome is filtered
            assert a1.epoch == 3
            fresh = a1.call('encrypt', bound(a1.dev, stale_plain))
            status, body = a1.post('application', fresh, stale_id)  # the 409'd id was never stored
            assert status == 201 and body['epoch'] == 3, (status, body)
            # b-2 joins from b-1's Welcome (a non-creator Welcome must carry the tree)
            # and, in the same pass, reads the re-encrypted epoch-3 message.
            assert b2.sync() == [bytes(stale_plain)] and b2.joined
            for device in [a2, b1]:
                assert device.sync() == [bytes(stale_plain)], device.dev
            receipt['checks']['a_stale_epoch_409_apply_commit_reencrypt_delivered_once'] = True

            # --- b: lost response -> byte-equal retry after a concurrent commit -> 200 duplicate,
            # --- g: commit race: a-1 and b-1 both commit b-2's removal at epoch 3.
            lost = a2.call('encrypt', bound(a2.dev, list(b'lost response')))
            lost_id = a2.client_id('lost')
            status, first = a2.post('application', lost, lost_id)
            assert status == 201, (status, first)  # ...and the response is "lost"
            b2_key = bytes.fromhex(b2.key_hex)
            losing = a1.call('remove_pending', list(b2_key))
            winning = b1.call('remove_pending', list(b2_key))
            # b-1 wins; the relay ordered a-2's epoch-3 message BEFORE b-1's commit, so b-1
            # must read it at epoch 3 and only then merge (deferred merge). The removal
            # commit's OUTER member list is the post-commit roster, so retire b-2 first.
            rosters[ROOM].remove('b-2')
            assert b1.commit_ok(winning, 'remove-b2', rosters[ROOM]) == [b'lost response']
            assert b1.epoch == 4
            status, body = a1.post('commit', losing, a1.client_id('remove-b2'),
                                   members=member_wire(rosters[ROOM]))
            assert status == 409 and body['error'] == 'cas_mismatch' and body['epoch'] == 4, (status, body)
            a1.call('clear_pending')  # stay at epoch 3, catch up, and find the goal already met
            expect(a1, 'lost response')
            assert a1.epoch == 4
            receipt['checks']['g_commit_race_loser_409_clear_pending_catch_up'] = True
            receipt['checks']['committer_reads_events_ordered_before_its_commit'] = True
            status, retry = a2.post('application', lost, lost_id, epoch=3)
            assert status == 200 and retry['duplicate'] is True and retry['seq'] == first['seq'], (status, retry)
            receipt['checks']['b_lost_response_retry_after_commit_is_200_duplicate'] = True

            # b-2 reads the message sent before its removal, then applies its own removal.
            expect(b2, 'lost response')
            assert a2.sync() == [] and a2.epoch == 4

            # --- c: same client_id, different bytes -> 409 client_id_reuse; sender keeps going.
            other = a2.call('encrypt', bound(a2.dev, list(b'different bytes')))
            status, body = a2.post('application', other, lost_id)
            assert status == 409 and body['error'] == 'client_id_reuse', (status, body)
            a2.post_ok('application', a2.call('encrypt', bound(a2.dev, list(b'after reuse'))), 'after-reuse')
            expect(a1, 'after reuse')
            expect(b1, 'after reuse')
            receipt['checks']['c_client_id_reuse_409_sender_not_retired_gap_tolerated'] = True
            removed_view = b2.raw_events(b2.cursor)
            b2.cursor = max([b2.cursor] + [ev['seq'] for ev in removed_view['events']])
            [after_removal] = [ev for ev in removed_view['events'] if ev['kind'] == 'application']
            b2.call('decrypt', sealed(base64.b64decode(after_removal['bytes'])), reject=True)
            receipt['checks']['removed_device_cannot_read_next_epoch'] = True

            # --- e: every Welcome reached exactly its target and nobody else.
            welcomes = {d.dev: sum(ev['kind'] == 'welcome' for ev in d.raw_events()['events']) for d in everyone}
            assert welcomes == {'a-1': 0, 'a-2': 1, 'b-1': 1, 'b-2': 1}, welcomes
            receipt['checks']['e_targeted_welcome_filtered_for_every_non_target'] = True
            receipt['welcomes_visible'] = welcomes

            # --- f: room byte cap 413; the sender is not retired and the room stays live.
            big_sent = []
            for i in range(32):
                big = a1.call('encrypt', bound(a1.dev, list(bytes([i]) * BIG_PLAINTEXT)))
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
            a1.post_ok('application', a1.call('encrypt', bound(a1.dev, list(b'after cap'))), 'after-cap')
            for device in [a2, b1]:
                assert device.sync() == big_sent + [b'after cap'], device.dev
            receipt['checks']['f_room_cap_413_sender_not_retired_room_live'] = True

            # --- d: SIGKILL the relay; b-1 is offline across the restart.
            a1.post_ok('application', a1.call('encrypt', bound(a1.dev, list(b'before kill'))), 'before-kill')
            relay.sigkill()
            relay.start(app_event_ttl=1)  # same data dir; every application event is soon stale
            time.sleep(2.2)  # created_at is whole seconds
            expect(a2, 'before kill')
            a1.sync()
            b2.cursor = max([b2.cursor] + [ev['seq'] for ev in b2.raw_events(b2.cursor)['events']])
            a1.post_ok('application', a1.call('encrypt', bound(a1.dev, list(b'after restart'))), 'after-restart')  # prunes
            expect(b1, 'before kill', 'after restart')  # unread by b-1 -> must have survived
            receipt['checks']['d_sigkill_restart_cursor_resume_offline_unread_kept'] = True

            # Reads prune too now (H2): once every known reader has passed a stale
            # event, the read that moved the minimum cursor reclaims it, so `before`
            # may already be shorter than the two messages above. The invariant is
            # that after the trigger exactly one application event remains and it
            # is newer than everything that was there before.
            for device in [a2, b1]:
                device.sync()
            a1.sync()
            b2.raw_events(b2.cursor)
            before = [ev['seq'] for ev in a1.raw_events()['events'] if ev['kind'] == 'application']
            time.sleep(2.2)
            a1.post_ok('application', a1.call('encrypt', bound(a1.dev, list(b'prune trigger'))), 'prune-trigger')
            after = [ev['seq'] for ev in a1.raw_events()['events'] if ev['kind'] == 'application']
            assert len(after) == 1 and all(seq < after[0] for seq in before), (before, after)
            expect(a2, 'prune trigger')
            expect(b1, 'prune trigger')
            receipt['checks']['d_pruning_advances_once_every_known_reader_read'] = True
            receipt['pruned_application_events'] = len(before)

            # --- h: revoke a-2 plainly. It is E2-enrolled: its approval evidence was
            # --- written once at enrollment, so a signed -input revoke is refused
            # --- (the one-time-evidence gate). Every request of a-2 is then cut at
            # --- the identity binding (its subject is still person-a, the device is
            # --- no longer active): both POST kinds AND GET are 403; the MLS removal
            # --- moves the survivors to a new epoch a-2 cannot decrypt.
            ev = a1.call('sign_approval', {'action': 'revoke-device', 'device_id': 'a-2', 'actor': 'a',
                                           'subject': 'person-a', 'signing_key': a2.key_hex,
                                           'acceptance': 'trusted-device-fingerprint',
                                           'base_revision': policy.revision})
            canonical_len = int.from_bytes(ev[:4], 'little')
            revoke_evidence = {'action': 'revoke-device', 'device_id': 'a-2',
                               'base_revision': policy.revision, 'signature': bytes(ev[4 + canonical_len:]).hex()}
            stderr = policy.refuse(['-revoke', 'a-2', '-input', str(policy.evidence_file(revoke_evidence))],
                                   policy.revision)
            assert 'plain revoke only' in stderr, stderr
            receipt['checks']['h_e2_signed_revoke_refused_evidence_written_once'] = True
            view = policy.mutate(['-revoke', 'a-2'], policy.revision)
            by_id = {d['device_id']: d for d in view['devices']}
            assert by_id['a-2']['status'] == 'revoked' and by_id['a-2']['approved_by']['device_id'] == 'a-1', view
            status, body = a2.post('application', a2.call('encrypt', bound(a2.dev, list(b'still here?'))), a2.client_id('revoked'))
            assert status == 403 and body == {'error': 'device_subject_mismatch'}, (status, body)
            status, body = relay.http('POST', f'/v2/rooms/{ROOM}/keypackages',
                                      {'device': 'a-2', 'packages': [{'ref': 'kp-x', 'bytes': b64(a2.call('key_package'))}]},
                                      subject=a2.subject)
            assert status == 403 and body == {'error': 'device_subject_mismatch'}, (status, body)
            status, body = relay.http('GET', f'/v2/rooms/{ROOM}/events?device=a-2&after={a2.cursor}', subject=a2.subject)
            assert status == 403 and body == {'error': 'device_subject_mismatch'}, (status, body)
            receipt['checks']['h_revoked_device_403_post_both_kinds_and_get'] = True

            removal = a1.call('remove_pending', list(bytes.fromhex(a2.key_hex)))
            rosters[ROOM].remove('a-2')  # outer list = post-commit roster (§3.3)
            a1.commit_ok(removal, 'remove-a2', rosters[ROOM])
            a1.post_ok('application', a1.call('encrypt', bound(a1.dev, list(b'after revoke'))), 'post-revoke')
            after_revoke_feed = a1.raw_events(a1.cursor)  # a-1's own new-epoch message, read through a-1's identity
            expect(b1, 'after revoke')  # b-1 merges the removal commit, then reads the new-epoch message
            assert a1.epoch == b1.epoch and a1.epoch > 4
            # a-2 can no longer read the feed at all, so it never sees its removal; the
            # message of the epoch it is no longer part of is undecryptable to it.
            [after_revoke] = [event for event in after_revoke_feed['events'] if event['kind'] == 'application']
            a2.call('decrypt', sealed(base64.b64decode(after_revoke['bytes'])), reject=True)
            receipt['checks']['h_revoked_device_cannot_read_new_epoch'] = True

            # --- i: total device loss. E4 locks every a: device; the replacement only
            # --- gets in through E1 and finds the old room read-only.
            view = policy.mutate(['-revoke-all', 'a'], policy.revision)
            assert all(d['status'] == 'revoked' for d in view['devices'] if d['actor'] == 'a'), view
            status, body = a1.post('application', a1.call('encrypt',
                                   bound(a1.dev, list(b'lost everything'))),
                                   a1.client_id('lost-all'))
            assert status == 403 and body == {'error': 'device_subject_mismatch'}, (status, body)
            receipt['checks']['i_revoke_all_locks_every_lost_device'] = True

            a3 = Device('a-3')
            status, body = a3.post('application', list(b'unknown device'),  # synthetic: cut at the identity binding, pre-MLS
                                   a3.client_id('pre-enroll'))
            assert status == 403 and body == {'error': 'device_subject_mismatch'}, (status, body)
            receipt['checks']['i_unknown_device_post_403'] = True
            view = policy.mutate(['-enroll-first', '-input', str(policy.evidence_file(
                {'device_id': 'a-3', 'actor': 'a', 'subject': 'person-a', 'signing_key': a3.key_hex}))],
                policy.revision)
            by_id = {d['device_id']: d for d in view['devices']}
            assert by_id['a-3']['acceptance'] == 'out-of-band-fingerprint' and 'approved_by' not in by_id['a-3'], view
            assert by_id['a-3']['fingerprint'] == hashlib.sha256(bytes.fromhex(a3.key_hex)).hexdigest()

            # E3 the other way round: a REVOKED-eligible E1 device. enroll-first only
            # applies to an actor's first device, so actor c exists for exactly this:
            # c-1 holds no evidence, c-2 joins through E2 (c-1 approves in the UI),
            # then c-2 signs c-1's revoke and the CLI writes approved_by exactly once.
            c1, c2 = Device('c-1'), Device('c-2')
            view = policy.mutate(['-enroll-first', '-input', str(policy.evidence_file(
                {'device_id': 'c-1', 'actor': 'c', 'subject': 'person-c', 'signing_key': c1.key_hex}))],
                policy.revision)
            by_id = {d['device_id']: d for d in view['devices']}
            assert by_id['c-1']['status'] == 'active' and 'approved_by' not in by_id['c-1'], view
            evidence_c2 = approve_via_ui(c1, c2, policy.revision)
            view = policy.mutate(['-add-device', '-input', str(policy.evidence_file(
                {'device_id': 'c-2', 'actor': 'c', 'subject': 'person-c', 'signing_key': c2.key_hex,
                 'base_revision': policy.revision, 'signature': evidence_c2['signature']}))], policy.revision)
            ev = c2.call('sign_approval', {'action': 'revoke-device', 'device_id': 'c-1', 'actor': 'c',
                                           'subject': 'person-c', 'signing_key': c1.key_hex,
                                           'acceptance': 'out-of-band-fingerprint',
                                           'base_revision': policy.revision})
            canonical_len = int.from_bytes(ev[:4], 'little')
            revoke_evidence = {'action': 'revoke-device', 'device_id': 'c-1',
                               'base_revision': policy.revision, 'signature': bytes(ev[4 + canonical_len:]).hex()}
            view = policy.mutate(['-revoke', 'c-1', '-input', str(policy.evidence_file(revoke_evidence))],
                                 policy.revision)
            by_id = {d['device_id']: d for d in view['devices']}
            assert by_id['c-1']['status'] == 'revoked' and by_id['c-1']['approved_by']['device_id'] == 'c-2', view
            receipt['checks']['e3_signed_revoke_writes_evidence_for_e1_device'] = True

            # The old room is read-only for the replacement: policy-active, but not on
            # the roster, so its commit is 403 (the relay never parses MLS commits —
            # the outer list is what counts) and history stays undecryptable (GET open).
            status, body = relay.http('POST', f'/v2/rooms/{ROOM}/events',
                                      {'device': 'a-3', 'client_id': 'a3-family-commit', 'kind': 'commit',
                                       'epoch': b1.epoch, 'bytes': b64(b'synthetic-not-an-mls-commit'),
                                       'members': [{'device': 'a-3', 'actor': 'a'}]}, subject=a3.subject)
            assert status == 403 and body['error'] == 'commit_sender_not_member', (status, body)
            # The replacement holds no group state for the old room, so its history is
            # undecryptable to it. Checked on a throwaway worker: the facade retires a
            # device on ANY failed operation (this experiment has no recovery), so a-3's
            # real worker must stay clean for family-2 below.
            probe = Device('a-3-probe')
            probe.call('decrypt', sealed([1, 2, 3]), reject=True)
            probe.context.close()
            receipt['checks']['i_old_room_read_only_for_replacement'] = True

            # 새 방: the replacement device creates family-2 and brings b-1 in.
            b1n = Device('b-1')  # the surviving b-1 identity, fresh worker for the new room
            for device in [a3, b1n]:
                device.publish_key_package(ROOM2)
            a3.call('create')
            a3.joined = True
            rosters[ROOM2] = ['a-3']
            a3.add(b1n, room=ROOM2)  # the founding-membership bootstrap seeds [a-3, b-1]
            b1n.sync(ROOM2)
            assert b1n.joined and b1n.epoch == 1
            a3.post_ok('application', a3.call('encrypt', bound(a3.dev, list(b'new room after total loss'), room=ROOM2)), 'room2', room=ROOM2)
            assert b1n.sync(ROOM2) == [b'new room after total loss']
            receipt['checks']['i_new_room_after_total_loss'] = True
            receipt['final_policy_revision'] = policy.revision

            # --- j (part 2): /close is a member-only deletion path. c-2 is active and
            # --- authenticated but not in family-2 -> 403; an unknown room -> 404; the
            # --- member a-3 closes it -> 200 and every route answers 410 afterwards.
            status, body = relay.http('POST', f'/v2/rooms/{ROOM2}/close?device=c-2', subject=c2.subject)
            assert status == 403 and body == {'error': 'not_a_member'}, (status, body)
            status, body = relay.http('POST', '/v2/rooms/no-such-room/close?device=a-3', subject=a3.subject)
            assert status == 404 and body['error'] == 'no_such_room', (status, body)
            assert b1n.raw_events(b1n.cursor, ROOM2)['epoch'] == b1n.epoch  # still open after the refused close
            status, body = relay.http('POST', f'/v2/rooms/{ROOM2}/close?device=a-3', subject=a3.subject)
            assert status == 200 and body == {'closed': True}, (status, body)
            status, body = relay.http('GET', f'/v2/rooms/{ROOM2}/events?device=b-1', subject=b1n.subject)
            assert status == 410 and body['error'] == 'room_closed', (status, body)
            receipt['checks']['j_close_member_only_then_410'] = True

            receipt['wire_bytes'] = {'add_commit': add_commit_size, 'welcome': welcome_size,
                                     'stale_app': len(stale), 'reencrypted_app': len(fresh)}
            for device in everyone + [a3, b1n, c1, c2]:
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
