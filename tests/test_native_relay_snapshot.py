import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
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


BLOB_SCHEMA = """CREATE TABLE IF NOT EXISTS mls_blobs (room TEXT NOT NULL, id TEXT NOT NULL, device TEXT NOT NULL,
  size INTEGER NOT NULL, after_seq INTEGER NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (room, id));"""
# The script cannot work without rsync, so a CI runner without it must fail rather than skip these.
NEEDS_RSYNC = unittest.skipIf(shutil.which('rsync') is None and not os.environ.get('CI'), 'rsync is not installed')


def blob_row(data, room, blob_id, size):
    db = sqlite3.connect(str(Path(data) / snap.DB_NAME))
    db.execute(BLOB_SCHEMA)
    db.execute('INSERT INTO mls_blobs VALUES (?, ?, ?, ?, 0, 0)', (room, blob_id, 'owner-pc', size))
    db.commit()
    db.close()


def blob_file(blobs_dir, room, blob_id, content):
    """A blob the way the relay leaves it: <blobs>/<room>/<id>, 0600 in a 0700 directory."""
    directory = Path(blobs_dir) / room
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    (directory / blob_id).write_bytes(content)
    os.chmod(directory / blob_id, 0o600)
    return directory / blob_id


def add_blob(data, room, content, with_file=True):
    """One mls_blobs row and (unless with_file=False) its file; returns the id = sha256 of the content."""
    blob_id = hashlib.sha256(content).hexdigest()
    blob_row(data, room, blob_id, len(content))
    if with_file:
        blob_file(Path(data) / 'blobs', room, blob_id, content)
    return blob_id


def mode(path):
    return oct(Path(path).stat().st_mode & 0o777)


def ok_runner(calls):
    def runner(command, **kwargs):
        calls.append((command, kwargs))
        return mock.Mock(returncode=0, stderr='', stdout='')
    return runner


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

    def test_bwlimit_reaches_every_rsync_of_a_snapshot_run(self):
        args = args_for(self.root, self.dest, push=['backup@standby:/inbox'], bwlimit=300)
        calls = []

        def runner(command, **kwargs):
            calls.append((command, kwargs['timeout']))
            return mock.Mock(returncode=0, stderr='', stdout='')

        with mock.patch.object(snap.subprocess, 'run', runner):
            payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'complete')
        self.assertIn('--bwlimit=300', calls[0][0])
        self.assertGreaterEqual(calls[0][1], 600)

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


class PushLatestTests(unittest.TestCase):
    """#426: a thin-line receiver gets the newest finished archive from its own, rarer, capped timer."""

    NOW = datetime.datetime(2026, 11, 13, 9, 0, tzinfo=datetime.timezone.utc)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.dest = self.root / 'local'
        self.dest.mkdir()
        self.state = self.root / 'state'

    def tearDown(self):
        self.tmp.cleanup()

    def archive(self, minutes_ago, sidecar=True, size=2048):
        when = self.NOW - datetime.timedelta(minutes=minutes_ago)
        path = self.dest / ('relay-' + when.strftime('%Y%m%dT%H%M%SZ') + '.tar.gz')
        path.write_bytes(b'x' * size)
        if sidecar:
            path.with_suffix('.gz.sha256').write_text(snap.sha256_file(path) + '  ' + path.name + '\n')
        return path

    def args(self, *extra):
        return snap.parse(['--dest', str(self.dest), '--state', str(self.state), '--push-latest',
                           '--push', 'relay-snapshots@thin:/inbox', '--bwlimit', '200'] + list(extra))

    def test_pushes_newest_finished_archive_with_cap_and_records_state(self):
        self.archive(20)
        newest = self.archive(5)
        self.archive(1, sidecar=False)  # still being packed: no sidecar yet
        calls = []

        def runner(command, **kwargs):
            calls.append((command, kwargs['timeout']))
            return mock.Mock(returncode=0, stderr='', stdout='')

        payload = snap.push_latest(self.args(), now=self.NOW, runner=runner)
        self.assertEqual(payload['status'], 'complete')
        self.assertEqual(payload['archive'], newest.name)
        self.assertEqual(len(calls), 1)
        command, timeout = calls[0]
        self.assertIn('--bwlimit=200', command)
        self.assertIn(str(newest), command)
        self.assertEqual(command[-1], 'relay-snapshots@thin:/inbox/')
        self.assertEqual(timeout, 600)  # tiny file: the floor applies
        recorded = json.loads((self.state / 'push-latest.json').read_text())
        self.assertEqual(recorded['archive'], newest.name)
        self.assertEqual(len(list(self.dest.glob('relay-*.tar.gz'))), 3, 'push-latest never creates or prunes')

    def test_stale_or_missing_archive_is_refused(self):
        with self.assertRaises(RuntimeError):
            snap.push_latest(self.args(), now=self.NOW, runner=mock.Mock())
        self.archive(45)
        runner = mock.Mock()
        with self.assertRaisesRegex(RuntimeError, 'min old'):
            snap.push_latest(self.args(), now=self.NOW, runner=runner)
        runner.assert_not_called()
        payload = snap.push_latest(self.args('--max-age-minutes', '60'), now=self.NOW,
                                   runner=mock.Mock(return_value=mock.Mock(returncode=0, stderr='', stdout='')))
        self.assertEqual(payload['status'], 'complete')

    def test_sidecar_naming_another_file_is_ignored(self):
        good = self.archive(10)
        bad = self.archive(2, sidecar=False)
        bad.with_suffix('.gz.sha256').write_text('0' * 64 + '  ' + good.name + '\n')
        self.assertEqual(snap.latest_archive(self.dest)[1], good)

    def test_timeout_scales_with_the_cap(self):
        self.assertEqual(snap.push_timeout(150 * 1024 * 1024, None), 600)
        self.assertEqual(snap.push_timeout(150 * 1024 * 1024, 300), int(150 * 1024 / 300 * 1.5) + 120)
        self.assertEqual(snap.push_timeout(1024, 300), 600)

    def test_parse_rules(self):
        with self.assertRaises(SystemExit):
            snap.parse(['--dest', str(self.dest), '--push-latest'])  # no --push
        with self.assertRaises(SystemExit):
            snap.parse(['--dest', str(self.dest), '--push-latest', '--push', 'a@b:/c', '--bwlimit', '0'])
        with self.assertRaises(SystemExit):
            snap.parse(['--dest', str(self.dest), '--push-latest', '--prune-only', '--push', 'a@b:/c'])
        args = snap.parse(['--dest', str(self.dest), '--push-latest', '--push', 'a@b:/c'])
        self.assertIsNone(args.data_dir)  # no relay paths needed

    def test_own_lock_does_not_block_the_snapshot_lock(self):
        self.archive(3)
        self.state.mkdir()
        import fcntl
        ok = mock.Mock(returncode=0, stderr='', stdout='')
        with open(self.state / '.lock', 'w') as snapshot_lock:
            fcntl.flock(snapshot_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # a snapshot run is in progress
            with mock.patch.object(snap.subprocess, 'run', return_value=ok), \
                    mock.patch.object(snap, 'utcnow', return_value=self.NOW), \
                    mock.patch('sys.stdout'):
                rc = snap.main(['--dest', str(self.dest), '--state', str(self.state), '--push-latest',
                                '--push', 'a@b:/c'])
        self.assertEqual(rc, 0)
        with open(self.state / '.push-lock', 'w') as push_lock:
            fcntl.flock(push_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # a push-latest run is in progress
            with mock.patch('sys.stderr'):
                rc = snap.main(['--dest', str(self.dest), '--state', str(self.state), '--push-latest',
                                '--push', 'a@b:/c'])
        self.assertEqual(rc, 2)


class BlobSnapshotTests(unittest.TestCase):
    """Attachment ciphertext lives outside the database; the rows of the database COPY decide what is shipped."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.dest = self.root / 'snapshots' / 'local'
        self.inbox = self.root / 'standby' / 'inbox'
        self.inbox.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def source(self, **extra):
        args = args_for(self.root / 'source', self.dest, **extra)
        return args, Path(args.data_dir)

    def test_path_rules_refuse_everything_but_room_and_hex_id(self):
        good = 'ab' * 32
        self.assertEqual(snap.blob_relpath('family-acc', good), 'family-acc/' + good)
        for room, blob_id in (('..', good), ('.tmp', good), ('a/b', good), ('', good), ('/etc', good),
                              ('r' * 65, good), ('room\n', good), ('room', good + '\n'), ('room', good.upper()),
                              ('room', good[:-1]), ('room', '../' + good[3:]), ('room', None), (7, good)):
            with self.subTest(room=room, blob_id=blob_id):
                with self.assertRaises(ValueError):
                    snap.blob_relpath(room, blob_id)
                with self.assertRaises((ValueError, TypeError)):
                    snap.locate_blob(self.root, room, blob_id)

    def test_listing_and_command_follow_the_snapshot_rows_only(self):
        args, data = self.source(push=['backup@standby:/inbox'], bwlimit=300)
        first = add_blob(data, 'family-acc', b'first attachment')
        second = add_blob(data, 'fleet', b'second attachment')
        (data / 'blobs' / '.tmp').mkdir()
        (data / 'blobs' / '.tmp' / 'upload-1').write_bytes(b'in flight')
        orphan = blob_file(data / 'blobs', 'family-acc', 'cd' * 32, b'no row points here')
        calls = []
        with mock.patch.object(snap.subprocess, 'run', ok_runner(calls)):
            payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'complete')
        self.assertEqual({k: payload['blobs'][k] for k in ('rows', 'listed', 'missing', 'clean')},
                         {'rows': 2, 'listed': 2, 'missing': 0, 'clean': True})
        self.assertEqual(len(calls), 2, 'one rsync for the archive, one for its blobs')
        archive_cmd, blob_cmd = calls[0][0], calls[1][0]
        listed = Path(payload['archive']).with_suffix('.gz.blobs')
        self.assertEqual(listed.read_text(), 'family-acc/%s 16\nfleet/%s 17\n' % (first, second))
        self.assertEqual(mode(listed), '0o600')
        self.assertIn(str(listed), archive_cmd, 'the list travels with the archive')
        self.assertLess(archive_cmd.index(str(listed)), archive_cmd.index(payload['archive'] + '.sha256'))
        self.assertEqual(calls[1][1]['input'], 'blobs/family-acc/%s\nblobs/fleet/%s\n' % (first, second))
        self.assertNotIn('.tmp', calls[1][1]['input'])
        self.assertNotIn(orphan.name, calls[1][1]['input'])
        self.assertEqual(blob_cmd[-2:], [str(data) + '/', 'backup@standby:/inbox/'])
        for flag in ('--files-from=-', '--ignore-existing', '--chmod=D700,F600', '--bwlimit=300'):
            self.assertIn(flag, blob_cmd)
        for flag in blob_cmd[1:-2]:
            self.assertFalse(flag.startswith('--delete') or flag in ('-a', '-l', '-L', '-r', '--copy-links'), flag)
        self.assertEqual(payload['pushes'][0]['blobs'], {'ok': True, 'listed': 2})

    @NEEDS_RSYNC
    def test_real_rsync_mirrors_next_to_the_archive_without_tmp_orphans_or_rewrites(self):
        args, data = self.source(push=[str(self.inbox)])
        first = add_blob(data, 'family-acc', b'first attachment')
        (data / 'blobs' / '.tmp').mkdir()
        (data / 'blobs' / '.tmp' / 'upload-1').write_bytes(b'in flight')
        blob_file(data / 'blobs', 'family-acc', 'cd' * 32, b'no row points here')
        os.symlink('/etc/hostname', data / 'blobs' / 'family-acc' / 'link')
        os.chmod(self.inbox, 0o750)
        payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'complete', payload)
        mirror = self.inbox / 'blobs'
        self.assertEqual(sorted(str(p.relative_to(mirror)) for p in mirror.rglob('*')),
                         ['family-acc', 'family-acc/' + first])
        self.assertEqual((mirror / 'family-acc' / first).read_bytes(), b'first attachment')
        self.assertEqual([mode(mirror), mode(mirror / 'family-acc'), mode(mirror / 'family-acc' / first)],
                         ['0o700', '0o700', '0o600'])
        self.assertEqual(mode(self.inbox), '0o750', 'the receiving directory keeps its own mode')
        archive = Path(payload['archive']).name
        for name in (archive, archive + '.blobs', archive + '.sha256'):
            self.assertTrue((self.inbox / name).is_file(), name)
        # A blob is immutable: what the mirror already holds is never rewritten, and nothing is deleted
        # from it when the sender no longer lists a file.
        (mirror / 'family-acc' / first).write_bytes(b'kept as it arrived')
        blob_file(mirror, 'older-room', 'ef' * 32, b'from an earlier sender')
        second = add_blob(data, 'fleet', b'second attachment')
        with mock.patch.object(snap, 'snapshot_id', return_value='relay-20991231T235959Z'):
            again = snap.snapshot(args)
        self.assertEqual(again['status'], 'complete', again)
        self.assertEqual((mirror / 'family-acc' / first).read_bytes(), b'kept as it arrived')
        self.assertEqual((mirror / 'fleet' / second).read_bytes(), b'second attachment')
        self.assertTrue((mirror / 'older-room' / ('ef' * 32)).is_file())

    def test_row_without_a_file_is_reported_with_prefix_only_and_fails_the_run(self):
        args, data = self.source()
        add_blob(data, 'family-acc', b'present')
        lost = add_blob(data, 'family-acc', b'lost attachment', with_file=False)
        payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'blobs-incomplete')
        self.assertEqual({k: payload['blobs'][k] for k in ('rows', 'listed', 'pruned', 'missing', 'clean')},
                         {'rows': 2, 'listed': 1, 'pruned': 0, 'missing': 1, 'clean': False})
        self.assertEqual(payload['blobs']['examples'], ['family-acc/' + lost[:12]])
        self.assertTrue(Path(payload['archive']).is_file(), 'the database archive is still made')
        recorded = (self.root / 'snapshots' / 'state' / 'latest.json').read_text()
        self.assertNotIn(lost, recorded, 'full ids stay out of the record')
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(snap, 'snapshot_id', return_value='relay-20991231T235959Z'), \
                mock.patch('sys.stdout', out), mock.patch('sys.stderr', err):
            rc = snap.main(['--data-dir', args.data_dir, '--policy-dir', args.policy_dir, '--dest', str(self.dest)])
        self.assertEqual(rc, 1)
        self.assertIn('missing=1', err.getvalue())
        self.assertIn('INCOMPLETE (family-acc/' + lost[:12] + ')', err.getvalue())
        self.assertNotIn(lost, out.getvalue() + err.getvalue())

    def test_file_gone_because_its_row_was_pruned_after_the_copy_is_not_an_error(self):
        args, data = self.source(push=['backup@standby:/inbox'])
        kept = add_blob(data, 'family-acc', b'kept')
        expired = add_blob(data, 'family-acc', b'expired meanwhile')
        real_pack = snap.pack

        def pack_then_relay_prunes(*a, **kw):
            result = real_pack(*a, **kw)
            db = sqlite3.connect(str(data / snap.DB_NAME))
            db.execute('DELETE FROM mls_blobs WHERE id = ?', (expired,))
            db.commit()
            db.close()
            (data / 'blobs' / 'family-acc' / expired).unlink()  # the sweeper removes a file without a row
            return result

        calls = []
        with mock.patch.object(snap, 'pack', pack_then_relay_prunes), \
                mock.patch.object(snap.subprocess, 'run', ok_runner(calls)):
            payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'complete')
        self.assertEqual({k: payload['blobs'][k] for k in ('rows', 'listed', 'pruned', 'missing', 'clean')},
                         {'rows': 2, 'listed': 1, 'pruned': 1, 'missing': 0, 'clean': True})
        self.assertEqual(calls[1][1]['input'], 'blobs/family-acc/%s\n' % kept)

    def test_links_wrong_sizes_and_apns_paths_are_never_shipped(self):
        args, data = self.source(push=['backup@standby:/inbox'])
        good = add_blob(data, 'family-acc', b'good')
        # A link whose own lstat size equals the row's size: only the file type can tell it apart.
        outside = self.root / 'outside'
        outside.write_bytes(b'x' * len(str(outside)))
        linked = add_blob(data, 'family-acc', outside.read_bytes(), with_file=False)
        os.symlink(outside, data / 'blobs' / 'family-acc' / linked)
        self.assertEqual(os.lstat(data / 'blobs' / 'family-acc' / linked).st_size, len(outside.read_bytes()))
        short = add_blob(data, 'family-acc', b'truncated on disk')
        (data / 'blobs' / 'family-acc' / short).write_bytes(b'trunc')
        elsewhere = self.root / 'elsewhere'
        in_linked_room = hashlib.sha256(b'room is a link').hexdigest()
        blob_file(elsewhere, 'x', in_linked_room, b'room is a link')
        os.symlink(elsewhere / 'x', data / 'blobs' / 'linked-room')
        blob_row(data, 'linked-room', in_linked_room, 14)
        add_blob(data, 'apns', b'room named like the key directory')
        calls = []
        with mock.patch.object(snap.subprocess, 'run', ok_runner(calls)):
            payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'blobs-incomplete')
        self.assertEqual({k: payload['blobs'][k] for k in ('rows', 'listed', 'missing', 'unsafe')},
                         {'rows': 5, 'listed': 1, 'missing': 0, 'unsafe': 4})
        self.assertEqual(calls[1][1]['input'], 'blobs/family-acc/%s\n' % good)

    def test_path_escape_rows_are_refused_not_turned_into_paths(self):
        args, data = self.source(push=['backup@standby:/inbox'])
        good = add_blob(data, 'family-acc', b'good')
        secret = hashlib.sha256(b'outside the blob root').hexdigest()
        blob_file(self.root / 'source', 'escape', secret, b'outside the blob root')
        blob_row(data, '../../escape', secret, 21)
        blob_row(data, '.tmp', 'ab' * 32, 3)
        blob_row(data, 'family-acc', '../../../relay.env', 3)
        blob_row(data, 'family-acc', 'AB' * 32, 3)
        calls = []
        with mock.patch.object(snap.subprocess, 'run', ok_runner(calls)):
            payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'blobs-incomplete')
        self.assertEqual({k: payload['blobs'][k] for k in ('rows', 'listed', 'refused', 'clean')},
                         {'rows': 5, 'listed': 1, 'refused': 4, 'clean': False})
        self.assertEqual(calls[1][1]['input'], 'blobs/family-acc/%s\n' % good)
        listed = Path(payload['archive']).with_suffix('.gz.blobs').read_text()
        self.assertEqual(listed, 'family-acc/%s 4\n' % good)
        for bad in ('../x/%s 3\n' % ('ab' * 32), '.tmp/%s 3\n' % ('ab' * 32), 'room/%s\n' % ('ab' * 32),
                    'room/%s -1\n' % ('ab' * 32), '/abs/%s 3\n' % ('ab' * 32), 'room/x/%s 3\n' % ('ab' * 32)):
            with self.subTest(line=bad):
                (self.root / 'bad.blobs').write_text(bad)
                with self.assertRaises(ValueError):
                    snap.read_blob_list(self.root / 'bad.blobs')

    def test_failed_archive_push_skips_that_targets_blobs_and_a_failed_blob_push_fails_the_run(self):
        args, data = self.source(push=['backup@down:/inbox', 'backup@standby:/inbox'])
        add_blob(data, 'family-acc', b'good')
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            return mock.Mock(returncode=12 if 'down' in command[-1] else 0, stderr='', stdout='')

        with mock.patch.object(snap.subprocess, 'run', runner):
            payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'push-failed')
        self.assertEqual([c[-1] for c in calls], ['backup@down:/inbox/', 'backup@standby:/inbox/',
                                                  'backup@standby:/inbox/'])
        self.assertFalse(payload['pushes'][0]['blobs']['ok'])
        self.assertEqual(payload['pushes'][1]['blobs'], {'ok': True, 'listed': 1})

        def blobs_fail(command, **kwargs):
            return mock.Mock(returncode=23 if '--files-from=-' in command else 0, stderr='partial', stdout='')

        args.push = ['backup@standby:/inbox']
        with mock.patch.object(snap.subprocess, 'run', blobs_fail), \
                mock.patch.object(snap, 'snapshot_id', return_value='relay-20991231T235959Z'):
            payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'push-failed')
        self.assertTrue(payload['pushes'][0]['ok'], 'the archive itself arrived')
        self.assertEqual(payload['pushes'][0]['blobs']['error'], 'rsync exit 23')

    def test_database_without_the_blob_table_ships_nothing_extra(self):
        args, _ = self.source(push=['backup@standby:/inbox'])
        calls = []
        with mock.patch.object(snap.subprocess, 'run', ok_runner(calls)):
            payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'complete')
        self.assertEqual(len(calls), 1)
        self.assertEqual(Path(payload['archive']).with_suffix('.gz.blobs').read_text(), '')
        self.assertNotIn('blobs', payload['pushes'][0])

    def test_push_latest_mirrors_the_blobs_its_archive_lists(self):
        args, data = self.source()
        first = add_blob(data, 'family-acc', b'first attachment')
        payload = snap.snapshot(args)
        add_blob(data, 'family-acc', b'uploaded after that archive')
        state = str(self.root / 'snapshots' / 'state')
        base = ['--dest', str(self.dest), '--state', state, '--push-latest', '--push', 'backup@thin:/inbox',
                '--bwlimit', '200']
        calls = []
        result = snap.push_latest(snap.parse(base + ['--data-dir', str(data)]), runner=ok_runner(calls))
        self.assertEqual(result['status'], 'complete')
        self.assertEqual(result['archive'], Path(payload['archive']).name)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1][1]['input'], 'blobs/family-acc/%s\n' % first)
        self.assertIn('--bwlimit=200', calls[1][0])
        self.assertEqual(result['blobs']['listed'], 1)
        # A unit that was not given --data-dir cannot find the files: loud, not a silent pass.
        calls = []
        result = snap.push_latest(snap.parse(base), runner=ok_runner(calls))
        self.assertEqual(result['status'], 'push-failed')
        self.assertEqual(len(calls), 1, 'the archive is still pushed')
        self.assertIn('--data-dir', result['pushes'][0]['blobs']['error'])
        # An archive from before blobs were carried has no list: behaviour is what it was.
        Path(payload['archive']).with_suffix('.gz.blobs').unlink()
        calls = []
        result = snap.push_latest(snap.parse(base), runner=ok_runner(calls))
        self.assertEqual((result['status'], len(calls), result['blobs']), ('complete', 1, None))


class BlobMirrorPruneTests(unittest.TestCase):
    NOW = datetime.datetime(2026, 11, 18, 12, 0, tzinfo=datetime.timezone.utc)
    A, B, C, D = ('a1' * 32, 'b2' * 32, 'c3' * 32, 'd4' * 32)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.inbox = Path(self.tmp.name) / 'inbox'
        self.inbox.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def archive(self, hours_ago, rows=()):
        name = snap.snapshot_id(self.NOW - datetime.timedelta(hours=hours_ago)) + '.tar.gz'
        (self.inbox / name).write_bytes(b'x')
        (self.inbox / (name + '.sha256')).write_text('0  ' + name + '\n')
        if rows is not None:
            snap.write_blob_list(self.inbox / name, [(room, blob_id, 1) for room, blob_id in rows])
        return self.inbox / name

    def mirrored(self, room, blob_id, hours_old):
        path = blob_file(self.inbox / 'blobs', room, blob_id, b'x')
        when = (self.NOW - datetime.timedelta(hours=hours_old)).timestamp()
        os.utime(path, (when, when))
        return path

    def test_only_old_files_no_kept_archive_lists_are_removed(self):
        self.archive(1, [('family-acc', self.A)])
        self.archive(20 * 24, [('family-acc', self.B)])
        listed_now = self.mirrored('family-acc', self.A, 100)
        listed_by_daily = self.mirrored('family-acc', self.B, 500)
        unlisted_old = self.mirrored('family-acc', self.C, 100)
        just_arrived = self.mirrored('family-acc', self.D, 1)
        gone_room = self.mirrored('closed-room', self.C, 100)
        stranger = self.inbox / 'blobs' / 'family-acc' / 'notes.txt'
        stranger.write_text('not ours')
        os.utime(stranger, (0, 0))
        result = snap.prune_blob_mirror(self.inbox, keep_hours=6, now=self.NOW)
        self.assertEqual(result, {'removed': 2})
        self.assertTrue(listed_now.is_file() and listed_by_daily.is_file() and just_arrived.is_file())
        self.assertFalse(unlisted_old.exists() or gone_room.exists())
        self.assertTrue(stranger.is_file(), 'only <room>/<64 hex> files are ever touched')

    def test_nothing_is_removed_while_any_kept_archive_has_no_list(self):
        self.archive(1, [('family-acc', self.A)])
        self.archive(2, rows=None)  # made before blobs were carried: what it needs is unknown
        old = self.mirrored('family-acc', self.C, 100)
        result = snap.prune_blob_mirror(self.inbox, keep_hours=6, now=self.NOW)
        self.assertEqual(result['removed'], 0)
        self.assertIn('1 of 2', result['skipped'])
        self.assertTrue(old.is_file())

    def test_a_directory_without_archives_is_never_treated_as_a_mirror(self):
        # e.g. --dest pointed at a relay data directory by mistake: its blobs/ must survive.
        old = self.mirrored('family-acc', self.C, 100)
        self.assertEqual(snap.prune_blob_mirror(self.inbox, keep_hours=6, now=self.NOW)['removed'], 0)
        self.assertTrue(old.is_file())
        shutil.rmtree(self.inbox / 'blobs')
        self.assertIsNone(snap.prune_blob_mirror(self.inbox, keep_hours=6, now=self.NOW))
        os.symlink(self.tmp.name, self.inbox / 'blobs')
        with self.assertRaises(ValueError):
            snap.prune_blob_mirror(self.inbox, keep_hours=6, now=self.NOW)

    def test_prune_only_removes_lists_with_their_archives_then_trims_the_mirror(self):
        now = snap.utcnow()
        fresh = snap.snapshot_id(now - datetime.timedelta(minutes=5)) + '.tar.gz'
        expired = snap.snapshot_id(now - datetime.timedelta(days=40)) + '.tar.gz'
        stray = snap.snapshot_id(now - datetime.timedelta(days=50)) + '.tar.gz.blobs'
        for name, blob_id in ((fresh, self.A), (expired, self.B)):
            (self.inbox / name).write_bytes(b'x')
            snap.write_blob_list(self.inbox / name, [('family-acc', blob_id, 1)])
        (self.inbox / stray).write_text('')
        for blob_id in (self.A, self.B):
            path = blob_file(self.inbox / 'blobs', 'family-acc', blob_id, b'x')
            os.utime(path, (0, 0))
        out = io.StringIO()
        with mock.patch('sys.stdout', out):
            rc = snap.main(['--prune-only', '--dest', str(self.inbox), '--keep-hours', '6', '--keep-days', '30'])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.getvalue()), {'pruned': [expired], 'blob_mirror': {'removed': 1}})
        self.assertEqual(sorted(p.name for p in self.inbox.iterdir()), sorted(['blobs', fresh, fresh + '.blobs']))
        self.assertEqual([p.name for p in (self.inbox / 'blobs' / 'family-acc').iterdir()], [self.A])


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

    def test_clear_lobby_keypackages_is_off_by_default_and_tolerates_a_missing_table(self):
        self.assertIsNone(rest.restore(self.restore_args())['lobby_keypackages_cleared'])
        # The fixture relay predates the lobby (#380): nothing to clear, no error.
        target = self.root / 'standby2'
        target.mkdir()
        result = rest.restore(rest.parse(['--archive', self.archive, '--target-data-dir', str(target / 'data'),
                                          '--target-policy-dir', str(target / 'policy'),
                                          '--skip-unit-check', '--clear-lobby-keypackages']))
        self.assertEqual(result['lobby_keypackages_cleared'], {})

    def test_clear_lobby_keypackages_drops_only_unconsumed_rows(self):
        """#812: a package consumed after the snapshot comes back unconsumed; clearing every
        unconsumed row makes each device see live 0 and republish. Consumed rows and room
        key packages stay; counts are still compared against the manifest before the delete."""
        source = self.root / 'lobby-source'
        argv = args_for(source, self.root / 'lobby-snapshots')
        db = sqlite3.connect(str(source / 'data' / snap.DB_NAME))
        db.execute("""CREATE TABLE mls_lobby_keypackages (device TEXT NOT NULL, ref TEXT NOT NULL, bytes BLOB NOT NULL,
            consumed_by TEXT, consumed_room TEXT, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
            PRIMARY KEY (device, ref))""")
        rows = [('owner-pc', 'a1', None, None), ('owner-pc', 'a2', None, None),
                ('owner-pc', 'a0', 'bot-1', 'family-acc'), ('owner-iphone', 'b1', None, None)]
        for device, ref, by, room in rows:
            db.execute("INSERT INTO mls_lobby_keypackages VALUES (?, ?, x'00', ?, ?, 1, 9999999999)",
                       (device, ref, by, room))
        db.execute("INSERT INTO mls_keypackages VALUES ('owner-pc', x'01')")
        db.commit()
        db.close()
        archive = snap.snapshot(argv)['archive']
        target = self.root / 'lobby-standby'
        target.mkdir()
        result = rest.restore(rest.parse(['--archive', archive, '--target-data-dir', str(target / 'data'),
                                          '--target-policy-dir', str(target / 'policy'),
                                          '--skip-unit-check', '--clear-lobby-keypackages']))
        self.assertEqual(result['lobby_keypackages_cleared'], {'owner-iphone': 1, 'owner-pc': 2})
        self.assertTrue(result['counts_match'], 'the copy matched the manifest before the delete')
        self.assertEqual(result['db']['counts']['mls_lobby_keypackages'], 4)
        conn = sqlite3.connect(str(target / 'data' / snap.DB_NAME))
        try:
            left = conn.execute('SELECT device, ref, consumed_by FROM mls_lobby_keypackages').fetchall()
            room_packages = conn.execute('SELECT COUNT(*) FROM mls_keypackages').fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(left, [('owner-pc', 'a0', 'bot-1')], 'consumed rows stay')
        self.assertEqual(room_packages, 1, 'room key packages are not lobby packages')

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


class BlobRestoreTests(unittest.TestCase):
    """After the database is back, every mls_blobs row gets its verified file or the gap is spelled out."""

    FIRST, SECOND = b'first attachment', b'second attachment, a little longer'

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.inbox = self.root / 'snapshots' / 'inbox'
        args = args_for(self.root / 'source', self.inbox)
        self.first = add_blob(Path(args.data_dir), 'family-acc', self.FIRST)
        self.second = add_blob(Path(args.data_dir), 'fleet', self.SECOND)
        self.source_blobs = Path(args.data_dir) / 'blobs'
        self.archive = snap.snapshot(args)['archive']
        self.mirror = self.inbox / 'blobs'
        self.target = self.root / 'standby'
        self.target.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def argv(self, *extra):
        return ['--archive', self.archive, '--target-data-dir', str(self.target / 'data'),
                '--target-policy-dir', str(self.target / 'policy'), '--skip-unit-check', *extra]

    def restore(self, *extra):
        return rest.restore(rest.parse(self.argv(*extra)))

    def placed(self, room, blob_id):
        return self.target / 'data' / 'blobs' / room / blob_id

    def test_rows_get_their_files_with_the_database_modes(self):
        blob_file(self.mirror, 'family-acc', self.first, self.FIRST)
        blob_file(self.mirror, 'fleet', self.second, self.SECOND)
        blob_file(self.mirror, 'family-acc', 'cd' * 32, b'in the mirror, not in this database')
        (self.mirror / '.tmp').mkdir()
        (self.mirror / '.tmp' / self.first).write_bytes(self.FIRST)
        result = self.restore()
        self.assertEqual(result['blobs']['summary'], 'blobs: rows=2 placed=2 already=0 missing=0 mismatch=0')
        self.assertTrue(result['blobs']['clean'] and result['counts_match'])
        self.assertEqual(self.placed('family-acc', self.first).read_bytes(), self.FIRST)
        self.assertEqual(self.placed('fleet', self.second).read_bytes(), self.SECOND)
        blobs = self.target / 'data' / 'blobs'
        self.assertEqual(sorted(str(p.relative_to(blobs)) for p in blobs.rglob('*')),
                         ['.tmp', 'family-acc', 'family-acc/' + self.first, 'fleet', 'fleet/' + self.second])
        self.assertEqual([mode(blobs), mode(blobs / 'fleet'), mode(self.placed('fleet', self.second))],
                         ['0o700', '0o700', '0o600'])
        self.assertEqual(mode(self.target / 'data' / snap.DB_NAME), mode(self.placed('fleet', self.second)))
        out, err = io.StringIO(), io.StringIO()
        target = self.root / 'again'
        with mock.patch('sys.stdout', out), mock.patch('sys.stderr', err):
            rc = rest.main(['--archive', self.archive, '--target-data-dir', str(target / 'data'),
                            '--target-policy-dir', str(target / 'policy'), '--skip-unit-check'])
        self.assertEqual(rc, 0)
        self.assertEqual(err.getvalue(), 'blobs: rows=2 placed=2 already=0 missing=0 mismatch=0\n')
        self.assertEqual(json.loads(out.getvalue())['blobs']['placed'], 2)

    def test_missing_file_is_loud_but_the_database_restore_stands(self):
        blob_file(self.mirror, 'family-acc', self.first, self.FIRST)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch('sys.stdout', out), mock.patch('sys.stderr', err):
            rc = rest.main(self.argv())
        self.assertEqual(rc, rest.EXIT_BLOBS)
        self.assertEqual(err.getvalue(), 'blobs: rows=2 placed=1 already=0 missing=1 mismatch=0 INCOMPLETE '
                                         '(fleet/%s)\n' % self.second[:12])
        result = json.loads(out.getvalue())
        self.assertFalse(result['blobs']['clean'])
        self.assertTrue(result['counts_match'], 'the database itself came back whole')
        self.assertTrue(self.placed('family-acc', self.first).is_file())
        self.assertFalse(self.placed('fleet', self.second).exists())
        self.assertNotIn(self.second, out.getvalue() + err.getvalue())

    def test_wrong_size_or_wrong_hash_is_a_mismatch_and_is_not_placed(self):
        blob_file(self.mirror, 'family-acc', self.first, self.FIRST[:-1] + b'X')  # same size, other bytes
        blob_file(self.mirror, 'fleet', self.second, self.SECOND + b'tail')  # other size
        result = self.restore()
        self.assertEqual(result['blobs']['summary'],
                         'blobs: rows=2 placed=0 already=0 missing=0 mismatch=2 INCOMPLETE (family-acc/%s, fleet/%s)'
                         % (self.first[:12], self.second[:12]))
        self.assertFalse(self.placed('family-acc', self.first).exists())
        self.assertFalse(self.placed('fleet', self.second).exists())
        self.assertEqual(list((self.target / 'data' / 'blobs' / '.tmp').iterdir()), [], 'no partial copy is left')

    def test_a_good_copy_in_a_later_source_wins_over_a_bad_one(self):
        blob_file(self.mirror, 'family-acc', self.first, b'x' * len(self.FIRST))
        blob_file(self.mirror, 'fleet', self.second, self.SECOND)
        result = self.restore('--blob-source', str(self.source_blobs))
        self.assertEqual(result['blobs']['summary'], 'blobs: rows=2 placed=2 already=0 missing=0 mismatch=0')
        self.assertEqual(self.placed('family-acc', self.first).read_bytes(), self.FIRST)
        self.assertEqual(result['blobs']['sources'], [str(self.source_blobs), str(self.mirror)])

    def test_data_directory_moved_aside_still_serves_its_blobs(self):
        # A restore on a host that was serving before: the old data directory (with every blob) is
        # renamed away by the restore itself. Its files are copied back, the old tree stays whole.
        blob_file(self.target / 'data' / 'blobs', 'family-acc', self.first, self.FIRST)
        blob_file(self.target / 'data' / 'blobs', 'fleet', self.second, self.SECOND)
        result = self.restore()
        self.assertEqual(result['blobs']['summary'], 'blobs: rows=2 placed=2 already=0 missing=0 mismatch=0')
        aside = Path(result['moved_aside']['data'])
        self.assertEqual((aside / 'blobs' / 'fleet' / self.second).read_bytes(), self.SECOND)
        self.assertEqual(self.placed('fleet', self.second).read_bytes(), self.SECOND)
        self.assertNotEqual(self.placed('fleet', self.second).stat().st_ino,
                            (aside / 'blobs' / 'fleet' / self.second).stat().st_ino)

    def test_links_in_a_source_are_not_followed(self):
        self.mirror.mkdir()
        (self.mirror / 'family-acc').mkdir()
        os.symlink(self.source_blobs / 'family-acc' / self.first, self.mirror / 'family-acc' / self.first)
        os.symlink(self.source_blobs / 'fleet', self.mirror / 'fleet')
        result = self.restore()
        self.assertEqual((result['blobs']['placed'], result['blobs']['mismatch']), (0, 2))
        linked_root = self.root / 'linked-root'
        os.symlink(self.source_blobs, linked_root)
        target = self.root / 'other'
        result = rest.restore(rest.parse(['--archive', self.archive, '--target-data-dir', str(target / 'data'),
                                          '--target-policy-dir', str(target / 'policy'), '--skip-unit-check',
                                          '--blob-source', str(linked_root)]))
        self.assertEqual(result['blobs']['placed'], 0)
        self.assertEqual(result['blobs']['sources_refused'], [str(linked_root)])

    def test_path_escape_rows_are_refused_and_nothing_is_written_outside(self):
        args = args_for(self.root / 'evil-source', self.root / 'evil-inbox')
        data = Path(args.data_dir)
        good = add_blob(data, 'family-acc', self.FIRST)
        escaped = hashlib.sha256(b'escape').hexdigest()
        blob_row(data, '../../escaped', escaped, 6)
        blob_row(data, '.tmp', escaped, 6)
        archive = snap.snapshot(args)['archive']
        mirror = self.root / 'evil-inbox' / 'blobs'
        blob_file(mirror, 'family-acc', good, self.FIRST)
        blob_file(self.root, 'escaped', escaped, b'escape')  # where '../../escaped' would point from the mirror
        target = self.root / 'deep' / 'standby'
        target.mkdir(parents=True)
        result = rest.restore(rest.parse(['--archive', archive, '--target-data-dir', str(target / 'data'),
                                          '--target-policy-dir', str(target / 'policy'), '--skip-unit-check']))
        self.assertEqual(result['blobs']['summary'],
                         'blobs: rows=3 placed=1 already=0 missing=0 mismatch=0 refused=2 INCOMPLETE')
        self.assertFalse(result['blobs']['clean'])
        self.assertEqual(sorted(p.name for p in (self.root / 'deep').iterdir()), ['standby'])
        self.assertEqual(sorted(p.name for p in target.iterdir()), ['data', 'policy'])
        self.assertEqual(list((target / 'data' / 'blobs' / '.tmp').iterdir()), [])

    def test_already_present_verified_file_is_left_and_a_damaged_one_is_replaced(self):
        data = self.target / 'data'
        rest.restore(rest.parse(self.argv()))  # database in place, both blobs missing
        db = data / snap.DB_NAME
        kept = blob_file(data / 'blobs', 'family-acc', self.first, self.FIRST)
        before = kept.stat().st_mtime_ns
        blob_file(data / 'blobs', 'fleet', self.second, b'damaged')
        blob_file(self.mirror, 'fleet', self.second, self.SECOND)
        result = rest.place_blobs(db, data, [self.mirror])
        self.assertEqual(result['summary'], 'blobs: rows=2 placed=1 already=1 missing=0 mismatch=0')
        self.assertEqual(kept.stat().st_mtime_ns, before)
        self.assertEqual(self.placed('fleet', self.second).read_bytes(), self.SECOND)

    def test_one_unreadable_blob_does_not_stop_the_others(self):
        blob_file(self.mirror, 'family-acc', self.first, self.FIRST)
        blob_file(self.mirror, 'fleet', self.second, self.SECOND)
        real = rest.copy_verified

        def failing(source, *rest_args):
            if self.first in str(source):
                raise OSError(5, 'Input/output error')
            return real(source, *rest_args)

        with mock.patch.object(rest, 'copy_verified', failing):
            result = self.restore()
        self.assertEqual((result['blobs']['placed'], result['blobs']['missing'], result['blobs']['errors']), (1, 1, 1))
        self.assertTrue(result['counts_match'])

    def test_summary_only_counts_what_the_mirror_could_serve_and_writes_nothing(self):
        blob_file(self.mirror, 'family-acc', self.first, self.FIRST)
        summary = rest.restore(rest.parse(['--archive', self.archive, '--summary-only']))
        self.assertEqual({k: summary['blobs'][k] for k in ('rows', 'available', 'missing', 'refused')},
                         {'rows': 2, 'available': 1, 'missing': 1, 'refused': 0})
        self.assertEqual(summary['blobs']['bytes'], len(self.FIRST) + len(self.SECOND))
        self.assertEqual(list(self.target.iterdir()), [])

    @NEEDS_RSYNC
    def test_snapshot_push_then_restore_end_to_end(self):
        source = self.root / 'e2e-source'
        standby_inbox = self.root / 'e2e-standby' / 'inbox'
        standby_inbox.mkdir(parents=True)
        args = args_for(source, self.root / 'e2e-local', push=[str(standby_inbox)])
        ids = [add_blob(Path(args.data_dir), 'family-acc', b'attachment %d' % n) for n in range(3)]
        payload = snap.snapshot(args)
        self.assertEqual(payload['status'], 'complete', payload)
        target = self.root / 'e2e-live'
        result = rest.restore(rest.parse(['--archive', str(standby_inbox / Path(payload['archive']).name),
                                          '--target-data-dir', str(target / 'data'),
                                          '--target-policy-dir', str(target / 'policy'), '--skip-unit-check']))
        self.assertEqual(result['blobs']['summary'], 'blobs: rows=3 placed=3 already=0 missing=0 mismatch=0')
        for n, blob_id in enumerate(ids):
            self.assertEqual((target / 'data' / 'blobs' / 'family-acc' / blob_id).read_bytes(), b'attachment %d' % n)


if __name__ == '__main__':
    unittest.main()
