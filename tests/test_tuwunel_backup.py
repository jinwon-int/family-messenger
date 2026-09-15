import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import tuwunel_backup as tb
from tuwunel_backup import (
    backup_pair, online_backup, parse, parse_backup_ids, snapshot_id, validate_sources,
)
from tuwunel_config import load_tuwunel_config, setting
from tuwunel_restore_drill import drill, local_url, probe
import tuwunel_restore_drill as drill_module


def fixture(root, backups_inside=False, backups_key=True):
    """Stage-1 layout in the tuwunel.toml.example shape: database, media inside it, backups OUTSIDE it."""
    database = root / 'data' / 'db'
    (database / 'media').mkdir(parents=True)
    (database / 'CURRENT').write_text('db')
    (database / 'media' / 'm1.bin').write_text('m')
    backups = database / 'backups' if backups_inside else root / 'data' / 'backups'
    backups.mkdir(parents=True)
    (backups / 'b1').write_text('db')
    config = root / 'tuwunel.toml'
    lines = ['[global]', 'server_name = "family.example"', 'address = ["127.0.0.1"]', 'port = 18809',
             'database_path = ' + json.dumps(str(database))]
    if backups_key:
        lines.append('database_backup_path = ' + json.dumps(str(backups)))
    config.write_text('\n'.join(lines) + '\n')
    return config, database, backups


class FakeAdmin:
    """Stand-in for tuwunel_admin_room.AdminRoom recording the live-server commands issued."""

    def __init__(self, listing='#1 backup 1005087 bytes, 60 files', backup='Done. Currently have 1 backups.',
                 verify='Verified. all files present'):
        self.calls = []
        self.replies = {'backup-database': backup, 'list-backups': listing, 'verify-backup': verify}

    def _reply(self, name):
        self.calls.append(name)
        reply = self.replies[name]
        if isinstance(reply, Exception):
            raise reply
        return reply

    def backup_database(self):
        return self._reply('backup-database')

    def list_backups(self):
        return self._reply('list-backups')

    def verify_backup(self):
        return self._reply('verify-backup')


class SettingTests(unittest.TestCase):
    def test_top_level_then_global_section(self):
        self.assertEqual(setting({'server_name': 'a.example'}, 'server_name'), 'a.example')
        self.assertEqual(setting({'global': {'database_path': '/x'}}, 'database_path'), '/x')
        with self.assertRaises(KeyError):
            setting({}, 'server_name')

    def test_load_config_reads_database_and_backup_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp))
            loaded = load_tuwunel_config(config)
            self.assertEqual((loaded['database'], loaded['database_backup_path']), (database, backups))


class ValidateSourcesTests(unittest.TestCase):
    def test_accepts_regular_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp))
            self.assertEqual(validate_sources(load_tuwunel_config(config)), (backups, database / 'media'))

    def test_rejects_backup_dir_inside_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp), backups_inside=True)
            with self.assertRaisesRegex(ValueError, 'inside database_path'):
                validate_sources(load_tuwunel_config(config))

    def test_rejects_missing_backup_path_setting(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp), backups_key=False)
            with self.assertRaisesRegex(ValueError, 'database_backup_path is required'):
                validate_sources(load_tuwunel_config(config))

    def test_rejects_missing_backup_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp))
            (backups / 'b1').unlink()
            backups.rmdir()
            with self.assertRaises(ValueError):
                validate_sources(load_tuwunel_config(config))

    def test_rejects_missing_media(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp))
            (database / 'media').rename(database / 'media.saved')
            with self.assertRaises(ValueError):
                validate_sources(load_tuwunel_config(config))

    def test_rejects_symlinked_media(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp))
            (database / 'media' / 'm1.bin').unlink()
            (database / 'media').rmdir()
            (database / 'media').symlink_to(backups)
            with self.assertRaises(ValueError):
                validate_sources(load_tuwunel_config(config))

    def test_rejects_non_regular_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp))
            loaded = load_tuwunel_config(config)
            config.unlink()
            config.symlink_to(database / 'media' / 'm1.bin')
            with self.assertRaises(ValueError):
                validate_sources(loaded)


class OnlineBackupTests(unittest.TestCase):
    def test_happy_path_orders_live_server_commands(self):
        admin = FakeAdmin()
        self.assertEqual(online_backup(admin), 1)
        self.assertEqual(admin.calls, ['backup-database', 'list-backups', 'verify-backup'])

    def test_failed_verify_refuses(self):
        admin = FakeAdmin(verify='verification failed: 2 files missing')
        with self.assertRaises(RuntimeError):
            online_backup(admin)

    def test_backup_without_done_refuses_before_listing(self):
        admin = FakeAdmin(backup='error: backup failed')
        with self.assertRaises(RuntimeError):
            online_backup(admin)
        self.assertEqual(admin.calls, ['backup-database'])

    def test_empty_listing_refuses(self):
        with self.assertRaises(RuntimeError):
            online_backup(FakeAdmin(listing=''))

    def test_parse_backup_ids(self):
        self.assertEqual(parse_backup_ids('#1 ...\nnoise\n#12 ...\n#3 ...'), [1, 3, 12])
        self.assertEqual(parse_backup_ids('nothing here'), [])


class BackupPairTests(unittest.TestCase):
    def scripted(self, calls, fail_second_restic=False):
        def execute(command):
            calls.append(command)
            if command[0] == 'restic':
                done = sum(1 for c in calls if c[0] == 'restic')
                if fail_second_restic and done == 2:
                    raise RuntimeError('fixture failure')
                return json.dumps({'message_type': 'summary', 'snapshot_id': 'snap' + str(done)})
            raise AssertionError(command)
        return execute

    def test_database_before_media_with_shared_pair_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp))
            calls = []
            admin = FakeAdmin()
            record = backup_pair(load_tuwunel_config(config), self.scripted(calls), admin)
            self.assertEqual(admin.calls, ['backup-database', 'list-backups', 'verify-backup'])
            self.assertEqual(len(calls), 2)
            self.assertTrue(all(c[0] == 'restic' for c in calls))  # no tuwunel subprocess at all
            self.assertIn('database', calls[0])
            self.assertIn(str(backups), calls[0])  # database_backup_path, not <database>/backups
            self.assertNotIn(str(database / 'backups'), calls[0])
            self.assertIn(str(config), calls[0])
            self.assertIn('media', calls[1])
            self.assertIn(str(database / 'media'), calls[1])
            self.assertEqual(record['pair'], calls[0][6])
            self.assertEqual(record['pair'], calls[1][6])
            self.assertEqual((record['database_snapshot'], record['media_snapshot']), ('snap1', 'snap2'))
            self.assertEqual((record['backup_id'], record['status']), (1, 'complete'))

    def test_media_failure_never_returns_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, _, _ = fixture(Path(tmp))
            calls = []
            with self.assertRaises(RuntimeError):
                backup_pair(load_tuwunel_config(config), self.scripted(calls, fail_second_restic=True), FakeAdmin())
            self.assertEqual(sum(1 for c in calls if c[0] == 'restic'), 2)

    def test_missing_media_never_starts_anything(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp))
            (database / 'media').rename(database / 'elsewhere')
            calls = []
            admin = FakeAdmin()
            with self.assertRaises(ValueError):
                backup_pair(load_tuwunel_config(config), self.scripted(calls), admin)
            self.assertEqual((calls, admin.calls), ([], []))

    def test_backup_dir_inside_database_never_starts_anything(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, _, _ = fixture(Path(tmp), backups_inside=True)
            calls = []
            admin = FakeAdmin()
            with self.assertRaises(ValueError):
                backup_pair(load_tuwunel_config(config), self.scripted(calls), admin)
            self.assertEqual((calls, admin.calls), ([], []))


class CommandLineTests(unittest.TestCase):
    def test_flags_mirror_the_drill_with_defaults(self):
        args = parse([])
        self.assertEqual((args.config, args.state, args.admin_token_file),
                         (tb.TUWUNEL_CONFIG, tb.STATE, tb.TUWUNEL_TOKEN))
        args = parse(['--config', '/tmp/c.toml', '--state', '/tmp/s', '--admin-token-file', '/tmp/t'])
        self.assertEqual((args.config, args.state, args.admin_token_file),
                         (Path('/tmp/c.toml'), Path('/tmp/s'), Path('/tmp/t')))

    def test_main_uses_flags_and_writes_record_into_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config, database, backups = fixture(root)
            token = root / 'admin_token'
            token.write_text('tok\n')
            token.chmod(0o600)
            state = root / 'state'
            record = {'pair': 'tuwunel-x', 'status': 'complete'}
            built = []

            def fake_admin(base, server_name, token_text):
                built.append((base, server_name, token_text))
                return 'admin'

            with mock.patch.object(tb, 'AdminRoom', fake_admin), \
                 mock.patch.object(tb, 'backup_pair', return_value=record) as pair, \
                 mock.patch.object(tb, 'FREE_RESERVE', 0), \
                 mock.patch('sys.stdout'):
                self.assertEqual(tb.main(['--config', str(config), '--state', str(state),
                                          '--admin-token-file', str(token)]), 0)
            self.assertEqual(built, [('http://127.0.0.1:18809', 'family.example', 'tok')])
            self.assertEqual(pair.call_args.args[0]['config_path'], config)
            self.assertEqual(pair.call_args.args[2], 'admin')
            self.assertEqual(json.loads((state / 'tuwunel-x.json').read_text()), record)
            self.assertEqual((state / 'tuwunel-x.json').stat().st_mode & 0o777, 0o600)
            self.assertTrue((state / 'tuwunel-backup.lock').exists())

    def test_main_fails_closed_without_backup_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config, _, _ = fixture(root, backups_key=False)
            with mock.patch.object(tb, 'backup_pair') as pair, mock.patch('sys.stderr'):
                self.assertEqual(tb.main(['--config', str(config), '--state', str(root / 'state'),
                                          '--admin-token-file', str(root / 'missing')]), 1)
            pair.assert_not_called()


class SnapshotIdTests(unittest.TestCase):
    def test_single_summary_required(self):
        line = json.dumps({'message_type': 'summary', 'snapshot_id': 'abc'})
        self.assertEqual(snapshot_id(line), 'abc')
        with self.assertRaises(RuntimeError):
            snapshot_id(json.dumps({'message_type': 'status'}))
        with self.assertRaises(RuntimeError):
            snapshot_id(line + '\n' + line)


class DrillTests(unittest.TestCase):
    def run_drill(self, config, execute, admin=None, log=None, **kwargs):
        logs = []
        return drill(config, 'tuwunel', ['stop'], ['start'], admin or FakeAdmin(listing='#1 ...\n#2 ...'),
                     execute=execute, log=log or logs.append, **kwargs), logs

    def test_happy_path_lists_live_stops_restores_copies_media_starts(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                if '--restore-backup' in command:
                    (database / 'CURRENT').write_text('restored')
                    (database / 'media').mkdir()
                    return 'log: Restored database backup backup_id=2'
                return 'ok'

            checks = []
            admin = FakeAdmin(listing='#1 ...\n#2 ...')
            record, _ = self.run_drill(config, execute, admin, check=lambda url: checks.append(url) or True)
            self.assertEqual((record['status'], record['backup_id'], record['service']),
                             ('complete', 2, 'started'))
            self.assertEqual(admin.calls, ['list-backups'])  # listing came from the live server
            self.assertTrue((database / 'media' / 'm1.bin').exists())
            self.assertEqual((database / 'CURRENT').read_text(), 'restored')
            saved = list((Path(tmp) / 'data').glob('db.pre-restore-*'))
            self.assertEqual(len(saved), 1)
            self.assertEqual((saved[0] / 'CURRENT').read_text(), 'db')
            self.assertTrue((backups / 'b1').exists())  # backups untouched by the rename
            self.assertEqual(record['preserved'], saved[0].name)
            self.assertEqual(calls[0], ['stop'])
            self.assertEqual(calls[1][:1], ['tuwunel'])
            self.assertIn('--restore-backup', calls[1])
            self.assertEqual(calls[1][calls[1].index('--restore-backup') + 1], '2')  # explicit id
            self.assertIn('--maintenance', calls[1])
            self.assertEqual(calls[1][-2:], ['--execute', 'server shutdown'])
            self.assertEqual(calls[2], ['start'])
            self.assertFalse(any('list-backups' in c for c in calls))  # never a second tuwunel --execute
            self.assertEqual(checks, ['http://127.0.0.1:18809'])

    def test_restore_failure_rolls_back_and_restarts(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, backups = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                if '--restore-backup' in command:
                    (database / 'partial').write_text('x')
                    raise RuntimeError('fixture failure')
                return 'ok'

            with self.assertRaisesRegex(RuntimeError, 'rolled back'):
                self.run_drill(config, execute)
            self.assertEqual(calls[-1], ['start'])  # service brought back on the preserved database
            self.assertEqual((database / 'CURRENT').read_text(), 'db')
            self.assertTrue((database / 'media' / 'm1.bin').exists())
            self.assertEqual(list((Path(tmp) / 'data').glob('db.pre-restore-*')), [])
            failed = list((Path(tmp) / 'data').glob('db.failed-restore-*'))
            self.assertEqual(len(failed), 1)
            self.assertTrue((failed[0] / 'partial').exists())

    def test_rollback_logs_clearly_and_removes_empty_attempt_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp))
            logs = []

            def execute(command):
                if '--restore-backup' in command:
                    raise RuntimeError('fixture failure')
                return 'ok'

            with self.assertRaises(RuntimeError):
                self.run_drill(config, execute, log=logs.append)
            self.assertTrue(any('rolling back' in line for line in logs))
            self.assertTrue(any('back to db' in line for line in logs))
            self.assertTrue(any('start command issued' in line for line in logs))
            self.assertEqual(list((Path(tmp) / 'data').glob('db.failed-restore-*')), [])
            self.assertEqual((database / 'CURRENT').read_text(), 'db')

    def test_rollback_start_failure_is_logged_and_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp))
            logs = []

            def execute(command):
                if command == ['stop']:
                    return 'ok'
                raise RuntimeError('fixture failure')

            with self.assertRaises(RuntimeError):
                self.run_drill(config, execute, log=logs.append)
            self.assertEqual((database / 'CURRENT').read_text(), 'db')  # database is back regardless
            self.assertTrue(any('start FAILED after rollback' in line for line in logs))

    def test_empty_restored_database_rolls_back(self):
        # Tuwunel 1.9.1 confirms a restore only by effect: a missing id fails
        # with a nonzero exit (binary fail-closed), but a successful one-shot
        # prints just the shutdown line. An empty database directory after a
        # zero-exit restore therefore means nothing was restored — drill must
        # roll back instead of reporting success.
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                if '--restore-backup' in command:
                    (database / 'media').mkdir()  # restore scaffolding, no data
                    return 'Shutting down server...'
                return 'ok'

            drill_logs = []

            def run():
                self.run_drill(config, execute, log=drill_logs.append)

            with self.assertRaisesRegex(RuntimeError, 'rolled back'):
                run()
            self.assertTrue(any('empty database directory' in line for line in drill_logs))
            self.assertEqual((database / 'CURRENT').read_text(), 'db')
            self.assertEqual(calls[-1], ['start'])
            self.assertEqual(len(list((Path(tmp) / 'data').glob('db.failed-restore-*'))), 1)

    def test_backup_dir_inside_database_refuses_before_stop(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp), backups_inside=True)
            calls = []
            admin = FakeAdmin()
            with self.assertRaisesRegex(ValueError, 'inside database_path'):
                self.run_drill(config, calls.append, admin)
            self.assertEqual((calls, admin.calls), ([], []))
            self.assertTrue((database / 'CURRENT').exists())

    def test_missing_backup_path_refuses_before_stop(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp), backups_key=False)
            calls = []
            with self.assertRaisesRegex(ValueError, 'database_backup_path is required'):
                self.run_drill(config, calls.append)
            self.assertEqual(calls, [])

    def test_empty_listing_refuses_before_stop(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp))
            calls = []
            with self.assertRaises(ValueError):
                self.run_drill(config, calls.append, FakeAdmin(listing=''))
            self.assertEqual(calls, [])

    def test_unknown_backup_id_refuses_before_stop(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp))
            calls = []
            with self.assertRaises(ValueError):
                self.run_drill(config, calls.append, backup_id=9)
            self.assertEqual(calls, [])

    def test_missing_stop_or_start_command_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp))
            with self.assertRaises(ValueError):
                drill(config, 'tuwunel', None, ['start'], FakeAdmin(), execute=lambda c: '')
            with self.assertRaises(ValueError):
                drill(config, 'tuwunel', ['stop'], None, FakeAdmin(), execute=lambda c: '')
            self.assertTrue(database.exists())  # untouched

    def test_missing_database_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database, _ = fixture(Path(tmp))
            database.rename(database.parent / 'moved')
            with self.assertRaises(ValueError):
                drill(config, 'tuwunel', ['stop'], ['start'], FakeAdmin(), execute=lambda c: '')

    def test_main_builds_admin_room_from_config_and_token_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config, _, _ = fixture(root)
            token = root / 'admin_token'
            token.write_text('tok\n')
            token.chmod(0o600)
            built = []

            def fake_admin(base, server_name, token_text):
                built.append((base, server_name, token_text))
                return 'admin'

            with mock.patch.object(drill_module, 'AdminRoom', fake_admin), \
                 mock.patch.object(drill_module, 'drill', return_value={'status': 'complete'}) as run, \
                 mock.patch('sys.stdout'):
                self.assertEqual(drill_module.main(['--config', str(config), '--admin-token-file', str(token),
                                                    '--stop-command', 'stop', '--start-command', 'start',
                                                    '--yes', '--skip-probe']), 0)
            self.assertEqual(built, [('http://127.0.0.1:18809', 'family.example', 'tok')])
            self.assertEqual(run.call_args.args[4], 'admin')

    def test_local_url_from_loopback_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, _, _ = fixture(Path(tmp))
            self.assertEqual(local_url(config), 'http://127.0.0.1:18809')

    def test_probe_against_live_and_dead_socket(self):
        import http.server
        import socket
        import threading

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{}')

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            self.assertTrue(probe('http://127.0.0.1:%d' % server.server_port, attempts=2, delay=0))
        finally:
            server.shutdown()
            server.server_close()
        sock = socket.socket()
        sock.bind(('127.0.0.1', 0))
        closed_port = sock.getsockname()[1]
        sock.close()
        self.assertFalse(probe('http://127.0.0.1:%d' % closed_port, attempts=2, delay=0))


if __name__ == '__main__':
    unittest.main()
