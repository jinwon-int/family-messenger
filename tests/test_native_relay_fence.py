import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

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
        assert 'cloudflare-dns.com' in request.full_url and 'type=TXT' in request.full_url
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
