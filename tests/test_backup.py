import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]/'scripts'))
from backup import backup_pair, snapshot_id, DIRECTORIES, FILES


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


if __name__ == '__main__':
    unittest.main()
