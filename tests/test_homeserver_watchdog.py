"""scripts/homeserver_watchdog.py (#412 A) — 오프호스트 워치독의 단위 검사(네트워크 없이, 프로브·시계 주입)."""
import contextlib
import datetime
import io
import json
import re
import sys
import tempfile
import unittest
from io import StringIO
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import homeserver_watchdog as wd

ROOT = Path(__file__).resolve().parents[1]
PKG = ROOT / 'deploy' / 'watchdog'
NOW = 1_800_000_000.0
MINUTE = 60
HOUR = 3600
RECORD_NAME = re.compile(r'^health-alert-(homeserver_down|homeserver_edge|homeserver_recovered)-\d{13}\.json$')

EXT_UP = {'ok': True, 'http': 200, 'detail': 'HTTP 200'}
EXT_530 = {'ok': False, 'http': 530, 'detail': 'HTTP 530'}
HOST_UP = {'ok': True, 'detail': 'tcp/22 connect ok'}
HOST_DOWN = {'ok': False, 'detail': 'tcp/22 TimeoutError'}
PROBES = {'up': (EXT_UP, HOST_UP), 'edge': (EXT_530, HOST_UP), 'host_down': (EXT_530, HOST_DOWN),
          'host_down_ext_up': (EXT_UP, HOST_DOWN)}


class FakeResponse:
    def __init__(self, status, body):
        self.status, self._body = status, body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self, n=-1):
        return self._body


def fake_opener(outcome, captured=None):
    class Opener:
        def open(self, req, timeout):
            if captured is not None:
                captured['url'] = req.full_url
                captured['ua'] = req.headers.get('User-agent')
                captured['timeout'] = timeout
            if isinstance(outcome, Exception):
                raise outcome
            return outcome
    return Opener()


class ProbeExternalTest(unittest.TestCase):
    def probe(self, outcome, url='https://matrix.example.com/'):
        captured = {}
        with mock.patch.object(wd.urllib.request, 'build_opener', return_value=fake_opener(outcome, captured)):
            return wd.probe_external(url, 7.5), captured

    def test_2xx_with_versions_is_up_and_sends_custom_ua(self):
        result, captured = self.probe(FakeResponse(200, b'{"versions": ["v1.11"]}'))
        self.assertEqual(result, {'ok': True, 'http': 200, 'detail': 'HTTP 200'})
        self.assertEqual(captured['url'], 'https://matrix.example.com/_matrix/client/versions')
        self.assertEqual(captured['ua'], 'family-messenger-watchdog/1')
        self.assertEqual(captured['timeout'], 7.5)

    def test_2xx_without_versions_key_is_down(self):
        for body in (b'{"error": "x"}', b'not json', b'[]'):
            result, _ = self.probe(FakeResponse(200, body))
            self.assertFalse(result['ok'], body)
            self.assertEqual(result['http'], 200)
            self.assertIn('no versions key', result['detail'])

    def test_cloudflare_530_records_status(self):
        err = HTTPError('https://matrix.example.com/_matrix/client/versions', 530, 'Origin unreachable', {},
                        io.BytesIO())
        result, _ = self.probe(err)
        self.assertEqual(result, {'ok': False, 'http': 530, 'detail': 'HTTP 530'})

    def test_transport_errors_have_no_status(self):
        for exc in (URLError('refused'), TimeoutError('timed out'), ConnectionResetError()):
            result, _ = self.probe(exc)
            self.assertFalse(result['ok'])
            self.assertIsNone(result['http'])
            self.assertTrue(result['detail'].startswith('error: '), result)


class ProbeHostTest(unittest.TestCase):
    def test_connect_ok_and_refused(self):
        captured = {}
        class Conn:
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False
        def connect(addr, timeout):
            captured['addr'], captured['timeout'] = addr, timeout
            return Conn()
        with mock.patch.object(wd.socket, 'create_connection', connect):
            self.assertEqual(wd.probe_host('100.64.0.2', 22, 4.0), {'ok': True, 'detail': 'tcp/22 connect ok'})
        self.assertEqual(captured, {'addr': ('100.64.0.2', 22), 'timeout': 4.0})
        with mock.patch.object(wd.socket, 'create_connection', side_effect=ConnectionRefusedError()):
            result = wd.probe_host('100.64.0.2', 22, 4.0)
        self.assertEqual(result, {'ok': False, 'detail': 'tcp/22 ConnectionRefusedError'})
        self.assertNotIn('100.64.0.2', result['detail'], 'the private address must not leak into alert text')
        with mock.patch.object(wd.socket, 'create_connection', side_effect=TimeoutError()):
            self.assertFalse(wd.probe_host('100.64.0.2', 22, 4.0)['ok'])


class ClassifyTest(unittest.TestCase):
    def test_matrix(self):
        self.assertEqual(wd.classify(True, True), 'up')
        self.assertEqual(wd.classify(False, True), 'edge')
        self.assertEqual(wd.classify(False, False), 'host_down')
        self.assertEqual(wd.classify(True, False), 'host_down', 'host down wins regardless of the edge')


class WatchdogRunBase(unittest.TestCase):
    """main() with injected probes/clock; one tmp dir per test for state + spool."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        root = Path(self.dir.name)
        self.state = root / 'state' / 'state.json'
        self.spool = root / 'spool'
        self.spool.mkdir(mode=0o700)
        self.base = ['--host', '100.64.0.2', '--push-spool', str(self.spool), '--push-node', 'seoseo',
                     '--state', str(self.state), '--json']

    def run_at(self, now, observed='up', argv=None, external=None, host=None):
        ext, hst = PROBES[observed]
        out = StringIO()
        with contextlib.redirect_stdout(out):
            code = wd.main(list(argv or self.base), external_fn=lambda url, t: external or ext,
                           host_fn=lambda h, p, t: host or hst, clock=lambda: now)
        summary = json.loads(out.getvalue())
        summary['exit'] = code
        return summary

    def records(self):
        paths = sorted(self.spool.glob('*.json'), key=lambda p: p.name.rsplit('-', 1)[-1])
        return [(p.name, json.loads(p.read_text(encoding='utf-8'))) for p in paths]

    def codes(self):
        return [rec['code'] for _, rec in self.records()]

    def settle(self, start, observed, runs=3):
        """`runs` consecutive observations one minute apart; returns the last summary."""
        last = None
        for i in range(runs):
            last = self.run_at(start + i * MINUTE, observed)
        return last


class DebounceTest(WatchdogRunBase):
    def test_two_bad_observations_do_not_alert_third_does(self):
        self.settle(NOW, 'up')
        s1 = self.run_at(NOW + 10 * MINUTE, 'host_down')
        s2 = self.run_at(NOW + 11 * MINUTE, 'host_down')
        self.assertEqual((s1['state'], s1['streak'], s1['alert']), ('up', 1, 'none'))
        self.assertEqual((s2['state'], s2['streak'], s2['alert']), ('up', 2, 'none'))
        self.assertEqual(self.codes(), [])
        s3 = self.run_at(NOW + 12 * MINUTE, 'host_down')
        self.assertEqual((s3['state'], s3['streak'], s3['transition']), ('host_down', 3, True))
        self.assertEqual(s3['alert'], 'transition:homeserver_down')
        self.assertEqual(s3['exit'], 0, 'a confirmed outage is not a run failure')
        self.assertEqual(self.codes(), ['homeserver_down'])
        self.assertEqual(s3['since'], NOW + 10 * MINUTE, 'since = first observation of the confirming streak')

    def test_flapping_resets_the_streak(self):
        self.settle(NOW, 'up')
        self.run_at(NOW + 10 * MINUTE, 'host_down')
        self.run_at(NOW + 11 * MINUTE, 'host_down')
        self.run_at(NOW + 12 * MINUTE, 'up')
        self.run_at(NOW + 13 * MINUTE, 'host_down')
        s = self.run_at(NOW + 14 * MINUTE, 'host_down')
        self.assertEqual((s['state'], s['streak']), ('up', 2))
        self.assertEqual(self.codes(), [])

    def test_mixed_bad_states_do_not_confirm_each_other(self):
        self.settle(NOW, 'up')
        self.run_at(NOW + 10 * MINUTE, 'edge')
        self.run_at(NOW + 11 * MINUTE, 'host_down')
        s = self.run_at(NOW + 12 * MINUTE, 'edge')
        self.assertEqual(s['state'], 'up')
        self.assertEqual(self.codes(), [])

    def test_threshold_option(self):
        argv = self.base + ['--threshold', '1']
        s = self.run_at(NOW, 'edge', argv=argv)
        self.assertEqual(s['alert'], 'transition:homeserver_edge')

    def test_first_confirmed_up_is_silent_but_first_confirmed_outage_alerts(self):
        s = self.settle(NOW, 'up')
        self.assertEqual((s['state'], s['alert']), ('up', 'none'))
        self.assertEqual(self.codes(), [])
        # Fresh state file, installed during an outage.
        self.state.unlink()
        s = self.settle(NOW + HOUR, 'edge')
        self.assertEqual(s['alert'], 'transition:homeserver_edge')


class ClassificationAlertTest(WatchdogRunBase):
    def test_edge_alert_text_and_escalation_to_host_down(self):
        self.settle(NOW, 'up')
        s = self.settle(NOW + 10 * MINUTE, 'edge')
        self.assertEqual(s['alert'], 'transition:homeserver_edge')
        [(_, rec)] = self.records()
        self.assertEqual(rec['status'], 'edge')
        self.assertIn('EDGE DOWN', rec['text'])
        self.assertIn('HTTP 530', rec['text'])
        self.assertIn('Cloudflare tunnel', rec['text'])
        self.assertIn('3/3 consecutive', rec['text'])
        s = self.settle(NOW + 20 * MINUTE, 'host_down')
        self.assertEqual(s['alert'], 'transition:homeserver_down')
        self.assertEqual(self.codes(), ['homeserver_edge', 'homeserver_down'])
        self.assertIn('HOST DOWN', self.records()[-1][1]['text'])
        self.assertIn('TimeoutError', self.records()[-1][1]['text'])
        # Host comes back but the edge is still broken: a partial recovery is an edge transition.
        s = self.settle(NOW + 30 * MINUTE, 'edge')
        self.assertEqual(s['alert'], 'transition:homeserver_edge')

    def test_host_down_with_external_up_is_host_down(self):
        self.settle(NOW, 'up')
        s = self.settle(NOW + 10 * MINUTE, 'host_down_ext_up')
        self.assertEqual((s['state'], s['alert']), ('host_down', 'transition:homeserver_down'))


class RecoveryTest(WatchdogRunBase):
    def test_recovery_needs_three_ups_and_reports_duration(self):
        self.settle(NOW, 'up')
        self.settle(NOW + 10 * MINUTE, 'host_down')
        self.run_at(NOW + 20 * MINUTE, 'up')
        s = self.run_at(NOW + 21 * MINUTE, 'up')
        self.assertEqual((s['state'], s['alert']), ('host_down', 'none'))
        s = self.run_at(NOW + 22 * MINUTE, 'up')
        self.assertEqual((s['state'], s['alert']), ('up', 'transition:homeserver_recovered'))
        self.assertEqual(self.codes(), ['homeserver_down', 'homeserver_recovered'])
        name, rec = self.records()[-1]
        self.assertEqual(rec['status'], 'up')
        self.assertIn('RECOVERED', rec['text'])
        self.assertIn('was host_down for 10m', rec['text'])
        self.assertTrue(rec['dedup'].endswith(':transition'))
        # Stays quiet while up, for a long time.
        s = self.run_at(NOW + 30 * HOUR, 'up')
        self.assertEqual(s['alert'], 'none')
        self.assertEqual(len(self.records()), 2)


class RealertTest(WatchdogRunBase):
    def test_suppressed_inside_six_hours_and_fires_after(self):
        self.settle(NOW, 'up')
        t_alert = NOW + 12 * MINUTE
        self.settle(NOW + 10 * MINUTE, 'host_down')          # alert at t_alert
        self.assertEqual(self.codes(), ['homeserver_down'])
        for dt in (MINUTE, HOUR, 5 * HOUR, 6 * HOUR - 1):
            s = self.run_at(t_alert + dt, 'host_down')
            self.assertEqual(s['alert'], 'none', 'quiet at +%ds' % dt)
        self.assertEqual(len(self.records()), 1)
        s = self.run_at(t_alert + 6 * HOUR, 'host_down')
        self.assertEqual(s['alert'], 'realert:homeserver_down')
        recs = self.records()
        self.assertEqual(len(recs), 2)
        self.assertEqual(recs[-1][1]['kind'], 'realert')
        self.assertIn('still host_down for 6.0h', recs[-1][1]['text'])
        self.assertNotEqual(recs[0][1]['dedup'], recs[1][1]['dedup'])
        # Next one is 6h after the re-alert, not 12h after the transition.
        self.assertEqual(self.run_at(t_alert + 11 * HOUR, 'host_down')['alert'], 'none')
        self.assertEqual(self.run_at(t_alert + 12 * HOUR, 'host_down')['alert'], 'realert:homeserver_down')
        self.assertEqual(len(self.records()), 3)

    def test_realert_hours_option(self):
        argv = self.base + ['--realert-hours', '1']
        for i in range(3):
            self.run_at(NOW + i * MINUTE, 'edge', argv=argv)
        t_alert = NOW + 2 * MINUTE
        self.assertEqual(self.run_at(t_alert + 59 * MINUTE, 'edge', argv=argv)['alert'], 'none')
        self.assertEqual(self.run_at(t_alert + 60 * MINUTE, 'edge', argv=argv)['alert'], 'realert:homeserver_edge')

    def test_realert_clock_restarts_on_state_change(self):
        self.settle(NOW, 'up')
        self.settle(NOW + 10 * MINUTE, 'edge')                # edge alert at +12m
        self.settle(NOW + 5 * HOUR, 'host_down')              # host_down alert at 5h+2m
        self.assertEqual(self.codes(), ['homeserver_edge', 'homeserver_down'])
        self.assertEqual(self.run_at(NOW + 6 * HOUR + 13 * MINUTE, 'host_down')['alert'], 'none')
        self.assertEqual(self.run_at(NOW + 11 * HOUR + 2 * MINUTE, 'host_down')['alert'], 'realert:homeserver_down')


class SpoolRecordTest(WatchdogRunBase):
    def test_record_shape_filename_mode_and_atomicity(self):
        self.settle(NOW, 'up')
        self.settle(NOW + 10 * MINUTE, 'host_down')
        [(name, rec)] = self.records()
        self.assertRegex(name, RECORD_NAME)
        self.assertEqual(name, 'health-alert-homeserver_down-%d.json' % int((NOW + 12 * MINUTE) * 1000))
        self.assertEqual(rec['event'], 'health-alert')
        self.assertEqual(rec['code'], 'homeserver_down')
        self.assertEqual(rec['node'], 'seoseo')
        self.assertEqual(rec['recipient'], 'owner')
        expected_ts = datetime.datetime.fromtimestamp(NOW + 12 * MINUTE, datetime.timezone.utc)
        self.assertEqual(rec['ts'], expected_ts.strftime('%Y-%m-%dT%H:%M:%SZ'))
        self.assertRegex(rec['ts'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
        self.assertEqual(rec['status'], 'host_down')
        self.assertEqual(rec['dedup'], 'homeserver-watchdog:homeserver_down:%d:transition' % int(NOW + 10 * MINUTE))
        self.assertTrue(rec['text'].startswith('homeserver watchdog [seoseo]: HOST DOWN'))
        self.assertLessEqual(len(rec['text']), wd.MAX_TEXT)
        self.assertNotIn('100.64.0.2', rec['text'])
        [path] = list(self.spool.glob('*.json'))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.spool.glob('.*')), [], 'no temp file left behind')

    def test_write_is_tmp_then_rename(self):
        seen = {}
        real_rename = wd.os.rename
        def rename(src, dst):
            seen['tmp'] = Path(src).name
            seen['tmp_mode'] = Path(src).stat().st_mode & 0o777
            seen['final'] = Path(dst).name
            real_rename(src, dst)
        with mock.patch.object(wd.os, 'rename', rename):
            wd.spool_alert(self.spool, 'seoseo', {'code': 'homeserver_edge', 'kind': 'transition', 'state': 'edge',
                                                   'since': NOW}, 'text', NOW)
        self.assertEqual(seen['final'], 'health-alert-homeserver_edge-%d.json' % int(NOW * 1000))
        self.assertEqual(seen['tmp'], '.' + seen['final'] + '.tmp')
        self.assertEqual(seen['tmp_mode'], 0o600)

    def test_untrusted_spool_fails_run_and_is_retried(self):
        self.settle(NOW, 'up')
        self.spool.rmdir()
        s = self.settle(NOW + 10 * MINUTE, 'host_down')
        self.assertEqual((s['alert'], s['exit']), ('failed: ValueError', 1))
        self.assertEqual(s['state'], 'host_down', 'the transition is still confirmed and persisted')
        self.assertEqual(json.loads(self.state.read_text())['pending'], 'homeserver_down')
        self.spool.mkdir(mode=0o700)
        s = self.run_at(NOW + 13 * MINUTE, 'host_down')
        self.assertEqual((s['alert'], s['exit']), ('retry:homeserver_down', 0))
        self.assertEqual(self.records()[-1][1]['kind'], 'retry')
        self.assertEqual(self.run_at(NOW + 14 * MINUTE, 'host_down')['alert'], 'none', 'retried once, then quiet')

    def test_symlinked_spool_is_refused(self):
        link = Path(self.dir.name) / 'link'
        link.symlink_to(self.spool)
        argv = [a if a != str(self.spool) else str(link) for a in self.base]
        s = self.settle(NOW, 'edge')
        self.assertEqual(s['alert'], 'transition:homeserver_edge')
        self.state.unlink()
        for i in range(3):
            s = self.run_at(NOW + HOUR + i * MINUTE, 'edge', argv=argv)
        self.assertEqual((s['alert'], s['exit']), ('failed: ValueError', 1))
        self.assertEqual(len(self.records()), 1)

    def test_pending_alert_is_superseded_by_the_next_transition(self):
        argv = self.base + ['--threshold', '1']
        self.run_at(NOW, 'up', argv=argv)
        self.spool.rmdir()
        s = self.run_at(NOW + MINUTE, 'host_down', argv=argv)     # alert failed, pending homeserver_down
        self.assertEqual(s['alert'], 'failed: ValueError')
        self.spool.mkdir(mode=0o700)
        s = self.run_at(NOW + 2 * MINUTE, 'up', argv=argv)        # recovered transition supersedes the stale one
        self.assertEqual(s['alert'], 'transition:homeserver_recovered')
        self.assertEqual(self.codes(), ['homeserver_recovered'])
        self.assertIsNone(json.loads(self.state.read_text())['pending'])
        self.assertEqual(self.run_at(NOW + 3 * MINUTE, 'up', argv=argv)['alert'], 'none')

    def test_without_push_spool_the_alert_is_only_reported(self):
        argv = ['--host', 'h', '--state', str(self.state), '--push-node', 'n', '--json']
        s = None
        for i in range(3):
            s = self.run_at(NOW + i * MINUTE, 'edge', argv=argv)
        self.assertEqual(s['alert'], 'unspooled:transition:homeserver_edge')
        self.assertIn('EDGE DOWN', s['text'])
        self.assertEqual(self.records(), [])


class StateFileTest(WatchdogRunBase):
    def test_round_trip(self):
        self.settle(NOW, 'up')
        self.run_at(NOW + 10 * MINUTE, 'edge')
        data = json.loads(self.state.read_text(encoding='utf-8'))
        self.assertEqual(data['version'], 1)
        self.assertEqual(data['state'], 'up')
        self.assertEqual(data['candidate'], 'edge')
        self.assertEqual([o['state'] for o in data['observations']], ['up', 'up', 'edge'])
        self.assertEqual(data['last']['external'], EXT_530)
        self.assertEqual(data['last']['host'], HOST_UP)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(self.state.parent.glob('.*')), [], 'no temp file left behind')
        # Everything the next run needs survives the round trip (confirmed state + since + last_alert).
        self.settle(NOW + 20 * MINUTE, 'host_down')
        data = json.loads(self.state.read_text(encoding='utf-8'))
        self.assertEqual(data['state'], 'host_down')
        self.assertEqual(data['since'], NOW + 20 * MINUTE)
        self.assertEqual(data['last_alert'], {'host_down': NOW + 22 * MINUTE})
        self.assertEqual(wd.read_state(self.state), data)

    def test_missing_malformed_and_wrong_shape_state_is_tolerated(self):
        self.state.parent.mkdir(mode=0o700)
        for content in ('', 'not json', '[1, 2]', '"up"',
                        json.dumps({'state': 'bogus', 'since': 'x', 'observations': 'nope', 'last_alert': [1],
                                    'pending': 5})):
            self.state.write_text(content, encoding='utf-8')
            s = self.run_at(NOW, 'up')
            self.assertEqual((s['exit'], s['state'], s['streak']), (0, None, 1), content)
        self.state.unlink()
        self.assertEqual(wd.read_state(self.state), {})
        s = self.run_at(NOW, 'up')
        self.assertEqual(s['exit'], 0)

    def test_symlinked_state_file_is_refused(self):
        self.state.parent.mkdir(mode=0o700)
        target = self.state.parent / 'elsewhere.json'
        target.write_text('{}', encoding='utf-8')
        self.state.symlink_to(target)
        err = StringIO()
        with contextlib.redirect_stdout(StringIO()), contextlib.redirect_stderr(err):
            code = wd.main(self.base, external_fn=lambda u, t: EXT_UP, host_fn=lambda h, p, t: HOST_UP,
                           clock=lambda: NOW)
        self.assertEqual(code, 1)
        self.assertIn('ValueError', err.getvalue())

    def test_advance_is_pure_and_keeps_only_threshold_observations(self):
        state, alert = wd.advance({}, 'up', NOW, 3, 6 * HOUR)
        self.assertIsNone(alert)
        self.assertEqual((state['state'], state['streak']), (None, 1))
        for i in range(1, 6):
            state, alert = wd.advance(state, 'up', NOW + i * MINUTE, 3, 6 * HOUR)
        self.assertEqual(len(state['observations']), 3)
        self.assertEqual(state['state'], 'up')
        self.assertIsNone(alert, 'first confirmed up is silent')


class ArgparseAndOutputTest(WatchdogRunBase):
    def test_defaults(self):
        args = wd.parse_args(['--host', 'h'])
        self.assertEqual(args.homeserver_url, 'https://matrix.seoyoon-family.com')
        self.assertEqual((args.host_port, args.timeout, args.threshold, args.realert_hours), (22, 10.0, 3, 6.0))
        self.assertEqual(args.state, '/var/lib/family-messenger-watchdog/state.json')
        self.assertIsNone(args.push_spool)
        self.assertTrue(args.push_node)

    def test_guards(self):
        for bad in ([], ['--host', ' '], ['--host', 'h', '--threshold', '0'], ['--host', 'h', '--realert-hours', '0'],
                    ['--host', 'h', '--timeout', '0'], ['--host', 'h', '--host-port', '70000'],
                    ['--host', 'h', '--homeserver-url', 'matrix.example.com']):
            with self.assertRaises(SystemExit) as cm, contextlib.redirect_stderr(StringIO()):
                wd.parse_args(bad)
            self.assertEqual(cm.exception.code, 2, bad)

    def test_probes_receive_the_arguments(self):
        seen = {}
        argv = ['--host', '100.64.0.9', '--host-port', '2222', '--timeout', '3', '--homeserver-url',
                'https://hs.example.com', '--state', str(self.state), '--json']
        with contextlib.redirect_stdout(StringIO()):
            wd.main(argv, external_fn=lambda u, t: seen.update(ext=(u, t)) or EXT_UP,
                    host_fn=lambda h, p, t: seen.update(host=(h, p, t)) or HOST_UP, clock=lambda: NOW)
        self.assertEqual(seen, {'ext': ('https://hs.example.com', 3.0), 'host': ('100.64.0.9', 2222, 3.0)})

    def test_text_output_without_json(self):
        argv = ['--host', 'h', '--state', str(self.state), '--once']
        out = StringIO()
        with contextlib.redirect_stdout(out):
            code = wd.main(argv, external_fn=lambda u, t: EXT_530, host_fn=lambda h, p, t: HOST_UP, clock=lambda: NOW)
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue().strip(),
                         'None (candidate edge 1/3) external=HTTP 530 host=tcp/22 connect ok alert=none')


class UnitTemplatesTest(unittest.TestCase):
    """deploy/watchdog 유닛 템플릿의 구조·경계 검사 — 실행 없이 파일만 본다."""

    def test_service_shape(self):
        unit = (PKG / 'family-messenger-watchdog.service').read_text(encoding='utf-8')
        for directive in (
            'Type=oneshot',
            'scripts/homeserver_watchdog.py',
            '--push-spool /root/.claude/state/telegram-spool',
            '--push-node ${WATCHDOG_NODE}',
            '--host ${WATCHDOG_HOST}',
            '--state /var/lib/family-messenger-watchdog/state.json',
            'EnvironmentFile=/etc/family-messenger/watchdog.env',
            'StateDirectory=family-messenger-watchdog',
            'StateDirectoryMode=0700',
            'UMask=0077',
            'NoNewPrivileges=true',
        ):
            self.assertIn(directive, unit, directive)
        self.assertNotIn('User=', unit, 'runs as root: the spool lives under /root')
        self.assertNotIn('tuwunel.service', unit, 'off-host: must not order after the homeserver unit')

    def test_timer_shape(self):
        timer = (PKG / 'family-messenger-watchdog.timer').read_text(encoding='utf-8')
        for directive in ('OnBootSec=2min', 'OnUnitActiveSec=1min', 'RandomizedDelaySec=10', 'Persistent=false',
                          'Unit=family-messenger-watchdog.service', 'WantedBy=timers.target'):
            self.assertIn(directive, timer, directive)

    def test_no_real_hosts_or_secrets(self):
        for name in ('family-messenger-watchdog.service', 'family-messenger-watchdog.timer', 'watchdog.env.example'):
            text = (PKG / name).read_text(encoding='utf-8')
            self.assertNotRegex(text, r'seoyoon-family\.com|racknerd|vps\d', name)
            self.assertNotRegex(text, r'BEGIN [A-Z ]*PRIVATE KEY|token|secret', name)
        env = (PKG / 'watchdog.env.example').read_text(encoding='utf-8')
        self.assertIn('WATCHDOG_HOST=', env)
        self.assertIn('WATCHDOG_NODE=', env)
        readme = (PKG / 'README.md').read_text(encoding='utf-8')
        for needle in ('homeserver_down', 'homeserver_edge', 'homeserver_recovered', '별도', '6', 'edge', 'host_down'):
            self.assertIn(needle, readme, needle)


if __name__ == '__main__':
    unittest.main()
