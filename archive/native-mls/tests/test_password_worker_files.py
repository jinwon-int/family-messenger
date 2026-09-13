"""A fixed asset replaced by a FIFO must deny, not block before fstat."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).with_name('password_worker_smoke.py')
SPEC = importlib.util.spec_from_file_location('password_fixture', SOURCE)
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class PasswordFixtureFileTests(unittest.TestCase):
    def test_regular_bytes_and_fifo_denial_without_blocking(self):
        # Own generated fixtures under the repository: /tmp itself intentionally
        # fails the helper's non-writable-ancestor rule before reaching open.
        with tempfile.TemporaryDirectory(prefix='.password-file-test-', dir=SOURCE.parents[1]) as directory:
            regular = Path(directory) / 'regular'
            regular.write_bytes(b'generated fixture')
            regular.chmod(0o600)
            self.assertEqual(fixture.safe_bytes(regular, 100), b'generated fixture')
            fifo = Path(directory) / 'fifo'
            os.mkfifo(fifo, 0o600)
            code = '''import importlib.util, pathlib, sys
s=importlib.util.spec_from_file_location("fixture", sys.argv[1])
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
try: m.safe_bytes(pathlib.Path(sys.argv[2]),100)
except (AssertionError,OSError): sys.exit(0)
sys.exit(3)
'''
            result = subprocess.run([sys.executable, '-c', code, str(SOURCE), str(fifo)],
                                    capture_output=True, timeout=2)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
