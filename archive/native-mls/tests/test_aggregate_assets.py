"""Fixture bundling must retain previous/unsafe output rather than overwrite it."""
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import native_aggregate_checks as fixture

ROOT=Path(__file__).resolve().parents[1]


class AggregateAssetTests(unittest.TestCase):
    def test_private_outputs_and_existing_bundle_retained(self):
        with tempfile.TemporaryDirectory(prefix='.aggregate-assets-',dir=ROOT) as directory:
            work=Path(directory)
            with patch.object(fixture.subprocess,'run',return_value=SimpleNamespace(stdout=b'generated bundle')):
                old=os.umask(0o022)
                try:fixture.aggregate_assets(ROOT,work,{})
                finally:os.umask(old)
                files={p.name:p.read_bytes() for p in work.iterdir()}
                self.assertEqual(len(files),3)
                for p in work.iterdir():self.assertEqual(p.stat().st_mode & 0o777,0o600)
                with self.assertRaises(FileExistsError):fixture.aggregate_assets(ROOT,work,{})
                self.assertEqual(files,{p.name:p.read_bytes() for p in work.iterdir()})

    def test_symlink_output_and_foreign_bytes_retained(self):
        with tempfile.TemporaryDirectory(prefix='.aggregate-assets-',dir=ROOT) as directory:
            work=Path(directory);foreign=work/'foreign';foreign.write_bytes(b'keep')
            link=work/'aggregate-store-original.js';link.symlink_to(foreign)
            with patch.object(fixture.subprocess,'run',return_value=SimpleNamespace(stdout=b'must not replace')):
                with self.assertRaises(FileExistsError):fixture.aggregate_assets(ROOT,work,{})
            self.assertTrue(link.is_symlink());self.assertEqual(foreign.read_bytes(),b'keep')
            self.assertEqual(len(list(work.iterdir())),2)

    def test_unsafe_or_symlink_work_directory_rejected_before_build(self):
        with tempfile.TemporaryDirectory(prefix='.aggregate-assets-',dir=ROOT) as directory:
            parent=Path(directory);work=parent/'work';work.mkdir(mode=0o700);link=parent/'link';link.symlink_to(work)
            with patch.object(fixture.subprocess,'run') as build:
                with self.assertRaises(AssertionError):fixture.aggregate_assets(ROOT,link,{})
                work.chmod(0o755)
                with self.assertRaises(AssertionError):fixture.aggregate_assets(ROOT,work,{})
                build.assert_not_called()
            self.assertFalse(list(work.iterdir()))
