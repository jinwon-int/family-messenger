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
                       'https://relay.example.test/v2/health': [502, 502, 502, 200],
                       'http://127.0.0.1:18921/v2/health': [None, 200]})

    def test_classification_matrix(self):
        self.assertEqual(cut.classify(False, False), 'relay-down')
        self.assertEqual(cut.classify(True, False), 'edge-only')
        self.assertEqual(cut.classify(False, True), 'peer-unreachable')
        self.assertEqual(cut.classify(True, True), 'healthy')

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
        self.assertEqual(len(record['plan']['confirm']), 12)
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
                         ['probe', 'plan', 'peer_stop', 'restore', 'fence', 'start', 'dns', 'edge', 'client_hook'])
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
        self.assertEqual(record['steps'][6]['detail'],
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
                         'http://127.0.0.1:18921/v2/health': [None]})
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

    def test_real_cutover_requires_dns_arguments(self):
        with self.assertRaises(SystemExit):
            cut.parse(['--to', 'x', '--fence-record', 'r', '--peer-health', 'u', '--inbox', str(self.inbox),
                       '--target-data-dir', 'a', '--target-policy-dir', 'b'])
        args = cut.parse(['--to', 'x', '--fence-record', 'r', '--peer-health', 'u', '--inbox', str(self.inbox),
                          '--target-data-dir', 'a', '--target-policy-dir', 'b', '--dry-run'])
        self.assertTrue(args.dry_run)


if __name__ == '__main__':
    unittest.main()
