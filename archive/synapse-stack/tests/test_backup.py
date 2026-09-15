import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]/'scripts'))
from backup import backup_pair, backup_target, main, snapshot_id, DIRECTORIES, FILES, GIB

TARGET = {'BACKUP_TARGET_HOST': 'backup@target.invalid', 'BACKUP_TARGET_PATH': '/var/backups/family'}
SUMMARY = '{"message_type":"summary","snapshot_id":"fixture"}'


class BackupTests(unittest.TestCase):
    def fixture(self, root, config=None):
        for name in DIRECTORIES: (root/name).mkdir(parents=True, exist_ok=True)
        for name in FILES:
            p = root/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('fixture')
        (root/'.runtime/synapse/homeserver.yaml').write_text(json.dumps(config or {}))

    def test_success_pairs_db_before_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root); commands = []
            def execute(cmd):
                commands.append(cmd)
                return json.dumps({'message_type': 'summary', 'snapshot_id': str(len(commands))})
            result = backup_pair(root, execute)
            self.assertEqual((result['database_snapshot'], result['files_snapshot']), ('1', '2'))
            self.assertIn('--stdin-from-command', commands[0])
            self.assertIn(str(root/'.runtime'), commands[1])
            self.assertTrue(all(result['pair'] in c for c in commands))

    def test_database_failure_does_not_start_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root); calls = []
            def execute(cmd):
                calls.append(cmd); raise RuntimeError('fixture failure')
            with self.assertRaises(RuntimeError): backup_pair(root, execute)
            self.assertEqual(len(calls), 1)

    def test_files_failure_cannot_return_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root); calls = []
            def execute(cmd):
                calls.append(cmd)
                if len(calls) == 2: raise RuntimeError('fixture failure')
                return '{"message_type":"summary","snapshot_id":"database"}'
            with self.assertRaises(RuntimeError): backup_pair(root, execute)

    def test_retention_refused_and_missing_summary_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root, {'media_retention': {'local_media_lifetime':'1d'}})
            with self.assertRaises(ValueError): backup_pair(root, lambda _: self.fail('must not start backup'))
        with self.assertRaises(RuntimeError): snapshot_id('{"message_type":"status"}')

    def test_missing_or_symlink_source_never_starts_backup(self):
        for kind in ('missing', 'symlink'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); self.fixture(root); (root/'compose.yaml').unlink()
                if kind == 'symlink': (root/'compose.yaml').symlink_to(root/'.env')
                with self.assertRaises((OSError, ValueError)):
                    backup_pair(root, lambda _: self.fail('must not start backup'))

    def test_config_change_or_disappearance_cannot_return_complete(self):
        for kind in ('change', 'disappear'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); self.fixture(root); calls = []
                def execute(cmd):
                    calls.append(cmd)
                    if len(calls) == 2:
                        if kind == 'change': (root/'compose.yaml').write_text('changed fixture')
                        else: (root/'compose.yaml').unlink()
                    return '{"message_type":"summary","snapshot_id":"fixture"}'
                with self.assertRaises((OSError, RuntimeError)): backup_pair(root, execute)


class MainTests(unittest.TestCase):
    """main() with injected execute/env: no ssh, restic, docker or /var access."""

    def run_main(self, env, execute, free=200*GIB, retained=1*GIB):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)/'root'; root.mkdir(); BackupTests.fixture(self, root)
            state = Path(tmp)/'state'; out, err = io.StringIO(), io.StringIO()
            with patch('backup.measure', return_value=(retained, free, 0)), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = main(execute, env, root, state)
            records = [json.loads(p.read_text()) for p in sorted(state.glob('pair-*.json'))] if state.exists() else []
            return code, out.getvalue(), err.getvalue(), records

    def test_missing_target_fails_closed_before_any_subprocess(self):
        for env in ({}, {'BACKUP_TARGET_HOST': 'target.invalid'}, {'BACKUP_TARGET_PATH': '/var/backups'},
                    {**TARGET, 'BACKUP_TARGET_HOST': '-oProxyCommand=evil'},
                    {**TARGET, 'BACKUP_TARGET_PATH': 'relative'}, {**TARGET, 'BACKUP_TARGET_PATH': '/a/../b'},
                    {**TARGET, 'BACKUP_TARGET_HOST': 'host; rm -rf /'}):
            with self.subTest(env=env):
                env = {**env, 'RESTIC_PASSWORD': 'fixture-secret'}
                code, out, err, records = self.run_main(env, lambda _: self.fail('must not start any subprocess'))
                self.assertEqual((code, records), (1, []))
                self.assertEqual(json.loads(out), {'status': 'failed', 'error_type': 'ValueError'})
                self.assertIn('ValueError: BACKUP_TARGET_', err)
                self.assertIn('/etc/family-messenger/backup.env', err)
                self.assertIn('Traceback', err)
                self.assertNotIn('fixture-secret', err)

    def test_target_from_env_is_checked_before_backup_starts(self):
        commands = []
        def execute(cmd):
            commands.append(cmd)
            return str(500*GIB) if cmd[0] == 'ssh' else SUMMARY
        code, out, err, records = self.run_main(TARGET, execute)
        self.assertEqual((code, err), (0, ''))
        self.assertEqual(commands[0][0], 'ssh')
        self.assertIn('backup@target.invalid', commands[0])
        self.assertIn("'/var/backups/family'", commands[0][-1])
        self.assertEqual([c[:2] for c in commands[1:]], [['restic', 'backup']]*2)
        self.assertEqual(len(records), 1)
        self.assertEqual(json.loads(out)['status'], 'complete')
        self.assertEqual(records[0]['status'], 'complete')

    def test_small_or_unreadable_remote_space_stops_before_restic(self):
        for reply, error_type in (('1', 'ValueError'), ('not a number', 'RuntimeError')):
            with self.subTest(reply=reply):
                commands = []
                def execute(cmd):
                    commands.append(cmd); return reply
                code, out, err, records = self.run_main(TARGET, execute)
                self.assertEqual((code, len(commands), records), (1, 1, []))
                self.assertEqual(json.loads(out)['error_type'], error_type)
                self.assertIn(error_type+': ', err)

    def test_backup_target_accepts_plain_hosts(self):
        self.assertEqual(backup_target({'BACKUP_TARGET_HOST': 'nas', 'BACKUP_TARGET_PATH': '/'}), ('nas', '/'))


if __name__ == '__main__':
    unittest.main()
