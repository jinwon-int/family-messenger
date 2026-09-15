"""scripts/health_check.py — 타이머 운영 헬스 점검의 단위 검사(네트워크·systemd 없이)."""
import contextlib
import datetime
import json
from io import StringIO
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock
from urllib.error import URLError

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import health_check as hc

NOW = 1_800_000_000.0
FRESH = NOW - 3 * 3600          # 3h 전 — 기본 26h 한도 안
STALE = NOW - 30 * 3600         # 30h 전 — 한도 밖
FAKE_CFG = {'base': 'http://127.0.0.1:8008', 'server_name': 'example.com'}


@contextlib.contextmanager
def fake_admin(room_class):
    with mock.patch.object(hc, 'load_tuwunel_config', return_value=FAKE_CFG), \
            mock.patch.object(hc, 'load_admin_token', return_value='token'), \
            mock.patch.object(hc, 'AdminRoom', room_class):
        yield


def write_record(directory, name, created_at, status='complete'):
    path = Path(directory) / name
    path.write_text(json.dumps({'pair': name.removesuffix('.json'), 'created_at': created_at,
                                'status': status}), encoding='utf-8')
    return path


def iso(epoch):
    import datetime
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')


def fake_fetch(statuses):
    def fetch(url):
        code = statuses[url]
        if isinstance(code, Exception):
            raise code
        return code
    return fetch


def fake_units(states):
    return lambda name: states[name]


def bot_db(directory, health=None):
    path = Path(directory) / 'inbox.sqlite3'
    db = sqlite3.connect(path)
    db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)')
    if health is not None:
        db.execute("INSERT INTO meta VALUES ('health', ?)", (json.dumps(health),))
    db.commit()
    db.close()
    return path


class UrlCheckTest(unittest.TestCase):
    def test_fetch_sends_custom_user_agent(self):
        # CF 터널은 urllib 기본 UA에 403 — 커스텀 UA를 보내야 한다(2026-09-16 실측).
        captured = {}
        class Resp:
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False
            status = 200
        class FakeOpener:
            def open(self, req, timeout):
                captured['ua'] = req.headers.get('User-agent')
                return Resp()
        with mock.patch.object(hc.urllib.request, 'build_opener', return_value=FakeOpener()):
            self.assertEqual(hc.fetch('http://127.0.0.1:8/versions'), 200)
        self.assertEqual(captured['ua'], 'family-messenger-health/1')

    def test_ok_and_fail_and_error(self):
        args = hc.parse_args(['--url', 'http://127.0.0.1:8008/_matrix/client/v3/versions'])
        fetch = fake_fetch({'http://127.0.0.1:8008/_matrix/client/v3/versions': 200})
        checks = hc.run_checks(args, NOW, fetch, lambda n: 'active')
        self.assertTrue(checks[0]['ok'])
        fetch = fake_fetch({'http://127.0.0.1:8008/_matrix/client/v3/versions': 503})
        checks = hc.run_checks(args, NOW, fetch, lambda n: 'active')
        self.assertFalse(checks[0]['ok'])
        self.assertIn('503', checks[0]['detail'])
        fetch = fake_fetch({'http://127.0.0.1:8008/_matrix/client/v3/versions': URLError('refused')})
        checks = hc.run_checks(args, NOW, fetch, lambda n: 'active')
        self.assertFalse(checks[0]['ok'])
        self.assertIn('error:', checks[0]['detail'])


class UnitCheckTest(unittest.TestCase):
    def test_active_and_failed(self):
        args = hc.parse_args(['--require-active', 'tuwunel.service', '--require-active', 'x.service'])
        checks = hc.run_checks(args, NOW, fake_fetch({}),
                               fake_units({'tuwunel.service': 'active', 'x.service': 'failed'}))
        self.assertEqual([c['ok'] for c in checks], [True, False])


class BackupFreshnessTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.args = hc.parse_args(['--backup-state', self.dir.name])

    def test_fresh_complete_record(self):
        write_record(self.dir.name, 'tuwunel-20260915T120000Z-abc.json', iso(FRESH))
        checks = hc.run_checks(self.args, NOW, fake_fetch({}), lambda n: 'active')
        self.assertTrue(checks[0]['ok'])
        self.assertIn('backup-freshness', checks[0]['name'])

    def test_stale_record_fails(self):
        write_record(self.dir.name, 'tuwunel-20260914T120000Z-abc.json', iso(STALE))
        checks = hc.run_checks(self.args, NOW, fake_fetch({}), lambda n: 'active')
        self.assertFalse(checks[0]['ok'])

    def test_missing_record_fails(self):
        checks = hc.run_checks(self.args, NOW, fake_fetch({}), lambda n: 'active')
        self.assertFalse(checks[0]['ok'])
        self.assertIn('no complete', checks[0]['detail'])

    def test_newest_incomplete_is_ignored_older_complete_decides(self):
        # 실패 실행은 기록 json을 쓰지 않으므로(모듈 규약), 불완전 파일은 신선성 후보에서 제외한다.
        write_record(self.dir.name, 'tuwunel-20260915T130000Z-new.json', iso(NOW - 60), status='partial')
        write_record(self.dir.name, 'tuwunel-20260915T120000Z-old.json', iso(FRESH))
        checks = hc.run_checks(self.args, NOW, fake_fetch({}), lambda n: 'active')
        self.assertTrue(checks[0]['ok'])
        self.assertIn('old', checks[0]['detail'])

    def test_unparseable_record_is_skipped(self):
        (Path(self.dir.name) / 'tuwunel-20260915T130000Z-bad.json').write_text('not json', encoding='utf-8')
        write_record(self.dir.name, 'tuwunel-20260915T120000Z-ok.json', iso(FRESH))
        checks = hc.run_checks(self.args, NOW, fake_fetch({}), lambda n: 'active')
        self.assertTrue(checks[0]['ok'])

    def test_created_at_parsed_as_utc(self):
        # created_at은 UTC Z 형식이다 — KST로 해석하면 9시간 어긋난다.
        record = write_record(self.dir.name, 'tuwunel-20260915T120000Z-abc.json', '20260915T120000Z')
        _, created = hc.newest_complete_record(Path(self.dir.name))
        expected = datetime.datetime(2026, 9, 15, 12, 0, tzinfo=datetime.timezone.utc).timestamp()
        self.assertEqual(created.timestamp(), expected)
        self.assertEqual(record.name, 'tuwunel-20260915T120000Z-abc.json')


class BotFreshnessTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def run_bot(self, health, max_age=600.0):
        kwargs = {} if health is None else {'health': health}
        path = bot_db(self.dir.name, **kwargs)
        args = hc.parse_args(['--bot-state', str(path), '--max-bot-age-seconds', str(max_age)])
        return hc.run_checks(args, NOW, fake_fetch({}), lambda n: 'active')[0]

    def test_fresh_ready_bot(self):
        check = self.run_bot({'state': 'ready', 'updated': NOW - 10})
        self.assertTrue(check['ok'])

    def test_stale_bot_fails(self):
        self.assertFalse(self.run_bot({'state': 'ready', 'updated': NOW - 4000})['ok'])

    def test_not_ready_fails(self):
        self.assertFalse(self.run_bot({'state': 'stopped', 'updated': NOW - 10})['ok'])

    def test_missing_mark_and_missing_file_fail(self):
        self.assertFalse(self.run_bot(None)['ok'])
        args = hc.parse_args(['--bot-state', str(Path(self.dir.name) / 'absent.sqlite3')])
        check = hc.run_checks(args, NOW, fake_fetch({}), lambda n: 'active')[0]
        self.assertFalse(check['ok'])
        self.assertTrue(check['detail'].startswith('FileNotFoundError'))


class TransitionAlertTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.state = Path(self.dir.name) / 'state.json'
        self.base = ['--alert-admin', '--config', 'x.toml', '--admin-token-file', 't', '--state-file', str(self.state)]

    def alerts(self, argv, unhealthy_names=('url u',)):
        sent = []
        class FakeRoom:
            def __init__(self, *a):
                pass
            def notice(self, text):
                sent.append(text)
                return '$ev'
        with fake_admin(FakeRoom):
            alert = hc.transition_alert(hc.parse_args(argv), list(unhealthy_names), bool(unhealthy_names), NOW)
        return alert, sent

    def test_first_run_records_without_notice(self):
        alert, sent = self.alerts(self.base + ['--url', 'u'], unhealthy_names=('url u',))
        self.assertEqual(alert, 'recorded')
        self.assertEqual(sent, [])
        self.assertEqual(json.loads(self.state.read_text())['status'], 'unhealthy')

    def test_unchanged_and_recovery(self):
        self.alerts(self.base + ['--url', 'u'], unhealthy_names=())
        alert, sent = self.alerts(self.base + ['--url', 'u'], unhealthy_names=('url u',))
        self.assertEqual(alert, 'sent')
        self.assertIn('UNHEALTHY', sent[0])
        self.assertIn('url u', sent[0])
        alert, sent = self.alerts(self.base + ['--url', 'u'], unhealthy_names=())
        self.assertEqual(alert, 'sent')
        self.assertIn('recovered', sent[0])

    def test_unchanged_repeat_is_silent(self):
        self.alerts(self.base + ['--url', 'u'], unhealthy_names=())
        alert, sent = self.alerts(self.base + ['--url', 'u'], unhealthy_names=())
        self.assertEqual(alert, 'unchanged')
        self.assertEqual(sent, [])

    def test_failed_notice_still_records(self):
        # 첫 실행(healthy 기록) 후의 전환에서만 통지를 시도한다 — Dead 방으로의 전환은 'failed'.
        self.alerts(self.base + ['--url', 'u'], unhealthy_names=())
        class Dead:
            def __init__(self, *a):
                raise RuntimeError('down')
        argv = self.base + ['--url', 'u']
        with fake_admin(Dead):
            alert = hc.transition_alert(hc.parse_args(argv), ['url u'], True, NOW)
        self.assertEqual(alert, 'failed')
        self.assertEqual(json.loads(self.state.read_text())['status'], 'unhealthy')


class MainTest(unittest.TestCase):
    def test_exit_codes_and_json_shape(self):
        argv = ['--url', 'http://127.0.0.1:1/versions', '--require-active', 'x.service']
        out = StringIO()
        with contextlib.redirect_stdout(out):
            code = hc.main(argv, fetch_fn=fake_fetch({'http://127.0.0.1:1/versions': 200}),
                           unit_fn=fake_units({'x.service': 'active'}), clock=lambda: NOW)
        self.assertEqual(code, 0)
        result = json.loads(out.getvalue())
        self.assertEqual(result['status'], 'healthy')
        self.assertEqual(len(result['checks']), 2)
        out = StringIO()
        with contextlib.redirect_stdout(out):
            code = hc.main(argv, fetch_fn=fake_fetch({'http://127.0.0.1:1/versions': 500}),
                           unit_fn=fake_units({'x.service': 'failed'}), clock=lambda: NOW)
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out.getvalue())['status'], 'unhealthy')

    def test_argparse_guards(self):
        with self.assertRaises(SystemExit) as cm:
            hc.parse_args([])
        self.assertEqual(cm.exception.code, 2)
        with self.assertRaises(SystemExit) as cm:
            hc.parse_args(['--alert-admin'])  # 검사 목록도, 알림 재료도 없음
        self.assertEqual(cm.exception.code, 2)
        with self.assertRaises(SystemExit) as cm:
            hc.parse_args(['--url', 'http://127.0.0.1/x', '--alert-admin', '--config', 'c'])
        self.assertEqual(cm.exception.code, 2)


if __name__ == '__main__':
    unittest.main()
