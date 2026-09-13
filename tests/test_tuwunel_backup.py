import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
from tuwunel_backup import backup_pair, load_config, online_backup, parse_backup_ids, setting, snapshot_id, validate_sources
from tuwunel_restore_drill import drill, local_url, probe


def fixture(root):
    """Build a minimal stage-1 layout: config, database backups dir, media dir."""
    database = root / 'data' / 'db'
    (database / 'backups').mkdir(parents=True)
    (database / 'media').mkdir()
    (database / 'backups' / 'b1').write_text('db')
    (database / 'media' / 'm1.bin').write_text('m')
    config = root / 'tuwunel.toml'
    config.write_text('server_name = "family.example"\n'
                      'address = "127.0.0.1"\n'
                      'port = 18809\n'
                      '[database]\n'
                      'path = ' + json.dumps(str(database)) + '\n')
    return config, database


class SettingTests(unittest.TestCase):
    def test_top_level_then_global_section(self):
        self.assertEqual(setting({'server_name': 'a.example'}, 'server_name'), 'a.example')
        self.assertEqual(setting({'global': {'database': {'path': '/x'}}},
                                 'database', 'path'), '/x')
        with self.assertRaises(KeyError):
            setting({}, 'server_name')

    def test_load_config_reads_database_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            self.assertEqual(load_config(config), database)


class ValidateSourcesTests(unittest.TestCase):
    def test_accepts_regular_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            self.assertEqual(validate_sources(config, database),
                             (database / 'backups', database / 'media'))

    def test_rejects_missing_media(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            (database / 'media').rename(database / 'media.saved')
            with self.assertRaises(ValueError):
                validate_sources(config, database)

    def test_rejects_symlinked_media(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            (database / 'media' / 'm1.bin').unlink()
            (database / 'media').rmdir()
            (database / 'media').symlink_to(database / 'backups')
            with self.assertRaises(ValueError):
                validate_sources(config, database)

    def test_rejects_non_regular_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            config.unlink()
            config.symlink_to(database / 'media' / 'm1.bin')
            with self.assertRaises(ValueError):
                validate_sources(config, database)


class OnlineBackupTests(unittest.TestCase):
    def test_happy_path_orders_builtin_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, _ = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                if command[-1] == 'server backup-database':
                    return 'Done. Currently have 1 backups.'
                if command[-1] == 'server list-backups':
                    return '#1 backup 1005087 bytes, 60 files'
                if command[-1] == 'server verify-backup':
                    return 'Verified. all files present'
                raise AssertionError(command)

            self.assertEqual(online_backup(config, execute), 1)
            self.assertEqual([c[-1] for c in calls],
                             ['server backup-database', 'server list-backups', 'server verify-backup'])
            for command in calls:
                self.assertEqual(command[:3], ['tuwunel', '-c', str(config)])

    def test_failed_verify_blocks_snapshots(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, _ = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                if command[-1] == 'server backup-database':
                    return 'Done.'
                if command[-1] == 'server list-backups':
                    return '#1 ...'
                return 'verification failed: 2 files missing'

            with self.assertRaises(RuntimeError):
                online_backup(config, execute)
            self.assertNotIn('restic', {c[0] for c in calls})

    def test_empty_listing_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, _ = fixture(Path(tmp))

            def execute(command):
                return 'Done.' if command[-1] == 'server backup-database' else ''

            with self.assertRaises(RuntimeError):
                online_backup(config, execute)

    def test_parse_backup_ids(self):
        self.assertEqual(parse_backup_ids('#1 ...\nnoise\n#12 ...\n#3 ...'), [1, 3, 12])
        self.assertEqual(parse_backup_ids('nothing here'), [])


class BackupPairTests(unittest.TestCase):
    def scripted(self, calls, fail_second_restic=False):
        def execute(command):
            calls.append(command)
            if '--execute' in command:
                if command[-1] == 'server backup-database':
                    return 'Done.'
                if command[-1] == 'server list-backups':
                    return '#1 ...'
                return 'all files present'
            if command[0] == 'restic':
                done = sum(1 for c in calls if c[0] == 'restic')
                if fail_second_restic and done == 2:
                    raise RuntimeError('fixture failure')
                return json.dumps({'message_type': 'summary',
                                   'snapshot_id': 'snap' + str(done)})
            raise AssertionError(command)
        return execute

    def test_database_before_media_with_shared_pair_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            calls = []
            record = backup_pair(config, self.scripted(calls))
            restic_calls = [c for c in calls if c[0] == 'restic']
            self.assertEqual(len(restic_calls), 2)
            self.assertLess(calls.index(restic_calls[0]), calls.index(restic_calls[1]))
            self.assertIn('database', restic_calls[0])
            self.assertIn(str(database / 'backups'), restic_calls[0])
            self.assertIn(str(config), restic_calls[0])
            self.assertIn('media', restic_calls[1])
            self.assertIn(str(database / 'media'), restic_calls[1])
            self.assertEqual(record['pair'], restic_calls[0][6])
            self.assertEqual(record['pair'], restic_calls[1][6])
            self.assertEqual((record['database_snapshot'], record['media_snapshot']),
                             ('snap1', 'snap2'))
            self.assertEqual((record['backup_id'], record['status']), (1, 'complete'))

    def test_media_failure_never_returns_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, _ = fixture(Path(tmp))
            calls = []
            with self.assertRaises(RuntimeError):
                backup_pair(config, self.scripted(calls, fail_second_restic=True))
            self.assertEqual(sum(1 for c in calls if c[0] == 'restic'), 2)

    def test_missing_media_never_starts_anything(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            (database / 'media').rename(database / 'elsewhere')
            calls = []
            with self.assertRaises(ValueError):
                backup_pair(config, self.scripted(calls))
            self.assertEqual(calls, [])


class SnapshotIdTests(unittest.TestCase):
    def test_single_summary_required(self):
        line = json.dumps({'message_type': 'summary', 'snapshot_id': 'abc'})
        self.assertEqual(snapshot_id(line), 'abc')
        with self.assertRaises(RuntimeError):
            snapshot_id(json.dumps({'message_type': 'status'}))
        with self.assertRaises(RuntimeError):
            snapshot_id(line + '\n' + line)


class DrillTests(unittest.TestCase):
    def test_happy_path_stops_restores_copies_media_starts(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                if command[-1] == 'server list-backups':
                    return '#1 ...\n#2 ...'
                if '--restore-backup' in command:
                    return 'log: Restored database backup backup_id=2'
                return 'ok'

            checks = []
            record = drill(config, 'tuwunel', ['stop'], ['start'],
                           execute=execute, check=lambda url: checks.append(url) or True)
            self.assertEqual((record['status'], record['backup_id'], record['service']),
                             ('complete', 2, 'started'))
            restored_database = load_config(config)
            self.assertTrue((restored_database / 'media' / 'm1.bin').exists())
            saved = list((Path(tmp) / 'data').glob('db.pre-restore-*'))
            self.assertEqual(len(saved), 1)
            self.assertTrue((saved[0] / 'backups' / 'b1').exists())
            self.assertEqual(record['preserved'], saved[0].name)
            self.assertEqual(calls[1], ['stop'])
            self.assertIn('--restore-backup', calls[2])
            self.assertIn('--maintenance', calls[2])
            self.assertEqual(calls[3], ['start'])
            self.assertEqual(checks, ['http://127.0.0.1:18809'])

    def test_restore_failure_keeps_state_and_never_starts(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                if command[-1] == 'server list-backups':
                    return '#1 ...'
                if command == ['stop']:
                    return 'ok'
                raise RuntimeError('fixture failure')

            with self.assertRaises(RuntimeError):
                drill(config, 'tuwunel', ['stop'], ['start'], execute=execute)
            self.assertNotIn(['start'], calls)
            self.assertFalse((database / 'media').exists())
            saved = list((Path(tmp) / 'data').glob('db.pre-restore-*'))
            self.assertEqual(len(saved), 1)
            self.assertTrue((saved[0] / 'backups' / 'b1').exists())

    def test_wrong_backup_id_in_output_never_starts(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                if command[-1] == 'server list-backups':
                    return '#1 ...\n#2 ...'
                if '--restore-backup' in command:
                    return 'Restored database backup backup_id=1'
                return 'ok'

            with self.assertRaises(RuntimeError):
                drill(config, 'tuwunel', ['stop'], ['start'], execute=execute)
            self.assertNotIn(['start'], calls)

    def test_empty_listing_refuses_before_stop(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                return ''

            with self.assertRaises(ValueError):
                drill(config, 'tuwunel', ['stop'], ['start'], execute=execute)
            self.assertEqual(len(calls), 1)

    def test_unknown_backup_id_refuses_before_stop(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            calls = []

            def execute(command):
                calls.append(command)
                return '#1 ...\n#2 ...'

            with self.assertRaises(ValueError):
                drill(config, 'tuwunel', ['stop'], ['start'], backup_id=9, execute=execute)
            self.assertEqual(len(calls), 1)

    def test_missing_stop_or_start_command_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            with self.assertRaises(ValueError):
                drill(config, 'tuwunel', None, ['start'], execute=lambda c: '')
            with self.assertRaises(ValueError):
                drill(config, 'tuwunel', ['stop'], None, execute=lambda c: '')
            self.assertTrue(database.exists())  # untouched

    def test_missing_database_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, database = fixture(Path(tmp))
            database.rename(database.parent / 'moved')
            with self.assertRaises(ValueError):
                drill(config, 'tuwunel', ['stop'], ['start'], execute=lambda c: '')

    def test_local_url_from_loopback_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, _ = fixture(Path(tmp))
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
