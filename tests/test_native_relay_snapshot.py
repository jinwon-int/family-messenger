import datetime
import json
import os
from pathlib import Path
import sqlite3
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import native_relay_snapshot as snap
import native_relay_restore as rest


SCHEMA = """
CREATE TABLE mls_rooms (room TEXT PRIMARY KEY, group_id BLOB, epoch INTEGER NOT NULL DEFAULT 0,
  revision INTEGER NOT NULL DEFAULT 0, last_seq INTEGER NOT NULL DEFAULT 0, created_at TEXT, creator TEXT,
  closed_at TEXT);
CREATE TABLE mls_events (room TEXT NOT NULL, seq INTEGER NOT NULL, epoch INTEGER, kind TEXT, bytes BLOB,
  device TEXT, client_id TEXT, PRIMARY KEY (room, seq));
CREATE TABLE mls_cursors (room TEXT, device TEXT, seq INTEGER NOT NULL, removed_seq INTEGER,
  PRIMARY KEY (room, device));
CREATE TABLE mls_members (room TEXT, device TEXT, added_seq INTEGER NOT NULL, PRIMARY KEY (room, device));
CREATE TABLE mls_keypackages (device TEXT, ref BLOB, PRIMARY KEY (device, ref));
CREATE TABLE push_devices (device TEXT PRIMARY KEY, token TEXT, updated_at TEXT);
"""


def fixture(root):
    """Relay host layout in the shape of the live unit flags (#440 topology table)."""
    root.mkdir(parents=True, exist_ok=True)
    data = root / 'data'
    data.mkdir(mode=0o700)
    db = sqlite3.connect(str(data / snap.DB_NAME))
    db.executescript(SCHEMA)
    db.execute("INSERT INTO mls_rooms (room, epoch, revision, last_seq) VALUES ('family-acc', 11, 5, 179)")
    db.execute("INSERT INTO mls_rooms (room, epoch, revision, last_seq) VALUES ('fleet', 2, 1, 7)")
    for seq in (177, 178, 179):
        db.execute("INSERT INTO mls_events VALUES ('family-acc', ?, 11, 'application', x'00', 'owner-pc', ?)",
                   (seq, 'c' + str(seq)))
    db.execute("INSERT INTO mls_cursors VALUES ('family-acc', 'bot-gongmyoung', 178, NULL)")
    db.execute("INSERT INTO mls_cursors VALUES ('family-acc', 'owner-pc', 179, NULL)")
    db.execute("INSERT INTO mls_members VALUES ('family-acc', 'owner-pc', 1)")
    db.execute("INSERT INTO push_devices VALUES ('owner-iphone', 'tok', '2026-10-19')")
    db.commit()
    db.close()
    policy = root / 'policy'
    policy.mkdir(mode=0o700)
    for revision in (17, 18, 19):
        (policy / ('policy-%06d.json' % revision)).write_text('{"revision": %d}\n' % revision)
    static = root / 'static'
    (static / 'pkg').mkdir(parents=True)
    (static / 'relay-app.html').write_text('<html>')
    (static / 'pkg' / 'custody.js').write_text('js')
    hande = root / 'hande'
    hande.mkdir()
    (hande / 'index.html').write_text('<html>')
    dropin = root / 'dropin'
    dropin.mkdir()
    (dropin / '20-apns.conf').write_text('[Service]\nExecStart=\n')
    env = root / 'relay.env'
    env.write_text('NATIVE_RELAY_ISSUER=https://team.example\n')
    return data, policy, static, hande, dropin, env


def args_for(root, dest, **extra):
    data, policy, static, hande, dropin, env = fixture(root)
    argv = ['--data-dir', str(data), '--policy-dir', str(policy), '--static-dir', str(static),
            '--hande-dir', str(hande), '--dropin-dir', str(dropin), '--env-file', str(env), '--dest', str(dest)]
    for key, value in extra.items():
        if isinstance(value, list):
            for item in value:
                argv += ['--' + key, item]
        else:
            argv += ['--' + key, str(value)]
    return snap.parse(argv)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.dest = self.root / 'snapshots' / 'local'

    def tearDown(self):
        self.tmp.cleanup()

    def test_snapshot_archive_manifest_and_state(self):
        payload = snap.snapshot(args_for(self.root, self.dest))
        self.assertEqual(payload['status'], 'complete')
        archive = Path(payload['archive'])
        self.assertTrue(archive.is_file())
        self.assertEqual(oct(archive.stat().st_mode & 0o777), '0o600')
        self.assertEqual(snap.sha256_file(archive), payload['archive_sha256'])
        sidecar = archive.with_suffix('.gz.sha256')
        self.assertEqual(sidecar.read_text().split()[0], payload['archive_sha256'])
        self.assertEqual(payload['policy_revision'], 19)
        self.assertEqual(payload['db']['rooms']['family-acc'], {'epoch': 11, 'revision': 5, 'last_seq': 179})
        self.assertEqual(payload['db']['counts']['mls_events'], 3)
        self.assertEqual(payload['db']['integrity'], 'ok')
        with tarfile.open(archive) as tar:
            names = set(tar.getnames())
        prefix = payload['id'] + '/'
        for member in ('data/' + snap.DB_NAME, 'policy/policy-000019.json', 'static/pkg/custody.js',
                       'hande/index.html', 'dropin/20-apns.conf', 'env/relay.env', 'manifest.json'):
            self.assertIn(prefix + member, names)
        state = self.root / 'snapshots' / 'state'
        self.assertTrue((state / (payload['id'] + '.json')).is_file())
        latest = json.loads((state / 'latest.json').read_text())
        self.assertEqual(latest['id'], payload['id'])
        self.assertFalse(list(self.dest.glob('.staging-*')), 'staging directory must be removed')

    def test_live_writer_is_not_blocked_and_copy_is_consistent(self):
        args = args_for(self.root, self.dest)
        live = sqlite3.connect(str(Path(args.data_dir) / snap.DB_NAME), isolation_level=None)
        live.execute('BEGIN IMMEDIATE')  # the relay's _txlock=immediate while a request is in flight
        live.execute("INSERT INTO mls_events VALUES ('family-acc', 180, 11, 'application', x'00', 'owner-pc', 'c180')")
        live.commit()
        payload = snap.snapshot(args)
        live.close()
        self.assertEqual(payload['db']['counts']['mls_events'], 4)

    def test_refuses_apns_key_and_symlinks(self):
        args = args_for(self.root, self.dest)
        key = Path(args.hande_dir) / 'AuthKey_XXXX.p8'
        key.write_text('secret')
        with self.assertRaises(ValueError):
            snap.snapshot(args)
        key.unlink()
        args.env_file = str(self.root / 'apns' / 'relay.env')
        Path(args.env_file).parent.mkdir()
        Path(args.env_file).write_text('x')
        with self.assertRaises(ValueError):
            snap.snapshot(args)
        args.env_file = None
        os.symlink('/etc/hostname', Path(args.static_dir) / 'link')
        with self.assertRaises(ValueError):
            snap.snapshot(args)

    def test_push_failure_is_reported_not_hidden(self):
        args = args_for(self.root, self.dest, push=['backup@standby:/var/lib/native-relay-snapshots/local',
                                                   'backup@second:/srv/relay'])
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            rc = 0 if 'standby' in command[-1] else 23
            return mock.Mock(returncode=rc, stderr='rsync: connection refused', stdout='')

        with mock.patch.object(snap.subprocess, 'run', runner):
            payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'push-failed')
        self.assertEqual([p['ok'] for p in payload['pushes']], [True, False])
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][0], 'rsync')
        self.assertTrue(calls[0][-1].endswith('/local/'))
        self.assertTrue(Path(payload['archive']).is_file(), 'local archive survives a failed push')

    def test_prune_keeps_recent_then_one_per_day(self):
        self.dest.mkdir(parents=True)
        now = datetime.datetime(2026, 10, 19, 12, 0, tzinfo=datetime.timezone.utc)
        ages_hours = [1, 20, 47, 49, 50, 30 * 24 + 5, 31 * 24 + 5, 60 * 24]
        names = []
        for hours in ages_hours:
            when = now - datetime.timedelta(hours=hours)
            name = snap.snapshot_id(when) + '.tar.gz'
            (self.dest / name).write_bytes(b'x')
            (self.dest / name).with_suffix('.gz.sha256').write_text('0  ' + name + '\n')
            names.append(name)
        (self.dest / 'unrelated.tar.gz').write_bytes(b'y')
        removed = snap.prune(self.dest, keep_hours=48, keep_days=30, now=now)
        remaining = sorted(p.name for p in self.dest.glob('*.tar.gz'))
        self.assertIn(names[0], remaining)
        self.assertIn(names[1], remaining)
        self.assertIn(names[2], remaining)
        self.assertIn(names[3], remaining, 'first archive of that day is kept')
        self.assertNotIn(names[4], remaining, 'second archive of the same day is pruned')
        self.assertNotIn(names[6], remaining, 'older than keep_days')
        self.assertNotIn(names[7], remaining)
        self.assertIn('unrelated.tar.gz', remaining)
        self.assertNotIn(names[5], remaining, '30 days + 5 h is past keep_days')
        self.assertEqual(set(removed), {names[4], names[5], names[6], names[7]})
        for name in removed:
            self.assertFalse((self.dest / name).with_suffix('.gz.sha256').exists())


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.dest = self.root / 'snapshots' / 'local'
        self.payload = snap.snapshot(args_for(self.root / 'source', self.dest))
        self.archive = self.payload['archive']
        self.target = self.root / 'standby'
        self.target.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def restore_args(self, *extra):
        return rest.parse(['--archive', self.archive, '--target-data-dir', str(self.target / 'data'),
                           '--target-policy-dir', str(self.target / 'policy'),
                           '--target-static-dir', str(self.target / 'static'),
                           '--target-hande-dir', str(self.target / 'hande'), '--skip-unit-check', *extra])

    def test_roundtrip_counts_match_and_modes(self):
        result = rest.restore(self.restore_args())
        self.assertTrue(result['counts_match'])
        self.assertEqual(result['db']['rooms'], self.payload['db']['rooms'])
        self.assertEqual(sorted(result['restored']), ['data', 'hande', 'policy', 'static'])
        db = self.target / 'data' / snap.DB_NAME
        self.assertEqual(oct(db.stat().st_mode & 0o777), '0o600')
        self.assertEqual(oct((self.target / 'data').stat().st_mode & 0o777), '0o700')
        self.assertEqual(oct((self.target / 'static' / 'relay-app.html').stat().st_mode & 0o777), '0o644')
        self.assertTrue((self.target / 'policy' / 'policy-000019.json').is_file())

    def test_bump_seq_raises_every_room_only_forward(self):
        result = rest.restore(self.restore_args('--bump-seq', '1000'))
        self.assertEqual(result['rooms']['family-acc'], {'before': 179, 'after': 1179})
        self.assertEqual(result['rooms']['fleet'], {'before': 7, 'after': 1007})
        self.assertEqual(result['db']['rooms']['family-acc']['last_seq'], 1179)
        self.assertEqual(result['db']['rooms']['family-acc']['epoch'], 11, 'epoch is MLS state, never touched')
        self.assertTrue(result['counts_match'])
        with self.assertRaises(ValueError):
            rest.bump_seq(self.target / 'data' / snap.DB_NAME, -1)

    def test_existing_target_is_moved_aside_not_deleted(self):
        (self.target / 'data').mkdir()
        (self.target / 'data' / 'old.db').write_text('keep me')
        result = rest.restore(self.restore_args())
        aside = Path(result['moved_aside']['data'])
        self.assertTrue((aside / 'old.db').is_file())
        self.assertIsNone(result['moved_aside']['static'])

    def test_refuses_active_unit(self):
        args = rest.parse(['--archive', self.archive, '--target-data-dir', str(self.target / 'data'),
                           '--target-policy-dir', str(self.target / 'policy')])
        runner = mock.Mock(return_value=mock.Mock(stdout='active\n', returncode=0))
        with self.assertRaises(RuntimeError):
            rest.restore(args, runner=runner)
        self.assertEqual(runner.call_args[0][0], ['systemctl', 'is-active', 'native-relay'])
        self.assertFalse((self.target / 'data').exists())

    def test_tampered_archive_or_member_is_rejected(self):
        with open(self.archive, 'r+b') as handle:
            handle.seek(-1, os.SEEK_END)
            last = handle.read(1)
            handle.seek(-1, os.SEEK_END)
            handle.write(bytes([last[0] ^ 0xFF]))
        with self.assertRaises(ValueError):
            rest.restore(self.restore_args())
        self.assertFalse((self.target / 'data').exists())

    def test_member_mismatch_against_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = rest.safe_extract(self.archive, tmp)
            (root / 'policy' / 'policy-000019.json').write_text('{"revision": 99}')
            bad = self.root / 'bad.tar.gz'
            with tarfile.open(bad, 'w:gz') as tar:
                tar.add(root, arcname=root.name)
            bad.with_suffix('.gz.sha256').write_text(snap.sha256_file(bad) + '  bad.tar.gz\n')
        args = self.restore_args()
        args.archive = str(bad)
        with self.assertRaises(ValueError):
            rest.restore(args)

    def test_safe_extract_rejects_traversal_and_links(self):
        evil = self.root / 'evil.tar.gz'
        with tarfile.open(evil, 'w:gz') as tar:
            info = tarfile.TarInfo('relay-x/../../escape')
            info.size = 0
            tar.addfile(info)
        with self.assertRaises(ValueError):
            rest.safe_extract(evil, self.root / 'out')
        link = self.root / 'link.tar.gz'
        with tarfile.open(link, 'w:gz') as tar:
            info = tarfile.TarInfo('relay-x/data/' + snap.DB_NAME)
            info.type = tarfile.SYMTYPE
            info.linkname = '/etc/passwd'
            tar.addfile(info)
        with self.assertRaises(ValueError):
            rest.safe_extract(link, self.root / 'out2')

    def test_summary_only_writes_nothing(self):
        args = rest.parse(['--archive', self.archive, '--summary-only'])
        result = rest.restore(args)
        self.assertEqual(result['manifest']['policy_revision'], 19)
        self.assertEqual(result['manifest']['db']['rooms']['family-acc']['last_seq'], 179)
        self.assertEqual(list(self.target.iterdir()), [])

    def test_drill_uses_access_disabled_on_loopback(self):
        started = {}

        class FakeProc:
            pid = 4242
            returncode = None
            stdout = None

            def poll(self):
                return None

            def wait(self, timeout=None):
                self.returncode = 0
                return 0

        def popen(command, **kwargs):
            started['command'] = command
            return FakeProc()

        with mock.patch.object(rest.subprocess, 'Popen', popen), \
                mock.patch.object(rest, 'probe', return_value=200), \
                mock.patch.object(rest.os, 'killpg') as killpg:
            result = rest.restore(self.restore_args('--relay-binary', '/opt/native-relay/bin/native-mls-relay',
                                                    '--drill-port', '18999'))
        self.assertEqual(result['drill']['health'], 200)
        self.assertEqual(started['command'][:3], ['/opt/native-relay/bin/native-mls-relay', '-addr', '127.0.0.1:18999'])
        self.assertIn('disabled', started['command'])
        self.assertNotIn('required', started['command'])
        killpg.assert_called_once()


if __name__ == '__main__':
    unittest.main()
