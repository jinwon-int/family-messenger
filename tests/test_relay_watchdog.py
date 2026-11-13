"""scripts/relay_watchdog.py (#426) — 오프호스트 릴레이 워치독의 단위 검사(네트워크 없이, 프로브·시계 주입)."""
import contextlib
import io
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import homeserver_watchdog as hw  # noqa: E402
import relay_watchdog as rw  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PKG = ROOT / 'deploy' / 'watchdog'
NOW = 1_800_000_000.0
MINUTE = 60
HOUR = 3600
RECORD_NAME = re.compile(r'^health-alert-(relay_down|relay_edge|relay_recovered)-\d{13}\.json$')

DIRECT_UP = {'ok': True, 'http': 200, 'detail': 'direct HTTP 200'}
DIRECT_DOWN = {'ok': False, 'http': None, 'detail': 'direct error: URLError'}
EDGE_UP = {'ok': True, 'http': 302, 'mode': 'edge-only', 'detail': 'edge HTTP 302 (edge-only)'}
EDGE_530 = {'ok': False, 'http': 530, 'mode': 'edge-only', 'detail': 'edge HTTP 530 (edge-only)'}
PROBES = {'up': (DIRECT_UP, EDGE_UP), 'edge': (DIRECT_UP, EDGE_530), 'down': (DIRECT_DOWN, EDGE_UP)}
CANARY = 'canary-value-0123456789abcdef'
# The fleet alert queue's own rule for a condition line (ccc-node fleet_alerts_outbox.py); kept
# here as the contract this watchdog writes against.
QUEUE_CONDITION_LINE = re.compile(r'^@fleet-alert[ \t]+(opens|resolves)=([A-Za-z0-9][A-Za-z0-9._:-]{0,127})[ \t]*$')
# The owner spool masks any unbroken run this long of key-like characters.
MASKED_RUN = re.compile(r'[A-Za-z0-9_./+=-]{24,}')


def conditions(record):
    """({'opens': [...], 'resolves': [...]}, display lines) as the fleet alert queue would read them."""
    found = {'opens': [], 'resolves': []}
    shown = []
    for line in record['text'].splitlines():
        m = QUEUE_CONDITION_LINE.match(line.strip())
        if m:
            found[m.group(1)].append(m.group(2))
        else:
            shown.append(line)
    return found, shown


class FakeResponse:
    def __init__(self, status, body):
        self.status, self._body = status, body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self, n=-1):
        return self._body


def fake_opener(outcome, captured):
    class Opener:
        def open(self, req, timeout):
            captured['url'] = req.full_url
            captured['headers'] = dict(req.header_items())
            captured['timeout'] = timeout
            if isinstance(outcome, Exception):
                raise outcome
            return outcome
    return Opener()


def http_error(code):
    return HTTPError('https://x/v2/health', code, 'x', {}, None)


class ProbeTest(unittest.TestCase):
    def call(self, fn, outcome, *args):
        captured = {}
        with mock.patch.object(rw.urllib.request, 'build_opener', return_value=fake_opener(outcome, captured)):
            return fn(*args), captured

    def test_direct_ok_only_for_200_ok_true(self):
        result, cap = self.call(rw.probe_direct, FakeResponse(200, b'{"ok":true}'), 'http://10.0.0.1:1/', 4.0)
        self.assertTrue(result['ok'])
        self.assertEqual(cap['url'], 'http://10.0.0.1:1/v2/health')
        self.assertEqual(cap['headers'].get('User-agent'), 'family-messenger-watchdog/1')
        self.assertEqual(cap['timeout'], 4.0)
        for body in (b'{"ok":false}', b'{"ok":"true"}', b'nope', b'[]'):
            result, _ = self.call(rw.probe_direct, FakeResponse(200, body), 'http://h:1', 1.0)
            self.assertFalse(result['ok'], body)
            self.assertIn('not ok', result['detail'])

    def test_direct_http_error_and_network_error_are_down(self):
        result, _ = self.call(rw.probe_direct, http_error(503), 'http://h:1', 1.0)
        self.assertEqual((result['ok'], result['http']), (False, 503))
        result, _ = self.call(rw.probe_direct, URLError('refused'), 'http://h:1', 1.0)
        self.assertEqual((result['ok'], result['http']), (False, None))
        self.assertEqual(result['detail'], 'direct error: URLError')

    def test_edge_only_mode_treats_access_answers_as_alive(self):
        for code in (302, 401, 403):
            result, cap = self.call(rw.probe_edge, http_error(code), 'https://relay.example.com', 2.0)
            self.assertTrue(result['ok'], code)
            self.assertEqual(result['mode'], 'edge-only')
            self.assertNotIn('Cf-access-client-id', cap['headers'])
        for outcome in (http_error(530), http_error(502), URLError('dns')):
            result, _ = self.call(rw.probe_edge, outcome, 'https://relay.example.com', 2.0)
            self.assertFalse(result['ok'], outcome)

    def test_authed_mode_requires_relay_health_and_sends_headers(self):
        headers = {'CF-Access-Client-Id': 'id.access', 'CF-Access-Client-Secret': CANARY}
        ok_body = FakeResponse(200, b'{"ok": true}')
        result, cap = self.call(rw.probe_edge, ok_body, 'https://r.example.com/', 2.0, headers)
        self.assertTrue(result['ok'])
        self.assertEqual(result['mode'], 'authed')
        self.assertEqual(cap['headers'].get('Cf-access-client-secret'), CANARY)
        self.assertNotIn(CANARY, json.dumps(result))
        # Access still redirecting despite the token (token revoked / wrong app) is down in authed mode.
        for outcome in (http_error(302), http_error(403), http_error(530)):
            result, _ = self.call(rw.probe_edge, outcome, 'https://r.example.com', 2.0, headers)
            self.assertFalse(result['ok'], outcome)

    def test_redirects_are_not_followed(self):
        handler = rw._NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, 'Found', {}, 'https://login.example'))


class AccessEnvTest(unittest.TestCase):
    def write(self, text, mode=0o600):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        p = Path(tmp.name) / 'token.env'
        p.write_text(text, encoding='utf-8')
        os.chmod(p, mode)
        return p

    def test_reads_both_keys_and_ignores_others(self):
        p = self.write('# c\nCF_ACCESS_TOKEN_ID=x\nCF_ACCESS_CLIENT_ID="id.access"\n'
                       'export CF_ACCESS_CLIENT_SECRET=%s\n' % CANARY)
        self.assertEqual(rw.read_access_env(p),
                         {'CF-Access-Client-Id': 'id.access', 'CF-Access-Client-Secret': CANARY})

    def test_rejects_loose_permissions_missing_keys_and_symlinks(self):
        with self.assertRaisesRegex(ValueError, 'chmod 600'):
            rw.read_access_env(self.write('CF_ACCESS_CLIENT_ID=a\nCF_ACCESS_CLIENT_SECRET=b\n', 0o644))
        with self.assertRaises(ValueError) as cm:
            rw.read_access_env(self.write('CF_ACCESS_CLIENT_ID=a\nCF_ACCESS_CLIENT_SECRET=\n'))
        self.assertIn('CF_ACCESS_CLIENT_SECRET', str(cm.exception))
        real = self.write('CF_ACCESS_CLIENT_ID=a\nCF_ACCESS_CLIENT_SECRET=%s\n' % CANARY)
        link = real.with_name('link.env')
        link.symlink_to(real)
        with self.assertRaises(ValueError) as cm:
            rw.read_access_env(link)
        self.assertNotIn(CANARY, str(cm.exception))

    def test_main_fails_closed_on_bad_access_env_without_leaking(self):
        p = self.write('CF_ACCESS_CLIENT_ID=a\nCF_ACCESS_CLIENT_SECRET=%s\n' % CANARY, 0o640)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = rw.main(['--direct-url', 'http://h:1', '--edge-url', 'https://e', '--access-env', str(p),
                            '--state', str(p.with_name('s.json'))],
                           direct_fn=lambda *a: self.fail('probed'), edge_fn=lambda *a: self.fail('probed'))
        self.assertEqual(code, 1)
        self.assertNotIn(CANARY, err.getvalue())


class ClassifyTest(unittest.TestCase):
    def test_matrix(self):
        self.assertEqual(rw.classify(True, True), rw.UP)
        self.assertEqual(rw.classify(True, False), rw.EDGE)
        self.assertEqual(rw.classify(False, True), rw.RELAY_DOWN)
        self.assertEqual(rw.classify(False, False), rw.RELAY_DOWN)


class CycleTest(unittest.TestCase):
    """Drives main() minute by minute with injected probes and clock, like the 1-minute timer."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.spool = self.dir / 'spool'
        self.spool.mkdir()
        self.state = self.dir / 'state' / 'relay-state.json'
        self.t = NOW

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir)

    def tick(self, kind, minutes=1, spool=True, extra=()):
        out = []
        for _ in range(minutes):
            direct, edge = PROBES[kind]
            argv = ['--direct-url', 'http://h:1', '--edge-url', 'https://e', '--state', str(self.state),
                    '--push-node', 'jingun', '--json'] + list(extra)
            if spool:
                argv += ['--push-spool', str(self.spool)]
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = rw.main(argv, direct_fn=lambda u, t: direct, edge_fn=lambda u, t, a: edge,
                               clock=lambda: self.t)
            out.append((code, json.loads(buf.getvalue())))
            self.t += MINUTE
        return out

    def records(self):
        names = sorted(p.name for p in self.spool.iterdir())
        for n in names:
            self.assertRegex(n, RECORD_NAME)
        return [json.loads((self.spool / n).read_text()) for n in names]

    def test_first_up_is_silent_then_down_within_three_minutes_then_recovered(self):
        self.tick('up', 3)
        self.assertEqual(self.records(), [])
        runs = self.tick('down', 3)
        self.assertEqual([r[1]['alert'] for r in runs], ['none', 'none', 'transition:relay_down'])
        rec = self.records()[-1]
        self.assertEqual((rec['event'], rec['code'], rec['status'], rec['node']),
                         ('health-alert', 'relay_down', 'relay_down', 'jingun'))
        self.assertTrue(rec['dedup'].startswith('relay-watchdog:relay_down:'))
        self.assertIn('RELAY DOWN', rec['text'])
        self.tick('down', 30)
        self.assertEqual(len(self.records()), 1)  # no re-alert inside 6 h
        runs = self.tick('up', 3)
        self.assertEqual(runs[-1][1]['alert'], 'transition:relay_recovered')
        rec = self.records()[-1]
        self.assertIn('RECOVERED', rec['text'])
        self.assertIn('was relay_down for 33m', rec['text'])

    def test_tunnel_only_outage_is_classified_edge(self):
        self.tick('up', 3)
        runs = self.tick('edge', 3)
        self.assertEqual(runs[-1][1]['alert'], 'transition:relay_edge')
        rec = self.records()[-1]
        self.assertEqual(rec['status'], 'edge')
        self.assertIn('node bots unaffected', rec['text'])

    def test_realert_after_six_hours_only(self):
        self.tick('up', 3)
        self.tick('down', 3)
        self.tick('down', 6 * 60 - 2)
        self.assertEqual(len(self.records()), 1)
        runs = self.tick('down', 2)
        self.assertEqual([r[1]['alert'] for r in runs][-1], 'realert:relay_down')
        self.assertEqual(len(self.records()), 2)
        self.assertIn('still relay_down', self.records()[-1]['text'])

    def test_flapping_below_threshold_never_alerts(self):
        self.tick('up', 3)
        for _ in range(10):
            self.tick('down', 2)
            self.tick('up', 1)
        self.assertEqual(self.records(), [])

    def test_failed_spool_write_retries_while_state_matches(self):
        self.tick('up', 3)
        self.spool.rmdir()
        runs = self.tick('down', 3)
        self.assertEqual(runs[-1][0], 1)
        self.assertEqual(runs[-1][1]['alert'], 'failed: ValueError')
        self.spool.mkdir()
        runs = self.tick('down', 1)
        self.assertEqual(runs[0], (0, runs[0][1]))
        self.assertEqual(runs[0][1]['alert'], 'retry:relay_down')
        self.assertEqual(len(self.records()), 1)

    def test_homeserver_codes_unchanged_by_shared_advance(self):
        # The relay codes are passed explicitly; the homeserver default must not move (#412 A).
        prev = {}
        for i in range(3):
            prev, alert = hw.advance(prev, hw.HOST_DOWN, NOW + i * MINUTE, 3, 6 * HOUR)
        self.assertEqual(alert['code'], 'homeserver_down')
        prev = {}
        for i in range(3):
            prev, alert = hw.advance(prev, hw.HOST_DOWN, NOW + i * MINUTE, 3, 6 * HOUR, alert_codes=rw.ALERT_CODES)
        self.assertEqual(alert['code'], 'relay_down')

    # --- tier and condition keys (#426): a record without a tier is held for the daily digest ---

    def open_keys(self):
        return json.loads(self.state.read_text())['open_keys']

    def newest(self):
        """The record written last (names sort by code first, so records()[-1] is not it)."""
        name = max((p.name for p in self.spool.iterdir()), key=lambda n: int(n[-18:-5]))
        return json.loads((self.spool / name).read_text())

    def test_down_is_critical_and_recovery_is_notice_that_resolves_it(self):
        self.tick('up', 3)
        first_down = self.t
        runs = self.tick('down', 3)
        self.assertEqual(runs[-1][1]['tier'], 'critical')
        down = self.records()[-1]
        self.assertEqual(down['tier'], 'critical')
        found, shown = conditions(down)
        key = 'relay-watchdog:relay_down:%d' % int(first_down)
        self.assertEqual(found, {'opens': [key], 'resolves': []})
        self.assertEqual(len(shown), 1)  # the owner still reads one line
        self.assertIn('RELAY DOWN', shown[0])
        self.assertEqual(self.open_keys(), [key])
        runs = self.tick('up', 3)
        self.assertEqual(runs[-1][1]['tier'], 'notice')
        up = self.records()[-1]
        self.assertEqual(up['tier'], 'notice')
        found, shown = conditions(up)
        self.assertEqual(found, {'opens': [], 'resolves': [key]})
        self.assertIn('RECOVERED', shown[0])
        self.assertEqual(self.open_keys(), [])

    def test_edge_is_critical_and_a_change_of_shape_resolves_the_earlier_key(self):
        self.tick('up', 3)
        first_edge = self.t
        self.tick('edge', 3)
        edge = self.newest()
        edge_key = 'relay-watchdog:edge:%d' % int(first_edge)
        self.assertEqual(edge['tier'], 'critical')
        self.assertEqual(conditions(edge)[0], {'opens': [edge_key], 'resolves': []})
        first_down = self.t
        self.tick('down', 3)
        down = self.newest()
        down_key = 'relay-watchdog:relay_down:%d' % int(first_down)
        self.assertEqual(conditions(down)[0], {'opens': [down_key], 'resolves': [edge_key]})
        self.assertEqual(self.open_keys(), [down_key])
        self.tick('up', 3)
        self.assertEqual(conditions(self.newest())[0], {'opens': [], 'resolves': [down_key]})

    def test_realert_names_the_same_outage(self):
        self.tick('up', 3)
        self.tick('down', 3)
        first = conditions(self.records()[-1])[0]
        self.tick('down', 6 * 60)
        again = self.records()[-1]
        self.assertEqual(again['kind'], 'realert')
        self.assertEqual(again['tier'], 'critical')
        self.assertEqual(conditions(again)[0], first)
        self.assertEqual(self.open_keys(), first['opens'])

    def test_retried_recovery_still_resolves_the_outage(self):
        self.tick('up', 3)
        self.tick('down', 3)
        key = self.open_keys()[0]
        self.tick('up', 2)
        held = self.dir / 'spool-held'
        self.spool.rename(held)  # the recovery record cannot be written
        runs = self.tick('up', 1)
        self.assertEqual(runs[0][1]['alert'], 'failed: ValueError')
        self.assertEqual(self.open_keys(), [key])  # not forgotten by the failed write
        held.rename(self.spool)
        runs = self.tick('up', 1)
        self.assertEqual(runs[0][1]['alert'], 'retry:relay_recovered')
        rec = self.records()[-1]
        self.assertEqual((rec['code'], rec['tier']), ('relay_recovered', 'notice'))
        self.assertEqual(conditions(rec)[0], {'opens': [], 'resolves': [key]})
        self.assertEqual(self.open_keys(), [])

    def test_failed_down_write_opens_nothing_until_it_lands(self):
        self.tick('up', 3)
        self.spool.rmdir()
        self.tick('down', 3)
        self.assertEqual(self.open_keys(), [])
        self.spool.mkdir()
        self.tick('down', 1)
        self.assertEqual(len(self.open_keys()), 1)
        self.assertEqual(conditions(self.records()[-1])[0]['opens'], self.open_keys())

    def test_keys_fit_the_queue_rule_and_are_not_masked(self):
        self.tick('up', 3)
        self.tick('edge', 3)
        self.tick('down', 3)
        self.tick('up', 3)
        seen = 0
        for rec in self.records():
            for line in rec['text'].splitlines()[1:]:
                m = QUEUE_CONDITION_LINE.match(line)
                self.assertIsNotNone(m, line)
                self.assertTrue(rw.CONDITION_KEY_RE.match(m.group(2)))
                for segment in m.group(2).split(':'):
                    self.assertIsNone(MASKED_RUN.search(segment), segment)
                seen += 1
        self.assertEqual(seen, 4)  # edge opens, down opens + resolves edge, up resolves down

    def test_marker_lines_survive_a_text_at_the_limit(self):
        alert = {'code': 'relay_down', 'kind': 'transition', 'state': rw.RELAY_DOWN, 'since': NOW}
        key = rw.condition_key(rw.RELAY_DOWN, NOW)
        rw.spool_alert(self.spool, 'jingun', alert, 'x' * rw.MAX_TEXT, NOW, [key], ['relay-watchdog:edge:1'])
        rec = self.records()[-1]
        self.assertLessEqual(len(rec['text']), rw.MAX_TEXT)
        self.assertEqual(conditions(rec)[0], {'opens': [key], 'resolves': ['relay-watchdog:edge:1']})

    def test_unusable_open_keys_in_the_state_file_are_dropped(self):
        good = 'relay-watchdog:edge:1700000000'
        cases = [({'open_keys': 'relay-watchdog:edge:1'}, []),
                 ({'open_keys': [good, good, 7, None, 'has space', '-leading', 'x' * 200, 'a\nb']}, [good]),
                 ({'open_keys': ['k%d' % i for i in range(20)]}, ['k%d' % i for i in range(12, 20)]),
                 ({}, [])]
        for prev, want in cases:
            self.assertEqual(rw.read_open_keys(prev), want)

    def test_no_spool_leaves_open_keys_alone(self):
        self.tick('up', 3, spool=False)
        runs = self.tick('down', 3, spool=False)
        self.assertEqual(runs[-1][1]['alert'], 'unspooled:transition:relay_down')
        self.assertNotIn('tier', runs[-1][1])
        self.assertEqual(self.open_keys(), [])

    def test_every_state_has_a_tier_the_queue_knows(self):
        self.assertEqual(set(rw.ALERT_TIERS), set(rw.ALERT_CODES))
        self.assertTrue(set(rw.ALERT_TIERS.values()) <= {'info', 'notice', 'action', 'critical'})
        self.assertNotIn('info', rw.ALERT_TIERS.values())

    def test_text_never_contains_addresses(self):
        self.tick('up', 3)
        self.tick('down', 3)
        text = self.records()[-1]['text']
        self.assertNotIn('http://h:1', text)
        self.assertLessEqual(len(text), rw.MAX_TEXT)


class ArgsTest(unittest.TestCase):
    def test_usage_errors(self):
        base = ['--direct-url', 'http://h:1', '--edge-url', 'https://e']
        for bad in (['--direct-url', 'h:1', '--edge-url', 'https://e'],
                    ['--direct-url', 'http://h:1', '--edge-url', 'e'],
                    base + ['--threshold', '0'], base + ['--realert-hours', '0'], base + ['--timeout', '0']):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
                rw.parse_args(bad)
            self.assertEqual(cm.exception.code, 2, bad)


class UnitTemplateTest(unittest.TestCase):
    def test_relay_units_and_env_example(self):
        service = (PKG / 'family-messenger-relay-watchdog.service').read_text(encoding='utf-8')
        timer = (PKG / 'family-messenger-relay-watchdog.timer').read_text(encoding='utf-8')
        env = (PKG / 'relay-watchdog.env.example').read_text(encoding='utf-8')
        self.assertIn('scripts/relay_watchdog.py --once --json', service)
        self.assertIn('EnvironmentFile=/etc/family-messenger/relay-watchdog.env', service)
        self.assertIn('--state /var/lib/family-messenger-watchdog/relay-state.json', service)
        self.assertIn('StateDirectory=family-messenger-watchdog', service)
        self.assertIn('OnUnitActiveSec=1min', timer)
        self.assertIn('Unit=family-messenger-relay-watchdog.service', timer)
        for key in ('RELAY_WATCHDOG_DIRECT_URL', 'RELAY_WATCHDOG_EDGE_URL', 'RELAY_WATCHDOG_NODE',
                    'RELAY_WATCHDOG_SPOOL', 'RELAY_WATCHDOG_EXTRA_ARGS'):
            self.assertIn(key + '=', env)
            self.assertIn('${%s}' % key if key != 'RELAY_WATCHDOG_EXTRA_ARGS' else '$' + key, service)
        self.assertNotIn('CF_ACCESS_CLIENT_SECRET=', env)

    def test_execstart_uses_offhost_checkout(self):
        # #426: installed off-host (not on the homeserver), where the checkout is /opt/family-messenger.
        # The homeserver path /opt/family-messenger-tuwunel does not exist there, so the unit failed every minute.
        service = (PKG / 'family-messenger-relay-watchdog.service').read_text(encoding='utf-8')
        execstart = [line for line in service.splitlines() if line.startswith('ExecStart=')]
        self.assertEqual(len(execstart), 1)
        self.assertIn(' /opt/family-messenger/scripts/relay_watchdog.py ', execstart[0])
        self.assertNotIn('family-messenger-tuwunel', execstart[0])


if __name__ == '__main__':
    unittest.main()
