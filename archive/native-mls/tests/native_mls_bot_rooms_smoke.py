#!/usr/bin/env python3
"""#423 ③ / #425 ⑤ acceptance smoke: two steward bots on a real v2 relay.

The unit tests of #486 (several agent rooms behind --room-frames) and #487
(peer bot alerts in the fleet alert room) drive the responder with fake relay
rows. This smoke runs the same rules end to end: Go v2 relay (-access-mode
disabled, loopback, device policy ON), real browser leaves doing MLS in their
workers, and two `native-mls-bot steward` processes with `--room-frames`, each
wired to a stand-in responder that speaks the FLEET-WORKER port and appends
every `turn` frame it receives to a log file.

Topology (one browser device per room: a facade Device belongs to exactly one
MLS group):

  bot na-bot (actor na)  a-one agent · a-two agent · a-quiet silent ·
                         fleet-alerts alert · shared agent
  bot nb-bot (actor nb)  fleet-alerts alert · shared agent
  people                 u-1 a-one · v-1 a-two · w-1 a-quiet · x-1 fleet-alerts · y-1 shared

Proven here:
  a. steward bootstrap like a node install: a short `session` mints the
     identity, the owner CLI enrolls it, `extract-identity` keeps the signer
     only, and the steward comes back with the same public key.
  b. steward room commands on the relay: `room create` (agent/silent/alert),
     `room join` (the other bot publishes a room key package), `room invite`
     (bot founder adds a bot and a person, targeted Welcome each).
  c. ③ two agent rooms + one silent room: each mention is answered in ITS
     room only (the turn frame carries `room`, turn id `t-<room>-<seq>`), the
     silent room stays silent after the bot provably read past the message,
     and `status.polls_per_round` equals the room count.
  d. outside the alert room bot output stays unread: in an agent room both
     bots share (with the other bot even listed in `<room>.peers`), a person's
     message is one turn per bot and neither bot reads the other's answer.
  e. ⑤ a node alert raised by na's responder (`notice` frame) lands in the
     alert room re-headed `[alert:na]` (the worker's spoofed header is
     replaced); nb takes it as ONE read-only peer turn (`peer: true`) and
     writes nothing — the relay holds zero nb-authored messages there.
  f. depth cap: a notice nb's responder raises during a peer turn goes out as
     `[alert:nb:2]` (people see it) and na skips it (`peer_skipped: depth`);
     na's responder never receives a peer turn.
  g. restart keeps cursors: a clean stop + start replays no old message (the
     only new turn is the new one).
  h. restart keeps the inbox: SIGKILL while a turn is in flight → on start the
     bot posts the "not confirmed" notice once, in THAT turn's room only, and
     the turn is never re-sent to the responder.

Usage:
  python archive/native-mls/tests/native_mls_bot_rooms_smoke.py \\
      --bundle artifacts/mls-pkg --relay-binary artifacts/native-mls-relay \\
      --devices-binary artifacts/native-devices \\
      --bot-binary archive/experiments/openmls-browser/target/debug/native-mls-bot
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from playwright.sync_api import sync_playwright

from native_mls_bot_smoke import CSP, Bot, Policy, Relay, b64, bound, sealed

ALERTS = 'fleet-alerts'
SHARED = 'shared'
A_ROOMS = {'a-one': 'agent', 'a-two': 'agent', 'a-quiet': 'silent', ALERTS: 'alert', SHARED: 'agent'}
B_ROOMS = {ALERTS: 'alert', SHARED: 'agent'}
UNCERTAIN_PREFIX = '⚠️ 요청(#'
# The line a message earns when it arrives while another turn runs (Matrix
# parity). One responder serves every room one turn at a time, so whether a
# near-simultaneous mention waits is a race: people keep these lines apart
# from `seen` and the checks below pin their wording, not their presence.
QUEUE_PREFIX = '⏳ 이 메시지는 대기 순번 '
QUEUE_LINE_FIRST = '⏳ 이 메시지는 대기 순번 2번에 저장되었으며 도착 순서대로 처리됩니다.'
# What a person in the alert room reads by the end: na's two alerts (re-headed
# by na) and nb's depth-2 reaction — never nb's suppressed peer answers.
ALERT_ROOM_FINAL = ['[alert:na] disk 91%', '[alert:na] chain check', '[alert:nb:2] reaction']

# The stand-in responder (FLEET-WORKER port, JSON lines). Every turn frame is
# appended to argv[1] before anything else, so the harness can count turns.
#   peer turn           → result (must be suppressed by the bot); with "chain"
#                         in the alert text it first raises a notice (depth 2)
#   "hang…"             → no answer at all (the bot is killed mid-turn)
#   "alert <text>"      → notice to the alert room with a spoofed header, then
#                         a normal result
#   anything else       → result "answer[<room>]: <prompt>"
FAKE_RESPONDER = r'''
import json, sys
log_path, alert_room = sys.argv[1], sys.argv[2]
def out(frame):
    print(json.dumps(frame), flush=True)
for line in sys.stdin:
    cmd = json.loads(line)
    if cmd.get("type") != "turn":
        continue
    with open(log_path, "a") as log:
        log.write(json.dumps(cmd, sort_keys=True) + "\n")
    tid, prompt = cmd["turn_id"], cmd["prompt"]
    out({"type": "session", "turn_id": tid, "session_id": "s1"})
    if cmd.get("peer"):
        if "chain" in prompt:
            out({"type": "notice", "room": alert_room, "text": "[alert:spoof] reaction"})
        out({"type": "result", "turn_id": tid, "status": "complete", "session_id": "s1", "text": "peer auto-reply"})
        continue
    if prompt.startswith("hang"):
        continue
    if prompt.startswith("alert "):
        out({"type": "notice", "room": alert_room, "text": "[alert:spoof] " + prompt[len("alert "):]})
    out({"type": "result", "turn_id": tid, "status": "complete", "session_id": "s1",
         "text": "answer[%s]: %s" % (cmd.get("room"), prompt)})
'''


class Steward(Bot):
    """`native-mls-bot steward` with --room-frames and the stand-in responder.
    Reuses Bot's line reader, waits and stop/kill contracts."""

    def __init__(self, binary, relay, device, identity_file, rooms_dir, responder_argv, owner_actor):
        self.binary, self.device, self.rooms_dir = binary, device, rooms_dir
        argv = [str(binary), f'http://127.0.0.1:{relay.port}', 'steward', device,
                '--identity-file', str(identity_file), '--rooms-dir', str(rooms_dir),
                '--responder-argv-json', json.dumps(responder_argv),
                '--owner-actor', owner_actor, '--room-frames']
        # No session cap: the default (300 s) would end a slow CI run mid-step.
        env = dict(os.environ, NATIVE_MLS_BOT_MAX_SECS='0')
        self.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.lines = []
        self.lock = threading.Condition()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.echo_seq = 0

    def mark(self):
        with self.lock:
            return len(self.lines)

    def wait_after(self, mark, predicate, timeout=60):
        """Like wait_for, but only lines logged after `mark` count."""
        deadline = time.monotonic() + timeout
        with self.lock:
            while True:
                for line in self.lines[mark:]:
                    if predicate(line):
                        return line
                if self.proc.poll() is not None:
                    raise AssertionError(f'{self.device} exited {self.proc.returncode} while waiting; '
                                         f'got {self.lines[mark:]}')
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f'{self.device} line timeout; got {self.lines[mark:]}')
                self.lock.wait(remaining)

    def events(self, name, room=None):
        with self.lock:
            return [line for line in self.lines if line.get('event') == name
                    and (room is None or line.get('room') == room)]

    def cmd(self, op, room, arg=None):
        """One operator command through the file queue (same CLI the node uses)."""
        argv = [str(self.binary), 'room', op, room] + ([arg] if arg else []) + ['--rooms-dir', str(self.rooms_dir)]
        run = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        assert run.returncode == 0, (self.device, op, room, arg, run.stdout, run.stderr)
        out = json.loads(run.stdout.strip().splitlines()[-1])
        assert out.get('ok') is True, (self.device, op, room, out)
        return out


def turns(log_path):
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text().splitlines() if line.strip()]


def wait_turns(log_path, count, timeout=60):
    deadline = time.monotonic() + timeout
    while True:
        got = turns(log_path)
        if len(got) >= count:
            return got
        assert time.monotonic() < deadline, f'{log_path.name}: {len(got)} turns, waited for {count}: {got}'
        time.sleep(0.1)


def bootstrap_identity(binary, relay, policy, device, actor, work):
    """The install path for a node bot: steward mode only READS an identity,
    so a short `session` mints one (state snapshotted before its first POST),
    the owner CLI enrolls its key, and `extract-identity` keeps the signer."""
    state = work / f'{device}-boot-state.json'
    boot = Bot(binary, relay, f'boot-{actor}', device, state_file=state)
    ident = boot.wait_for(lambda line: line.get('event') == 'identity')
    assert ident['restored'] is False, ident
    policy.mutate(['-enroll-first', '-input', str(policy.evidence_file(
        {'device_id': device, 'actor': actor, 'subject': f'person-{actor}',
         'signing_key': ident['public_key']}))], policy.revision)
    boot.wait_for(lambda line: line.get('event') == 'ready')
    boot.stop()
    identity_file = work / f'{device}.identity.json'
    run = subprocess.run([str(binary), 'extract-identity', f'boot-{actor}', device, '--state-file', str(state),
                          '--identity-file', str(identity_file)], capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, (run.stdout, run.stderr)
    state.unlink()
    return identity_file, ident['public_key']


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
    evidence = Path(tempfile.mkdtemp(prefix='native-v2-steward-', dir=repo / 'artifacts'))
    bot_binary = args.bot_binary.resolve()
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
    receipt = {'synthetic_only': True,
               'transport': 'python harness HTTP to the v2 relay (-access-mode disabled, loopback, device policy ON); '
                            'MLS state in browser workers and two steward bot processes (--room-frames) with a '
                            'stand-in FLEET-WORKER responder each',
               'rooms': {'na-bot': A_ROOMS, 'nb-bot': B_ROOMS}, 'checks': {}}

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

    policy_state = evidence / 'device-policy'
    policy_state.mkdir(mode=0o700)
    policy = Policy(args.devices_binary.resolve(), policy_state, evidence)
    view = policy.run(['-init'])
    assert view['revision'] == 1 and view['devices'] == [], view
    policy.revision = 1
    relay = Relay(args.relay_binary.resolve(), evidence / 'relay-data', evidence, policy_state)
    responder_py = evidence / 'fake_responder.py'
    responder_py.write_text(FAKE_RESPONDER)
    log_a, log_b = evidence / 'turns-na.jsonl', evidence / 'turns-nb.jsonl'
    dir_a, dir_b = evidence / 'rooms-na', evidence / 'rooms-nb'
    stewards = []

    def start_steward(device, identity_file, rooms_dir, log_path):
        steward = Steward(bot_binary, relay, device, identity_file, rooms_dir,
                          [sys.executable, str(responder_py), str(log_path), ALERTS], owner_actor='u')
        stewards.append(steward)
        return steward

    try:
        relay.start()

        # --- a. steward bootstrap, both bots, then the long-running stewards.
        id_a, key_a = bootstrap_identity(bot_binary, relay, policy, 'na-bot', 'na', evidence)
        id_b, key_b = bootstrap_identity(bot_binary, relay, policy, 'nb-bot', 'nb', evidence)
        bot_a = start_steward('na-bot', id_a, dir_a, log_a)
        bot_b = start_steward('nb-bot', id_b, dir_b, log_b)
        for steward, key in [(bot_a, key_a), (bot_b, key_b)]:
            ready = steward.wait_for(lambda line: line.get('event') == 'steward_ready')
            assert ready['public_key'] == key and ready['rooms'] == [] and ready['max_secs'] == 0, ready
            started = steward.wait_for(lambda line: line.get('event') == 'agent_started')
            assert started['room_frames'] is True, started
        receipt['checks']['steward_bootstrap_session_enroll_extract_identity'] = True

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            receipt['browser'] = browser.version

            class Person:
                """A real chromium context doing MLS in its worker, member of one room."""

                def __init__(self, dev, room):
                    self.dev, self.room = dev, room
                    self.context = browser.new_context()
                    self.page = self.context.new_page()
                    self.page.goto('http://' + expected_host)
                    # predicate must be a function: bare expressions are compiled
                    # by playwright into the page, where CSP blocks them.
                    self.page.wait_for_function('() => window.ready === true')
                    self.page.evaluate("spawn('main')")
                    self.cursor, self.epoch, self.joined, self.serial = 0, 0, False, 0
                    self.seen = []  # every application plaintext, in relay order (queue lines aside)
                    self.queued = []  # queue-position lines (QUEUE_PREFIX), in relay order
                    self.call('init', dev)
                    self.key_hex = bytes(self.call('public_key')).hex()

                def call(self, method, argument=None):
                    value = self.page.evaluate('([m, a]) => call("main", m, a)', [method, argument])
                    assert value['ok'] is True, (self.dev, method, value)
                    return value.get('result')

                def publish_key_package(self):
                    package = self.call('key_package')
                    # The ref is the package's sha256 (the app's rule; a steward
                    # refuses a consumed package whose bytes do not match it).
                    packages = [{'ref': hashlib.sha256(bytes(package)).hexdigest(), 'bytes': b64(package)}]
                    status, body = relay.http('POST', f'/v2/rooms/{self.room}/keypackages',
                                              {'device': self.dev, 'packages': packages})
                    assert status == 201, (self.dev, status, body)

                def sync(self):
                    status, body = relay.http(
                        'GET', f'/v2/rooms/{self.room}/events?device={self.dev}&after={self.cursor}')
                    assert status == 200, (self.dev, status, body)
                    for ev in body['events']:
                        self.cursor = max(self.cursor, ev['seq'])
                        if ev['device'] == self.dev:
                            continue
                        data = list(base64.b64decode(ev['bytes']))
                        if not self.joined:
                            if ev['kind'] == 'welcome':
                                self.call('join', data)
                                self.joined = True
                            continue
                        if ev['kind'] == 'commit':
                            self.call('commit', data)
                        elif ev['kind'] == 'welcome':
                            raise AssertionError(f'{self.dev} got a Welcome not targeted at it: {ev}')
                        else:
                            text = bytes(self.call('decrypt', sealed(data, room=self.room))).decode()
                            (self.queued if text.startswith(QUEUE_PREFIX) else self.seen).append(text)
                    self.epoch = body['epoch']

                def wait_seen(self, count, timeout=60):
                    deadline = time.monotonic() + timeout
                    while True:
                        self.sync()
                        if len(self.seen) >= count:
                            return self.seen
                        assert time.monotonic() < deadline, f'{self.dev}: saw {self.seen}, waited for {count}'
                        time.sleep(0.2)

                def say(self, text):
                    """Post one message; returns its relay seq."""
                    self.sync()
                    self.serial += 1
                    client_id = f'{self.dev}-{self.serial}-m'
                    status, body = relay.http('POST', f'/v2/rooms/{self.room}/events', {
                        'device': self.dev, 'client_id': client_id, 'kind': 'application', 'epoch': self.epoch,
                        'bytes': b64(self.call('encrypt', bound(self.dev, list(text.encode()), room=self.room)))})
                    assert status == 201, (self.dev, status, body)
                    return body['seq']

            people = {}
            for dev, room in [('u-1', 'a-one'), ('v-1', 'a-two'), ('w-1', 'a-quiet'), ('x-1', ALERTS), ('y-1', SHARED)]:
                person = Person(dev, room)
                actor = dev.split('-')[0]
                policy.mutate(['-enroll-first', '-input', str(policy.evidence_file(
                    {'device_id': dev, 'actor': actor, 'subject': f'person-{actor}',
                     'signing_key': person.key_hex}))], policy.revision)
                people[room] = person

            # --- b. steward room commands: na founds every room; nb joins the
            # --- two shared ones by key package; every invite = commit echo →
            # --- targeted Welcome.
            for room, mode in A_ROOMS.items():
                out = bot_a.cmd('create', room, mode)
                assert out['mode'] == mode and out['epoch'] == 0, out

            def invite(room, target):
                mark = bot_a.mark()
                out = bot_a.cmd('invite', room, target)
                assert out['key_source'] == 'room' and target in out['members'], out
                bot_a.wait_after(mark, lambda line: line.get('event') == 'welcome_sent'
                                 and line.get('room') == room and target in line.get('targets', []))

            for room in B_ROOMS:
                out = bot_b.cmd('join', room)
                assert out['stored'], out
                mark = bot_b.mark()
                invite(room, 'nb-bot')
                bot_b.wait_after(mark, lambda line, room=room: line.get('event') == 'joined'
                                 and line.get('room') == room)
                bot_b.cmd('mode', room, B_ROOMS[room])
            for room, person in people.items():
                person.publish_key_package()
                invite(room, person.dev)
                person.sync()
                assert person.joined, (person.dev, room)
            # Peer lists: nb reads na's alerts; na reads nb's (for the depth
            # cap). nb also lists na in the SHARED agent room — the list must
            # not matter outside an alert room.
            (dir_b / f'{ALERTS}.peers').write_text('# fleet alert room\nna\n')
            (dir_b / f'{SHARED}.peers').write_text('na\n')
            (dir_a / f'{ALERTS}.peers').write_text('nb\n')
            members = bot_a.cmd('members', ALERTS)
            alert_devices = sorted(m['device'] for m in members['members'])
            assert alert_devices == ['na-bot', 'nb-bot', 'x-1'], members
            receipt['checks']['steward_create_join_invite_on_relay'] = {'alert_room_members': alert_devices}

            # --- c. ③ two agent rooms + one silent room.
            one, two, quiet = people['a-one'], people['a-two'], people['a-quiet']
            one.say('hello one')
            two.say('hello two')
            quiet_seq = quiet.say('hello quiet')
            got = wait_turns(log_a, 2)
            by_room = {turn['room']: turn for turn in got}
            assert sorted(by_room) == ['a-one', 'a-two'], got
            for room, text in [('a-one', 'hello one'), ('a-two', 'hello two')]:
                turn = by_room[room]
                assert turn['prompt'] == text and turn['turn_id'].startswith(f't-{room}-'), turn
                assert 'peer' not in turn, turn
            assert one.wait_seen(1) == ['answer[a-one]: hello one'], one.seen
            assert two.wait_seen(1) == ['answer[a-two]: hello two'], two.seen
            # Silence needs a tripwire: the bot must have READ past the message.
            status = bot_a.wait_for(lambda line: line.get('event') == 'status' and any(
                r['room'] == 'a-quiet' and r['cursor'] >= quiet_seq for r in line['rooms']), timeout=30)
            assert status['polls_per_round'] == len(A_ROOMS) == len(status['rooms']), status
            quiet.sync()
            assert quiet.seen == [], quiet.seen
            assert not bot_a.events('agent_offer', 'a-quiet'), bot_a.events('agent_offer', 'a-quiet')
            assert len(turns(log_a)) == 2, turns(log_a)
            assert one.seen == ['answer[a-one]: hello one'] and two.seen == ['answer[a-two]: hello two']
            # Two mentions, one responder: at most the later one waited, and
            # then it was told its place in line in its own room.
            assert one.queued + two.queued in ([], [QUEUE_LINE_FIRST]), (one.queued, two.queued)
            receipt['checks']['two_agent_rooms_answer_in_own_room_silent_room_silent'] = {
                'turn_ids': sorted(t['turn_id'] for t in got), 'polls_per_round': status['polls_per_round']}

            # --- d. outside the alert room bot output stays unread.
            shared = people[SHARED]
            mark_a, mark_b = bot_a.mark(), bot_b.mark()
            shared.say('hi both')
            assert shared.wait_seen(2) == ['answer[shared]: hi both'] * 2, shared.seen
            # Each bot reads the other's answer and skips it as bot output.
            for steward in (bot_a, bot_b):
                steward.wait_after(mark_a if steward is bot_a else mark_b,
                                   lambda line: line.get('event') == 'echo_skipped' and line.get('room') == SHARED)
            for log_path in (log_a, log_b):
                shared_turns = [t for t in turns(log_path) if t['room'] == SHARED]
                assert [t['prompt'] for t in shared_turns] == ['hi both'], (log_path.name, shared_turns)
                assert all('peer' not in t for t in shared_turns), shared_turns
            assert not bot_b.events('peer_offer', SHARED) and not bot_b.events('peer_skipped', SHARED)
            receipt['checks']['agent_room_bot_output_unread_even_with_peers_file'] = True

            # --- e. ⑤ na's node alert → alert room → nb read-only peer turn.
            alerts = people[ALERTS]
            mark_a, mark_b = bot_a.mark(), bot_b.mark()
            one.say('alert disk 91%')
            assert alerts.wait_seen(1) == ['[alert:na] disk 91%'], alerts.seen
            assert one.wait_seen(2)[-1] == 'answer[a-one]: alert disk 91%', one.seen
            offer = bot_b.wait_after(mark_b, lambda line: line.get('event') == 'peer_offer'
                                     and line.get('room') == ALERTS)
            assert offer['from'] == 'na-bot' and offer['depth'] == 1, offer
            bot_b.wait_after(mark_b, lambda line: line.get('event') == 'agent_outbound_suppressed'
                             and line.get('room') == ALERTS and line.get('kind') == 'reply')
            peer_turns = [t for t in turns(log_b) if t.get('peer')]
            assert len(peer_turns) == 1, peer_turns
            assert peer_turns[0]['room'] == ALERTS and peer_turns[0]['prompt'] == '[alert:na] disk 91%', peer_turns
            status, view = relay.http('GET', f'/v2/rooms/{ALERTS}/events?device=x-1&after=0')
            assert status == 200, (status, view)
            nb_apps = [ev for ev in view['events'] if ev['device'] == 'nb-bot' and ev['kind'] == 'application']
            assert nb_apps == [], nb_apps
            alerts.sync()
            assert alerts.seen == ['[alert:na] disk 91%'], alerts.seen
            receipt['checks']['alert_room_peer_turn_read_only_zero_replies'] = {
                'peer_turns_nb': 1, 'nb_messages_in_alert_room': 0, 'header_rewritten': True}

            # --- f. depth cap: a notice raised during nb's peer turn is depth 2.
            mark_a, mark_b = bot_a.mark(), bot_b.mark()
            one.say('alert chain check')
            assert alerts.wait_seen(3) == ALERT_ROOM_FINAL, alerts.seen
            skipped = bot_a.wait_after(mark_a, lambda line: line.get('event') == 'peer_skipped'
                                       and line.get('room') == ALERTS)
            assert skipped['reason'] == 'depth' and skipped['from'] == 'nb-bot', skipped
            bot_b.wait_after(mark_b, lambda line: line.get('event') == 'agent_outbound_suppressed'
                             and line.get('room') == ALERTS and line.get('kind') == 'reply')
            assert len([t for t in turns(log_b) if t.get('peer')]) == 2, turns(log_b)
            assert not [t for t in turns(log_a) if t.get('peer')], turns(log_a)
            assert one.wait_seen(3)[-1] == 'answer[a-one]: alert chain check', one.seen
            receipt['checks']['depth_two_notice_seen_by_people_skipped_by_peer'] = True

            # --- g. clean restart: cursors survive, nothing old is replayed.
            before = len(turns(log_a))
            bot_a.stop()
            bot_a = start_steward('na-bot', id_a, dir_a, log_a)
            ready = bot_a.wait_for(lambda line: line.get('event') == 'steward_ready')
            assert ready['public_key'] == key_a, ready
            assert {r['room']: r['mode'] for r in ready['rooms']} == A_ROOMS, ready
            assert all(r['joined'] and not r['halted'] for r in ready['rooms']), ready
            one.say('after restart')
            got = wait_turns(log_a, before + 1)
            assert [t['prompt'] for t in got[before:]] == ['after restart'], got[before:]
            assert one.wait_seen(4)[-1] == 'answer[a-one]: after restart', one.seen
            # One more full round after the answer: still nothing replayed.
            mark = bot_a.mark()
            bot_a.wait_after(mark, lambda line: line.get('event') == 'status', timeout=30)
            assert len(turns(log_a)) == before + 1, turns(log_a)[before:]
            assert not bot_a.events('joined'), bot_a.events('joined')
            receipt['checks']['clean_restart_keeps_cursors_no_replay'] = True

            # --- h. SIGKILL mid-turn: the inbox survives, the room of the turn
            # --- gets the notice once, the turn is not re-run.
            before = len(turns(log_a))
            two.say('hang on this one')
            wait_turns(log_a, before + 1)
            bot_a.kill()
            bot_a = start_steward('na-bot', id_a, dir_a, log_a)
            bot_a.wait_for(lambda line: line.get('event') == 'agent_outbound' and line.get('kind') == 'uncertain'
                           and line.get('room') == 'a-two')
            seen_two = two.wait_seen(2)
            assert len(seen_two) == 2 and seen_two[-1].startswith(UNCERTAIN_PREFIX), seen_two
            two.say('after crash')
            assert two.wait_seen(3)[-1] == 'answer[a-two]: after crash', two.seen
            prompts = [t['prompt'] for t in turns(log_a)]
            assert prompts.count('hang on this one') == 1, prompts
            assert prompts[before:] == ['hang on this one', 'after crash'], prompts[before:]
            one.sync()
            assert len(one.seen) == 4 and not any(s.startswith(UNCERTAIN_PREFIX) for s in one.seen), one.seen
            assert not [line for line in bot_a.events('agent_outbound') if line.get('kind') == 'uncertain'
                        and line.get('room') != 'a-two'], bot_a.events('agent_outbound')
            receipt['checks']['sigkill_mid_turn_inbox_notice_in_turn_room_once_no_rerun'] = True

            # Final: people saw exactly what the rules allow.
            for person in people.values():
                person.sync()
            assert quiet.seen == [], quiet.seen
            assert alerts.seen == ALERT_ROOM_FINAL, alerts.seen
            receipt['seen'] = {room: len(person.seen) for room, person in people.items()}
            receipt['turns'] = {'na': len(turns(log_a)), 'nb': len(turns(log_b))}
            for steward in (bot_a, bot_b):
                steward.assert_clean()
                steward.stop()
            receipt['checks']['stewards_clean_exit'] = True
    finally:
        for steward in stewards:
            if steward.proc.poll() is None:
                steward.proc.kill()
                steward.proc.wait(timeout=10)
        relay.stop()
        server.shutdown()

    out = evidence / 'verification.json'
    out.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n')
    print(out, flush=True)
    print(json.dumps(receipt['checks'], indent=2, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
