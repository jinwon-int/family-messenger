import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
sys.path.insert(0, str(Path(__file__).parent))
import native_relay_cutover as cut
import native_relay_snapshot as snap
from test_native_relay_snapshot import args_for

ZONE = 'zone123'
TUNNEL = 'abcd-1234.cfargotunnel.com'


class FakeResponse(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class FakeCloudflare:
    """Records every API call; serves existing records from a dict keyed (type, name)."""

    def __init__(self, records=None):
        self.records = dict(records or {})
        self.calls = []

    def __call__(self, request, timeout=None):
        path = request.full_url[len(cut.CF_API):]
        body = json.loads(request.data.decode()) if request.data else None
        self.calls.append((request.get_method(), path, body))
        assert request.get_header('Authorization') == 'Bearer dns-token-value'
        if request.get_method() == 'GET':
            query = dict(part.split('=') for part in path.split('?', 1)[1].split('&'))
            found = self.records.get((query['type'], query['name']))
            return FakeResponse(json.dumps({'success': True, 'result': [found] if found else []}).encode())
        if request.get_method() == 'PUT':
            rid = path.rsplit('/', 1)[1]
            for key, rec in self.records.items():
                if rec['id'] == rid:
                    self.records[key] = dict(rec, **body)
            return FakeResponse(json.dumps({'success': True, 'result': {'id': rid}}).encode())
        if request.get_method() == 'POST':
            rid = 'new-' + body['name']
            self.records[(body['type'], body['name'])] = dict(body, id=rid)
            return FakeResponse(json.dumps({'success': True, 'result': {'id': rid}}).encode())
        raise AssertionError('unexpected method ' + request.get_method())


class Status:
    """Scripted HTTP statuses per URL: a list is consumed call by call, last value sticks."""

    def __init__(self, table):
        self.table = {k: list(v) for k, v in table.items()}
        self.calls = []

    def __call__(self, url, headers=None, timeout=None):
        self.calls.append((url, dict(headers or {})))
        values = self.table.get(url, [None])
        return values.pop(0) if len(values) > 1 else values[0]


class Runner:
    def __init__(self, fail=()):
        self.commands = []
        self.fail = set(fail)

    def __call__(self, command, **kwargs):
        self.commands.append(' '.join(command))
        rc = 1 if command[0] in self.fail or ' '.join(command) in self.fail else 0
        return mock.Mock(returncode=rc, stdout='inactive\n' if 'is-active' in command else '',
                         stderr='boom' if rc else '')


class CutoverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.inbox = self.root / 'snapshots' / 'inbox'
        self.inbox.mkdir(parents=True)
        payload = snap.snapshot(args_for(self.root / 'source', self.root / 'snapshots' / 'local'))
        archive = Path(payload['archive'])
        (self.inbox / archive.name).write_bytes(archive.read_bytes())
        (self.inbox / (archive.name + '.sha256')).write_text(archive.with_suffix('.gz.sha256').read_text())
        self.archive = self.inbox / archive.name
        self.target = self.root / 'live'
        (self.root / 'dns.env').write_text('CF_DNS_TOKEN=dns-token-value\n')
        (self.root / 'edge.env').write_text('CF_ACCESS_CLIENT_ID=id\nCF_ACCESS_CLIENT_SECRET=secret\n')
        self.clock = [0.0]

    def tearDown(self):
        self.tmp.cleanup()

    def argv(self, *extra):
        return ['--to', 'soonwook', '--fence-record', '_native-relay-active.example.test',
                '--peer-health', 'http://100.64.0.1:18921/v2/health',
                '--edge-health', 'https://relay.example.test/v2/health',
                '--edge-token-file', str(self.root / 'edge.env'),
                '--probe-interval', '0', '--inbox', str(self.inbox),
                '--target-data-dir', str(self.target / 'data'), '--target-policy-dir', str(self.target / 'policy'),
                '--target-static-dir', str(self.target / 'static'), '--skip-unit-check', '--owner', '',
                '--cf-zone-id', ZONE, '--cf-dns-token-file', str(self.root / 'dns.env'),
                '--hostname', 'relay.example.test', '--hostname', 'hande.example.test', '--tunnel-target', TUNNEL,
                '--client-hook', 'ssh gongmyoung systemctl restart native-relay-bot', *extra]

    def io(self, status, cf, runner, fence_after_upsert=True):
        def fence_check(expect, record):
            fenced = ('TXT', record) in cf.records and cf.records[('TXT', record)]['content'] == expect
            return (0, 'ok') if (fenced and fence_after_upsert) else (1, 'other')

        def tick(seconds):
            self.clock[0] += seconds
        return {'status': status, 'opener': cf, 'runner': runner, 'sleep': tick, 'clock': lambda: self.clock[0],
                'fence_check': fence_check}

    def down_status(self):
        return Status({'http://100.64.0.1:18921/v2/health': [None],
                       'https://relay.example.test/v2/health': [502, 502, 502, 502, 200],
                       'http://127.0.0.1:18921/v2/health': [None, 200]})

    def test_classification_matrix(self):
        self.assertEqual(cut.classify(False, False), 'relay-down')
        self.assertEqual(cut.classify(True, False), 'edge-only')
        self.assertEqual(cut.classify(False, True), 'peer-unreachable')
        self.assertEqual(cut.classify(True, True), 'healthy')
        self.assertEqual(cut.classify(False, None), 'edge-unknown', 'H2: an unprobed edge never means relay-down')

    def test_probe_uses_service_token_and_any_200_counts(self):
        args = cut.parse(self.argv('--probe-tries', '3'))
        status = Status({'http://100.64.0.1:18921/v2/health': [None, None, 200],
                         'https://relay.example.test/v2/health': [502]})
        result = cut.probe(args, status=status, sleep=lambda s: None)
        self.assertEqual(result['classification'], 'edge-only')
        self.assertEqual(len(result['samples']), 3)
        edge_calls = [h for u, h in status.calls if 'relay.example.test' in u]
        self.assertEqual(edge_calls[0]['CF-Access-Client-Id'], 'id')

    def test_not_down_stops_before_any_change(self):
        cf = FakeCloudflare(); runner = Runner()
        status = Status({'http://100.64.0.1:18921/v2/health': [200], 'https://relay.example.test/v2/health': [502]})
        record = cut.cutover(cut.parse(self.argv('--confirm', 'x')), self.io(status, cf, runner))
        self.assertEqual(record['status'], 'not-down:edge-only')
        self.assertEqual(cf.calls, [])
        self.assertEqual(runner.commands, [])
        self.assertFalse((self.target / 'data').exists())

    def test_unconfirmed_prints_token_and_changes_nothing(self):
        cf = FakeCloudflare(); runner = Runner()
        record = cut.cutover(cut.parse(self.argv()), self.io(self.down_status(), cf, runner))
        self.assertEqual(record['status'], 'unconfirmed')
        self.assertEqual(len(record['plan']['confirm']), 16)
        self.assertEqual(record['plan']['manifest']['policy_revision'], 19)
        self.assertEqual(cf.calls, [])
        self.assertFalse((self.target / 'data').exists())
        wrong = cut.cutover(cut.parse(self.argv('--confirm', 'nope')), self.io(self.down_status(), cf, runner))
        self.assertEqual(wrong['status'], 'unconfirmed')

    def test_dry_run_changes_nothing(self):
        cf = FakeCloudflare(); runner = Runner()
        record = cut.cutover(cut.parse(self.argv('--dry-run')), self.io(self.down_status(), cf, runner))
        self.assertEqual(record['status'], 'dry-run')
        self.assertEqual(cf.calls, [])
        self.assertFalse((self.target / 'data').exists())

    def test_full_cutover_order_and_effects(self):
        cf = FakeCloudflare({
            ('CNAME', 'relay.example.test'): {'id': 'r1', 'type': 'CNAME', 'name': 'relay.example.test',
                                              'content': 'old.cfargotunnel.com', 'proxied': True},
            ('TXT', '_native-relay-active.example.test'): {'id': 't1', 'type': 'TXT', 'content': 'seoseo',
                                                           'name': '_native-relay-active.example.test',
                                                           'proxied': False}})
        runner = Runner()
        plan = cut.cutover(cut.parse(self.argv()), self.io(self.down_status(), cf, runner))['plan']
        argv = self.argv('--confirm', plan['confirm'], '--peer-stop-cmd', 'ssh seoseo systemctl stop native-relay',
                         '--state', str(self.root / 'state'))
        record = cut.cutover(cut.parse(argv), self.io(self.down_status(), cf, runner))
        self.assertEqual(record['status'], 'complete', record)
        self.assertEqual([s['step'] for s in record['steps']],
                         ['probe', 'plan', 'peer_stop', 'restore', 'fence', 'reprobe', 'start', 'dns', 'edge',
                          'client_hook'])
        # fence TXT is rewritten BEFORE the relay starts and BEFORE the CNAMEs move
        methods = [(m, p.split('?')[0]) for m, p, _ in cf.calls]
        txt_put = methods.index(('PUT', '/zones/zone123/dns_records/t1'))
        cname_put = methods.index(('PUT', '/zones/zone123/dns_records/r1'))
        cname_post = methods.index(('POST', '/zones/zone123/dns_records'))
        self.assertLess(txt_put, cname_put)
        self.assertLess(txt_put, cname_post)
        start_idx = runner.commands.index('systemctl start native-relay')
        self.assertLess(runner.commands.index('ssh seoseo systemctl stop native-relay'), start_idx)
        self.assertEqual(cf.records[('TXT', '_native-relay-active.example.test')]['content'], 'soonwook')
        self.assertEqual(cf.records[('CNAME', 'relay.example.test')]['content'], TUNNEL)
        self.assertEqual(cf.records[('CNAME', 'hande.example.test')]['content'], TUNNEL)
        self.assertTrue(cf.records[('CNAME', 'hande.example.test')]['proxied'])
        self.assertEqual(record['steps'][7]['detail'],
                         {'relay.example.test': 'updated', 'hande.example.test': 'created'})
        self.assertIn('ssh gongmyoung systemctl restart native-relay-bot', runner.commands)
        db = sqlite3.connect(str(self.target / 'data' / snap.DB_NAME))
        self.assertEqual(db.execute("SELECT last_seq FROM mls_rooms WHERE room='family-acc'").fetchone()[0], 1179)
        db.close()
        self.assertEqual(record['steps'][3]['detail']['rooms']['family-acc'], {'before': 179, 'after': 1179})
        files = list((self.root / 'state').glob('cutover-*.json'))
        self.assertEqual(len(files), 1)
        self.assertNotIn('dns-token-value', files[0].read_text())
        self.assertNotIn('secret', files[0].read_text())

    def test_relay_not_healthy_stops_before_dns(self):
        cf = FakeCloudflare(); runner = Runner()
        status = Status({'http://100.64.0.1:18921/v2/health': [None], 'https://relay.example.test/v2/health': [502],
                         'http://127.0.0.1:18921/v2/health': [None]})  # peer stays dead through the re-probe
        plan = cut.cutover(cut.parse(self.argv()), self.io(status, cf, runner))['plan']
        record = cut.cutover(cut.parse(self.argv('--confirm', plan['confirm'], '--start-wait', '3')),
                             self.io(status, cf, runner))
        self.assertEqual(record['status'], 'failed')
        self.assertEqual(record['steps'][-1]['step'], 'start')
        self.assertFalse(record['steps'][-1]['ok'])
        self.assertNotIn(('CNAME', 'relay.example.test'), cf.records, 'DNS must not move to an unhealthy relay')
        self.assertEqual(cf.records[('TXT', '_native-relay-active.example.test')]['content'], 'soonwook',
                         'fence already moved — the record shows exactly where it stopped')

    def test_hook_failure_is_recorded_not_fatal(self):
        cf = FakeCloudflare(); runner = Runner(fail={'ssh gongmyoung systemctl restart native-relay-bot'})
        plan = cut.cutover(cut.parse(self.argv()), self.io(self.down_status(), cf, runner))['plan']
        record = cut.cutover(cut.parse(self.argv('--confirm', plan['confirm'])),
                             self.io(self.down_status(), cf, runner))
        self.assertEqual(record['status'], 'complete-with-hook-failures')
        self.assertEqual(cf.records[('CNAME', 'relay.example.test')]['content'], TUNNEL)

    # --- regression tests from the adversarial review (2026-10-19) ---

    def test_H1_peer_back_after_fence_stops_before_start(self):
        cf = FakeCloudflare(); runner = Runner()
        status = Status({'http://100.64.0.1:18921/v2/health': [None, None, None, 200],
                         'https://relay.example.test/v2/health': [502]})
        plan = cut.cutover(cut.parse(self.argv()), self.io(self.down_status(), cf, runner))['plan']
        record = cut.cutover(cut.parse(self.argv('--confirm', plan['confirm'])), self.io(status, cf, runner))
        self.assertEqual(record['status'], 'failed')
        self.assertEqual(record['steps'][-1]['step'], 'reprobe')
        self.assertNotIn('systemctl start native-relay', runner.commands, 'a second writer must not start')
        self.assertNotIn(('CNAME', 'relay.example.test'), cf.records)

    def test_H1_peer_stop_failure_is_fatal_unless_host_known_dead(self):
        cf = FakeCloudflare(); runner = Runner(fail={'ssh seoseo systemctl stop native-relay'})
        plan = cut.cutover(cut.parse(self.argv()), self.io(self.down_status(), cf, runner))['plan']
        record = cut.cutover(cut.parse(self.argv('--confirm', plan['confirm'], '--peer-stop-cmd',
                                                 'ssh seoseo systemctl stop native-relay')),
                             self.io(self.down_status(), cf, runner))
        self.assertEqual(record['status'], 'failed')
        self.assertEqual(record['steps'][-1]['step'], 'peer_stop')
        self.assertFalse((self.target / 'data').exists(), 'nothing restored after a failed peer stop')
        record = cut.cutover(cut.parse(self.argv('--confirm', plan['confirm'], '--peer-stop-cmd',
                                                 'ssh seoseo systemctl stop native-relay', '--peer-unreachable-ok')),
                             self.io(self.down_status(), cf, Runner(fail={'ssh seoseo systemctl stop native-relay'})))
        self.assertEqual(record['status'], 'complete')

    def test_H2_edge_health_is_required_to_probe(self):
        base = [a for a in self.argv() if a not in ('--edge-health', 'https://relay.example.test/v2/health')]
        with self.assertRaises(SystemExit):
            cut.parse(base)
        self.assertTrue(cut.parse(base + ['--skip-probe']).skip_probe)

    def test_M1_run_cmd_never_raises(self):
        def timeout_runner(command, **kwargs):
            raise cut.subprocess.TimeoutExpired(command, kwargs.get('timeout'))
        result = cut.run_cmd('ssh seoseo systemctl start native-relay-snapshot.service', 1, timeout_runner)
        self.assertIsNone(result['exit']); self.assertIn('timeout', result['error'])
        result = cut.run_cmd('/no/such/binary --x', 1, lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError('nope')))
        self.assertIsNone(result['exit']); self.assertIn('FileNotFoundError', result['error'])

    def test_M2_confirm_token_binds_tunnel_hostnames_bump(self):
        cf = FakeCloudflare(); runner = Runner()
        plan = cut.cutover(cut.parse(self.argv()), self.io(self.down_status(), cf, runner))['plan']
        for variant in (self.argv('--tunnel-target', 'WRONG.cfargotunnel.com'), self.argv('--bump-seq', '0'),
                        self.argv('--hostname', 'extra.example.test')):
            other = cut.cutover(cut.parse(variant), self.io(self.down_status(), cf, runner))['plan']
            self.assertNotEqual(other['confirm'], plan['confirm'])

    def test_N3_peer_snapshot_runs_in_the_plan_run_only(self):
        cf = FakeCloudflare()
        newer = self.inbox / 'relay-29991231T235959Z.tar.gz'
        snapshots = []

        def runner(command, **kwargs):
            if 'snapshot' in command[-1]:
                snapshots.append(1)
                newer.write_bytes(self.archive.read_bytes())
                (self.inbox / (newer.name + '.sha256')).write_text(
                    snap.sha256_file(newer) + '  ' + newer.name + '\n')
            return mock.Mock(returncode=0, stdout='', stderr='')
        argv = self.argv('--peer-snapshot-cmd', 'ssh seoseo systemctl start native-relay-snapshot.service')
        first = cut.cutover(cut.parse(argv), self.io(self.down_status(), cf, runner))
        self.assertEqual(first['status'], 'unconfirmed')
        self.assertEqual([s['step'] for s in first['steps']][:2], ['probe', 'peer_snapshot'])
        self.assertEqual(Path(first['plan']['archive']).name, newer.name, 'the token names the fresh archive')
        self.assertEqual(len(snapshots), 1)
        second = cut.cutover(cut.parse(argv + ['--confirm', first['plan']['confirm']]),
                             self.io(self.down_status(), cf, runner))
        self.assertEqual(second['status'], 'complete', second)
        self.assertEqual(len(snapshots), 1, 'the confirm run never takes another snapshot')
        self.assertNotIn('peer_snapshot', [s['step'] for s in second['steps']])
        self.assertEqual(Path(second['plan']['archive']).name, newer.name, 'the confirmed archive is restored')

    def test_N1_example_argfile_parses_with_comments_blank_lines_and_crlf(self):
        example = Path(__file__).parents[1] / 'deploy' / 'native-relay' / 'cutover.args.example'
        args = cut.parse(['@' + str(example)])
        self.assertEqual(args.to, 'soonwook')
        self.assertEqual(args.hostname, ['relay.example.test', 'hande.example.test'])
        self.assertEqual(args.peer_stop_cmd,
                         'ssh -o BatchMode=yes -o ConnectTimeout=10 seoseo systemctl stop native-relay')
        crlf = self.root / 'args.txt'
        crlf.write_bytes(b'# comment\r\n\r\n--to\r\nsoonwook \r\n--fence-record\r\nr\r\n--peer-health\r\nu\r\n'
                         b'--inbox\r\n' + str(self.inbox).encode() + b'\r\n--target-data-dir\r\na\r\n'
                         b'--target-policy-dir\r\nb\r\n--dry-run\r\n--skip-probe\r\n')
        self.assertEqual(cut.parse(['@' + str(crlf)]).to, 'soonwook')

    def test_N5_start_exit_nonzero_is_tolerated_when_health_comes_up(self):
        cf = FakeCloudflare(); runner = Runner(fail={'systemctl start native-relay'})
        plan = cut.cutover(cut.parse(self.argv()), self.io(self.down_status(), cf, runner))['plan']
        record = cut.cutover(cut.parse(self.argv('--confirm', plan['confirm'])),
                             self.io(self.down_status(), cf, runner))
        self.assertEqual(record['status'], 'complete')
        start = next(s for s in record['steps'] if s['step'] == 'start')
        self.assertEqual(start['detail'], {'health': 200, 'start_exit': 1})
        self.assertEqual(cut.parse(self.argv()).start_wait, 120.0)

    def test_N6_redaction_patterns(self):
        cases = {
            'x --token abc': 'x --token <redacted>',
            'x --access-token=abc': 'x --access-token=<redacted>',
            'curl https://user:pw@host/p': 'curl https://<redacted>@host/p',
            'X-Auth-Key: abc def': 'X-Auth-Key: <redacted>',
            'api_key=abc': 'api_key=<redacted>',
            'password=abc': 'password=<redacted>',
            'CF_API_KEY=abc': 'CF_API_KEY=<redacted>',
        }
        for raw, expect in cases.items():
            self.assertEqual(cut.redact(raw), expect, raw)
        self.assertEqual(cut.redact('ssh host /usr/local/sbin/repoint http://100.64.0.2:18921'),
                         'ssh host /usr/local/sbin/repoint http://100.64.0.2:18921', 'plain hooks are untouched')

    def test_M3_redirects_are_not_health(self):
        class Redirecting:
            def open(self, request, timeout=None):
                raise cut.urllib.error.HTTPError(request.full_url, 302, 'Found', {}, None)
        self.assertEqual(cut.http_status('https://relay.example.test/v2/health', opener=Redirecting().open), 302)
        self.assertIsInstance(cut.OPENER.handlers[0], cut.urllib.request.BaseHandler)
        self.assertTrue(any(isinstance(h, cut.NoRedirect) for h in cut.OPENER.handlers))

    def test_probe_sends_a_non_python_user_agent(self):
        seen = {}

        def opener(request, timeout=None):
            seen['ua'] = request.get_header('User-agent')
            seen['id'] = request.get_header('Cf-access-client-id')
            raise cut.urllib.error.HTTPError(request.full_url, 200, 'OK', {}, None)
        cut.http_status('https://relay.example.test/v2/health', headers={'CF-Access-Client-Id': 'id'}, opener=opener)
        self.assertEqual(seen['ua'], cut.USER_AGENT)
        self.assertFalse(seen['ua'].lower().startswith('python-urllib'), 'Cloudflare answers 403 to the default UA')
        self.assertEqual(seen['id'], 'id', 'caller headers are preserved')

    def test_M4_probe_tries_below_one_is_rejected(self):
        with self.assertRaises(SystemExit):
            cut.parse(self.argv('--probe-tries', '0'))

    def test_M5_fence_requires_consecutive_reads(self):
        cf = FakeCloudflare(); runner = Runner()
        plan = cut.cutover(cut.parse(self.argv()), self.io(self.down_status(), cf, runner))['plan']
        io = self.io(self.down_status(), cf, runner)
        flaps = iter([0, 1, 0, 0, 0, 0, 0, 0])
        io['fence_check'] = lambda expect, record: (next(flaps, 0), '')
        record = cut.cutover(cut.parse(self.argv('--confirm', plan['confirm'], '--fence-settle', '3')), io)
        self.assertEqual(record['status'], 'complete')
        fence_step = next(s for s in record['steps'] if s['step'] == 'fence')
        self.assertEqual(fence_step['detail']['consecutive_reads'], 3)
        self.assertEqual(cut.parse(self.argv()).fence_wait, 300.0)

    def test_M7_newest_archive_without_sidecar_is_ignored(self):
        orphan = self.inbox / 'relay-29991231T235959Z.tar.gz'
        orphan.write_bytes(b'partial')
        self.assertEqual(cut.latest_archive(self.inbox), self.archive)

    def test_L2_record_filename_has_Z_suffix(self):
        path = cut.write_record(self.root / 'state', {'started_at': '2026-10-19T12:34:56+00:00'})
        self.assertEqual(path.name, 'cutover-2026-10-19T123456Z.json')

    def test_L7_quoted_txt_content_counts_as_unchanged(self):
        cf = FakeCloudflare({('TXT', 'f.example.test'): {'id': 't1', 'type': 'TXT', 'name': 'f.example.test',
                                                         'content': '"soonwook"', 'proxied': False, 'ttl': 60}})
        action, _ = cf.records and cut.dns_upsert('dns-token-value', ZONE, 'f.example.test', 'TXT', 'soonwook', False,
                                                  opener=cf)
        self.assertEqual(action, 'unchanged')

    def test_L8_hook_output_is_redacted(self):
        self.assertEqual(cut.redact('curl -H "Authorization: Bearer abc.def" x'),
                         'curl -H "Authorization: <redacted>" x')
        self.assertEqual(cut.redact('ssh host cmd --token=abc123'), 'ssh host cmd --token=<redacted>')

    def test_L5_hook_failure_exit_code(self):
        self.assertEqual(cut.EXIT_HOOKS, 3)

    def test_real_cutover_requires_dns_arguments(self):
        with self.assertRaises(SystemExit):
            cut.parse(['--to', 'x', '--fence-record', 'r', '--peer-health', 'u', '--inbox', str(self.inbox),
                       '--target-data-dir', 'a', '--target-policy-dir', 'b'])
        args = cut.parse(['--to', 'x', '--fence-record', 'r', '--peer-health', 'u', '--inbox', str(self.inbox),
                          '--target-data-dir', 'a', '--target-policy-dir', 'b', '--dry-run', '--skip-probe'])
        self.assertTrue(args.dry_run)


if __name__ == '__main__':
    unittest.main()
