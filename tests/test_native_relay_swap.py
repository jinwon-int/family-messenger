"""deploy/native-relay/native-relay-swap — 릴레이 바이너리 교체 (2026-11-03 서서 #659 배포 재발 방지).

그날의 임시 swap 스크립트는 (1) 없는 경로 /healthz(404)로 정상 릴레이를 실패로 보고,
(2) 실행 중인 바이너리에 cp 로 롤백하려다 ETXTBSY 로 실패한 채 재시작해, 릴레이를 30 s 안에
두 번 재시작했다(순욱 봇이 진행 중 턴 #7577 을 잃음). 여기서는 실행 중인 파일을 교체 대상으로 두고
health 는 /v2/health 의 200 + "ok":true 만 인정하는지, 롤백도 rename 으로 성공하는지 본다.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / 'deploy' / 'native-relay' / 'native-relay-swap'
SLEEP = shutil.which('sleep')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


@unittest.skipUnless(SLEEP and shutil.which('bash'), 'needs bash and an ELF sleep')
class NativeRelaySwapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='relay-swap-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        base = Path(SLEEP).read_bytes()
        (self.tmp / 'bin').mkdir()
        self.bin = self.tmp / 'bin' / 'native-mls-relay'
        # An executable that really runs (ELF sleep) with a marker appended: the fake
        # curl reads the marker of whatever is installed at RELAY_BIN right now.
        self.bin.write_bytes(base + b'\nMARK-OLD-GOOD\n')
        self.bin.chmod(0o755)
        self.good = self.tmp / 'stage-good'
        self.good.write_bytes(base + b'\nMARK-NEW-GOOD\n')
        self.bad = self.tmp / 'stage-bad'
        self.bad.write_bytes(base + b'\nMARK-NEW-BAD\n')
        self.calls = self.tmp / 'systemctl.log'
        fake_systemctl = self.tmp / 'systemctl'
        fake_systemctl.write_text(f'#!/usr/bin/env bash\necho "$*" >> {self.calls}\n')
        fake_systemctl.chmod(0o755)
        self.urls = self.tmp / 'curl.log'
        fake_curl = self.tmp / 'curl'
        fake_curl.write_text(
            '#!/usr/bin/env bash\n'
            f'echo "${{@: -1}}" >> {self.urls}\n'
            f'case "${{@: -1}}" in */v2/health) ;; *) printf "404 page not found\\n404"; exit 0;; esac\n'
            f'if grep -q GOOD {self.bin}; then printf \'{{"ok":true}}\\n\\n200\'; else printf "boom\\n503"; fi\n'
        )
        fake_curl.chmod(0o755)
        # The relay "runs" from RELAY_BIN: writing into this file is ETXTBSY.
        self.running = subprocess.Popen([str(self.bin), '60'])
        self.addCleanup(self.running.wait)
        self.addCleanup(self.running.kill)

    def swap(self, staged, digest=None, health_url='http://127.0.0.1:18921/v2/health'):
        env = dict(os.environ, RELAY_BIN=str(self.bin), RELAY_UNIT='native-relay.service',
                   RELAY_HEALTH_URL=health_url, HEALTH_TIMEOUT='1',
                   NATIVE_RELAY_SWAP_SYSTEMCTL=str(self.tmp / 'systemctl'),
                   NATIVE_RELAY_SWAP_CURL=str(self.tmp / 'curl'))
        return subprocess.run(['bash', str(SCRIPT), str(staged), digest or sha(staged)],
                              env=env, capture_output=True, text=True, timeout=60)

    def restarts(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_swaps_a_running_binary_by_rename_and_probes_v2_health(self):
        old = sha(self.bin)
        proc = self.swap(self.good)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(sha(self.bin), sha(self.good), 'new binary in place despite the running process')
        self.assertEqual(sha(self.bin.with_name(f'native-mls-relay.old-{old[:16]}')), old, 'backup kept')
        self.assertEqual(self.restarts(), ['restart native-relay.service'], 'exactly one restart')
        self.assertTrue(all(u.endswith('/v2/health') for u in self.urls.read_text().split()))
        self.assertEqual(sorted(p.name for p in self.bin.parent.iterdir() if '.swap.' in p.name), [], 'no temp left')

    def test_unhealthy_binary_rolls_back_by_rename(self):
        old = sha(self.bin)
        proc = self.swap(self.bad)
        self.assertEqual(proc.returncode, 6, proc.stdout + proc.stderr)
        self.assertEqual(sha(self.bin), old, 'old binary restored even though it is running')
        self.assertNotIn('Text file busy', proc.stdout + proc.stderr)
        self.assertEqual(self.restarts(), ['restart native-relay.service'] * 2)

    def test_healthz_is_not_a_health_check(self):
        # The 11-03 probe path: a 404 there must never count as healthy.
        proc = self.swap(self.good, health_url='http://127.0.0.1:18921/healthz')
        self.assertEqual(proc.returncode, 7, proc.stdout + proc.stderr)

    def test_refuses_a_hash_mismatch_without_touching_anything(self):
        old = sha(self.bin)
        proc = self.swap(self.good, digest='0' * 64)
        self.assertEqual(proc.returncode, 65, proc.stdout + proc.stderr)
        self.assertEqual(sha(self.bin), old)
        self.assertEqual(self.restarts(), [])

    def test_same_binary_is_a_no_op(self):
        shutil.copy(self.bin, self.tmp / 'stage-same')
        proc = self.swap(self.tmp / 'stage-same')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn('unchanged', proc.stdout)
        self.assertEqual(self.restarts(), [])


if __name__ == '__main__':
    unittest.main()
