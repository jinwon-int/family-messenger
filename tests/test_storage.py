import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('storage', Path(__file__).parents[1]/'scripts/check_storage.py')
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)


class StorageTests(unittest.TestCase):
    def test_thresholds_and_combined_alerts(self):
        self.assertEqual(storage.evaluate(100, 1000, 149, 100, 150)['status'], 'ok')
        self.assertEqual(storage.evaluate(99, 1000, 150, 100, 150)['alerts'],
                         ['filesystem_free_below_reserve', 'retention_budget_reached'])

    def test_real_allocated_bytes_and_nested_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root/'nested').mkdir()
            f = root/'nested/data'; f.write_bytes(b'x'*8192)
            expected = sum(p.stat().st_blocks*512 for p in (root, root/'nested', f))
            self.assertEqual(storage.tree_bytes(root), expected)

    def test_links_rejected_without_reading_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root/'link').symlink_to('/does-not-exist')
            with self.assertRaises(ValueError): storage.tree_bytes(root)
            with self.assertRaises(OSError): storage.tree_bytes(root/'link')

    def test_ancestor_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root/'real/data').mkdir(parents=True)
            (root/'alias').symlink_to(root/'real', target_is_directory=True)
            with self.assertRaises(OSError): storage.tree_bytes(root/'alias/data')

    def test_hardlinks_counted_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); f = root/'a'; f.write_bytes(b'x'*8192)
            (root/'b').hardlink_to(f)
            expected = (root.stat().st_blocks+f.stat().st_blocks)*512
            self.assertEqual(storage.tree_bytes(root), expected)


if __name__ == '__main__':
    unittest.main()
