"""Build-only pinning failures must retain unknown/partial outputs."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('prepare_assets', Path(__file__).resolve().parents[1] / 'tools/prepare_mls_assets.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
PIN = json.loads(m.MANIFEST.read_text())

class AssetPreparationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = self.root / 'server/internal/chat/mlsassets'
        self.output.parent.mkdir(parents=True)
        self.manifest = self.output.parent / 'mls_bundle.json'
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        self.sources = []
        pin = json.loads(json.dumps(PIN))
        for entry in pin['files']:
            data = ('synthetic ' + entry['file']).encode()
            path = self.bundle / entry['source'][7:] if entry['source'].startswith('bundle:') else self.root / entry['source']
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o600)
            self.sources.append(path)
            entry['bytes'] = len(data)
            entry['sha256'] = hashlib.sha256(data).hexdigest()
        self.manifest.write_text(json.dumps(pin, indent=2) + '\n')
        self.manifest.chmod(0o600)
        p = patch.multiple(m, ROOT=self.root, MANIFEST=self.manifest, OUTPUT=self.output)
        p.start()
        self.addCleanup(p.stop)

    def rejected(self):
        with self.assertRaises((OSError, ValueError)):
            m.prepare(self.bundle)

    def test_exact_create_reuse_and_check(self):
        with self.assertRaises(ValueError):
            m.prepare(self.bundle, True)
        m.prepare(self.bundle)
        before = {p.name: (p.stat().st_ino, p.read_bytes()) for p in self.output.iterdir()}
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in self.output.iterdir()))
        m.prepare(self.bundle, True)
        m.prepare(self.bundle)
        self.assertEqual(before, {p.name: (p.stat().st_ino, p.read_bytes()) for p in self.output.iterdir()})

    def test_wrong_source_hash_never_creates_output(self):
        p = self.sources[0]
        p.write_bytes(b'X' * p.stat().st_size)
        self.rejected()
        self.assertFalse(self.output.exists())

    def test_input_link_and_writable_mode_denied(self):
        p = self.sources[0]
        original = p.read_bytes()
        target = p.with_suffix('.saved')
        p.rename(target)
        p.symlink_to(target)
        self.rejected()
        p.unlink()
        os.link(target, p)
        self.rejected()
        p.unlink()
        p.write_bytes(original)
        p.chmod(0o666)
        self.rejected()
        self.assertFalse(self.output.exists())

    def test_symlinked_bundle_parent_denied(self):
        link = self.root / 'bundle-link'
        link.symlink_to(self.bundle, target_is_directory=True)
        with self.assertRaises(ValueError):
            m.prepare(link)
        self.assertFalse(self.output.exists())

    def test_unknown_corrupt_unsafe_output_retained(self):
        m.prepare(self.bundle)
        unknown = self.output / 'unknown'
        unknown.write_bytes(b'retain')
        self.rejected()
        self.assertEqual(unknown.read_bytes(), b'retain')
        unknown.rename(self.root / 'retained-unknown')
        p = self.output / 'chat.html'
        p.write_bytes(b'X' * p.stat().st_size)
        self.rejected()
        self.assertTrue(p.read_bytes().startswith(b'X'))
        self.output.chmod(0o755)
        self.rejected()
        self.assertTrue(p.exists())

    def test_interrupted_output_is_not_repaired_or_deleted(self):
        real = m.os.fsync
        calls = 0
        def broken(fd):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('synthetic fsync interruption')
            return real(fd)
        with patch.object(m.os, 'fsync', broken):
            self.rejected()
        before = {p.name: p.read_bytes() for p in self.output.iterdir()}
        self.assertGreater(len(before), 0)
        self.assertLess(len(before), 9)
        self.rejected()
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.output.iterdir()})

    def test_concurrent_lock_denies_without_output(self):
        lock = self.output.parent / '.mls-build.lock'
        fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.rejected()
            self.assertFalse(self.output.exists())
        finally:
            os.close(fd)
        m.prepare(self.bundle)

    def test_unsafe_lock_and_duplicate_manifest_denied(self):
        lock = self.output.parent / '.mls-build.lock'
        lock.symlink_to(self.manifest)
        self.rejected()
        lock.unlink()
        self.manifest.write_text(self.manifest.read_text().replace('"version": 1', '"version": 1, "version": 1'))
        self.rejected()
        self.assertFalse(self.output.exists())

    def test_symlinked_lock_parent_rejects_before_creating_files(self):
        original = self.output.parent
        retained = self.root / 'retained-chat'
        original.rename(retained)
        original.symlink_to(retained, target_is_directory=True)
        before = set(retained.iterdir())
        self.rejected()
        self.assertEqual(before, set(retained.iterdir()))
        self.assertFalse((retained / '.mls-build.lock').exists())
