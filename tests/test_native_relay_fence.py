import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import urllib.parse

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
sys.path.insert(0, str(Path(__file__).parent))
import native_relay_fence as fence
import native_relay_snapshot as snap
from test_native_relay_snapshot import args_for


class FakeResponse(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def doh(answers=None, status=0, raise_exc=None):
    def opener(request, timeout=None):
        if raise_exc:
            raise raise_exc
        payload = {'Status': status, 'Answer': [{'type': 16, 'data': '"' + a + '"'} for a in (answers or [])]}
        parts = urllib.parse.urlsplit(request.full_url)
        assert parts.hostname == 'cloudflare-dns.com' and parts.path == '/dns-query'
        assert urllib.parse.parse_qs(parts.query).get('type') == ['TXT']
        return FakeResponse(json.dumps(payload).encode())
    return opener


class FenceTests(unittest.TestCase):
    def test_active_host_matches(self):
        code, message = fence.check('seoseo', '_native-relay-active.example.test', opener=doh(['seoseo']))
        self.assertEqual(code, 0)
        self.assertIn('seoseo is active', message)

    def test_other_host_active_is_refused(self):
        code, message = fence.check('seoseo', '_native-relay-active.example.test', opener=doh(['soonwook']))
        self.assertEqual(code, 1)
        self.assertIn('soonwook', message)

    def test_lookup_failures_fail_closed(self):
        for opener in (doh(status=3), doh([]), doh(raise_exc=OSError('no network')), doh(['a', 'b'])):
            code, _ = fence.check('seoseo', '_native-relay-active.example.test', opener=opener)
            self.assertEqual(code, 2)

    def test_M6_empty_name_or_empty_record_is_refused(self):
        self.assertEqual(fence.check('', 'r.example.test', opener=doh(['']))[0], 2)
        self.assertEqual(fence.check('seoseo', 'r.example.test', opener=doh(['']))[0], 2)
        self.assertEqual(fence.check('   ', 'r.example.test', opener=doh(['seoseo']))[0], 2)

    def test_L1_malformed_answers_fail_closed_with_exit_2(self):
        def weird(request, timeout=None):
            return FakeResponse(json.dumps({'Status': 0, 'Answer': ['not-a-dict']}).encode())
        self.assertEqual(fence.check('seoseo', 'r.example.test', opener=weird)[0], 2)

        def not_json_object(request, timeout=None):
            return FakeResponse(b'[1,2,3]')
        self.assertEqual(fence.check('seoseo', 'r.example.test', opener=not_json_object)[0], 2)

    def test_stop_side_only_on_positive_other_host(self):
        active = mock.Mock(return_value=mock.Mock(returncode=0, stdout='active\n'))
        self.assertEqual(fence.stop_if_fenced_out(1, 'native-relay', streak=3, stop_after=3, runner=active),
                         {'stopped': 'native-relay', 'exit': 0})
        self.assertEqual(active.call_args_list[-1][0][0], ['systemctl', 'stop', 'native-relay'])
        active.reset_mock()
        self.assertIsNone(fence.stop_if_fenced_out(2, 'native-relay', streak=9, stop_after=3, runner=active),
                          'a lookup failure never stops the relay')
        self.assertIsNone(fence.stop_if_fenced_out(0, 'native-relay', streak=9, stop_after=3, runner=active))
        active.assert_not_called()

    def test_N2_stop_side_needs_consecutive_readings(self):
        with tempfile.TemporaryDirectory() as tmp:
            streak_file = Path(tmp) / 'fence-watch.json'
            argv = ['--expect', 'seoseo', '--record', 'r', '--stop-unit', 'native-relay', '--stop-after', '3',
                    '--streak-file', str(streak_file)]
            with mock.patch.object(fence, 'read_txt', return_value=['soonwook']), \
                    mock.patch.object(fence.subprocess, 'run',
                                      return_value=mock.Mock(returncode=0, stdout='active\n')) as run:
                self.assertEqual(fence.main(argv), 0)   # 1st stale-looking read: no stop
                self.assertEqual(fence.main(argv), 0)   # 2nd: no stop
                self.assertFalse(any(c[0][0][:2] == ['systemctl', 'stop'] for c in run.call_args_list))
                self.assertEqual(fence.main(argv), 0)   # 3rd consecutive: stop
                self.assertTrue(any(c[0][0][:2] == ['systemctl', 'stop'] for c in run.call_args_list))
            self.assertEqual(json.loads(streak_file.read_text())['streak'], 3)
            with mock.patch.object(fence, 'read_txt', return_value=['seoseo']), \
                    mock.patch.object(fence.subprocess, 'run') as run:
                self.assertEqual(fence.main(argv), 0)
                run.assert_not_called()
            self.assertEqual(json.loads(streak_file.read_text())['streak'], 0, 'a matching read resets the streak')

    def test_N4_watch_exit_is_zero_unless_a_stop_failed(self):
        with tempfile.TemporaryDirectory() as tmp:
            argv = ['--expect', 'soonwook', '--record', 'r', '--stop-unit', 'native-relay', '--stop-after', '1',
                    '--streak-file', str(Path(tmp) / 's.json')]
            with mock.patch.object(fence, 'read_txt', return_value=['seoseo']), \
                    mock.patch.object(fence.subprocess, 'run',
                                      return_value=mock.Mock(returncode=0, stdout='inactive\n')) as run:
                self.assertEqual(fence.main(argv), 0, 'standby normal state: other host active, unit inactive')
                self.assertFalse(any(c[0][0][:2] == ['systemctl', 'stop'] for c in run.call_args_list),
                                 'no stop issued for an already-inactive unit')
            with mock.patch.object(fence, 'read_txt', side_effect=RuntimeError('dns down')), \
                    mock.patch.object(fence.subprocess, 'run') as run:
                self.assertEqual(fence.main(argv), 0)
                run.assert_not_called()

            def active_then_fail(command, **kwargs):
                return mock.Mock(returncode=0, stdout='active\n') if 'is-active' in command else mock.Mock(returncode=5)
            with mock.patch.object(fence, 'read_txt', return_value=['seoseo']), \
                    mock.patch.object(fence.subprocess, 'run', side_effect=active_then_fail):
                self.assertEqual(fence.main(argv), 3, 'only a failed stop is a unit failure')

    def test_cli_exit_codes(self):
        with mock.patch.object(fence, 'read_txt', return_value=['seoseo']):
            self.assertEqual(fence.main(['--expect', 'seoseo', '--record', 'r.example.test']), 0)
            self.assertEqual(fence.main(['--expect', 'soonwook', '--record', 'r.example.test']), 1)


class SnapshotFenceGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.dest = self.root / 'snapshots' / 'local'

    def tearDown(self):
        self.tmp.cleanup()

    def test_fenced_out_host_skips_without_failing(self):
        args = args_for(self.root, self.dest, **{'fence': 'soonwook', 'fence-record': 'r.example.test'})
        argv = ['--data-dir', args.data_dir, '--policy-dir', args.policy_dir, '--dest', str(self.dest),
                '--fence', 'soonwook', '--fence-record', 'r.example.test']
        with mock.patch.object(fence, 'check', return_value=(1, 'fence: active host is seoseo, not soonwook')):
            self.assertEqual(snap.main(argv), 0)
        self.assertFalse(list(self.dest.glob('relay-*.tar.gz')), 'standby must not produce archives')

    def test_N8_skipped_record_is_cleared_by_the_next_success(self):
        args = args_for(self.root, self.dest)
        argv = ['--data-dir', args.data_dir, '--policy-dir', args.policy_dir, '--dest', str(self.dest),
                '--fence', 'seoseo', '--fence-record', 'r.example.test']
        skipped = self.root / 'snapshots' / 'state' / 'skipped-latest.json'
        with mock.patch.object(fence, 'check', return_value=(2, 'fence lookup failed')):
            snap.main(argv)
        self.assertTrue(skipped.exists())
        with mock.patch.object(fence, 'check', return_value=(0, 'ok')):
            self.assertEqual(snap.main(argv), 0)
        self.assertFalse(skipped.exists())

    def test_L4_unreadable_fence_is_a_visible_failure_with_skipped_record(self):
        args = args_for(self.root, self.dest)
        argv = ['--data-dir', args.data_dir, '--policy-dir', args.policy_dir, '--dest', str(self.dest),
                '--fence', 'seoseo', '--fence-record', 'r.example.test']
        with mock.patch.object(fence, 'check', return_value=(2, 'fence lookup failed')):
            self.assertEqual(snap.main(argv), 1)
        self.assertFalse(list(self.dest.glob('relay-*.tar.gz')))
        skipped = json.loads((self.root / 'snapshots' / 'state' / 'skipped-latest.json').read_text())
        self.assertEqual(skipped['fence_exit'], 2)

    def test_active_host_snapshots(self):
        args = args_for(self.root, self.dest)
        argv = ['--data-dir', args.data_dir, '--policy-dir', args.policy_dir, '--dest', str(self.dest),
                '--fence', 'seoseo', '--fence-record', 'r.example.test']
        with mock.patch.object(fence, 'check', return_value=(0, 'fence: seoseo is active')):
            self.assertEqual(snap.main(argv), 0)
        self.assertEqual(len(list(self.dest.glob('relay-*.tar.gz'))), 1)

    def test_fence_flags_go_together(self):
        with self.assertRaises(SystemExit):
            snap.parse(['--dest', str(self.dest), '--prune-only', '--fence', 'seoseo'])


if __name__ == '__main__':
    unittest.main()
