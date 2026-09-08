import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]/'scripts'))
from backup import backup_pair, snapshot_id


class BackupTests(unittest.TestCase):
    def fixture(self, root, config=None):
        p = root/'.runtime/synapse'; p.mkdir(parents=True)
        (p/'homeserver.yaml').write_text(json.dumps(config or {}))

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


if __name__ == '__main__':
    unittest.main()
