"""archive/native-mls/bot/deploy/native-mls-bot-swap · native-mls-bot-fleet — 한데 봇 바이너리 교체 정본.

#676·#703·#731+#733 플릿 롤아웃의 임시 스크립트를 레포로 옮긴 것. 여기서는 그 롤아웃들이 지켜 온 규칙을 고정한다:
실행 중인 파일은 rename 으로만 바꾸고(ETXTBSY), 유휴가 아니면 아무것도 바꾸지 않으며, 새 프로세스가 정말 새 바이너리를
실행하는지(/proc/<pid>/exe)와 방이 joined·halted=false 인지 보고, 아니면 되돌린다. 같은 파일을 쓰는 다른 봇
유닛(gwakga hande-bunjang-bot)과 사용자 유닛 브리지(gongmyoung)도 다룬다.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest

DEPLOY = Path(__file__).parents[1] / 'archive' / 'native-mls' / 'bot' / 'deploy'
SWAP = DEPLOY / 'native-mls-bot-swap'
FLEET = DEPLOY / 'native-mls-bot-fleet'
# The fake bot is a copy of bash (+ a marker), not of `sleep`: ubuntu-26.04's coreutils is the uutils
# multicall binary, which picks the tool from its own file name (/proc/self/exe, not argv[0]), so a
# `sleep` copy named native-mls-bot exits at once. bash does not care what it is called.
BASH = shutil.which('bash')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# systemctl double: per-unit pid files; `restart` starts the *current* BOT_BIN (an ELF `bash` with a
# marker appended) so /proc/<pid>/exe is the file the swap placed. `--user -M <u>@` is logged and stripped.
FAKE_SYSTEMCTL = r'''#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/calls"
if [ "$1" = --user ]; then shift 3; fi
case "$1" in
  show)
    if [ "$3" = Environment ]; then exit 0; fi
    cat "$FAKE_DIR/pid.$5" 2>/dev/null || echo 0 ;;
  restart)
    old=$(cat "$FAKE_DIR/pid.$2" 2>/dev/null); [ -n "$old" ] && kill "$old" 2>/dev/null
    # The bash copy waits in the `read` builtin (no child): $! is the pid whose exe is the bot file.
    setsid "$FAKE_BIN" -c 'read -r -t 60 _ <> "$FAKE_DIR/fifo"' >/dev/null 2>&1 < /dev/null &
    echo $! > "$FAKE_DIR/pid.$2"; echo $! >> "$FAKE_DIR/spawned" ;;
  is-active) echo active ;;
esac
'''
# journalctl double: a healthy room unless the binary now in place carries the BAD marker — a string
# no real binary holds (uutils' coreutils, for one, carries errno names such as EBADF).
FAKE_JOURNALCTL = r'''#!/usr/bin/env bash
if grep -q SWAPTEST-BAD-7c1e "$FAKE_BIN"; then echo '{"event":"steward_ready","rooms":[{"joined":true,"halted":true}]}'
else echo '{"event":"steward_ready","rooms":[{"halted":false,"joined":true,"mode":"agent"}]}'; fi
'''


@unittest.skipUnless(BASH and shutil.which('setsid') and Path('/proc/self/exe').exists(),
                     'needs bash, setsid and /proc')
class NativeMlsBotSwapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='bot-swap-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.addCleanup(self.kill_spawned)
        base = Path(BASH).read_bytes()
        self.assertNotIn(b'SWAPTEST-BAD-7c1e', base, 'the BAD marker must not occur in the bash binary')
        os.mkfifo(self.tmp / 'fifo')
        (self.tmp / 'bin').mkdir()
        self.bin = self.tmp / 'bin' / 'native-mls-bot'
        self.bin.write_bytes(base + b'\nOLD-GOOD\n')
        self.bin.chmod(0o755)
        self.good = self.tmp / 'stage-good'
        self.good.write_bytes(base + b'\nNEW-GOOD watchdog_max\n')
        self.bad = self.tmp / 'stage-bad'
        self.bad.write_bytes(base + b'\nNEW SWAPTEST-BAD-7c1e watchdog_max\n')
        for name, body in (('systemctl', FAKE_SYSTEMCTL), ('journalctl', FAKE_JOURNALCTL)):
            (self.tmp / name).write_text(body)
            (self.tmp / name).chmod(0o755)
        self.health = self.tmp / 'health.json'
        self.set_occupancy('idle')
        (self.tmp / 'pid.ccc-hande-bridge').write_text('424242\n')
        # The bot "runs" from BOT_BIN before the swap: writing into it would be ETXTBSY.
        self.start_unit('native-relay-bot')

    def kill_spawned(self):
        spawned = self.tmp / 'spawned'
        for pid in (spawned.read_text().split() if spawned.exists() else []):
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass

    def start_unit(self, unit):
        subprocess.run([str(self.tmp / 'systemctl'), 'restart', unit], env=self.env(), check=True)
        (self.tmp / 'calls').unlink()

    def set_occupancy(self, state):
        self.health.write_text(json.dumps({'workload': {'turn_occupancy': {'state': state}}}))

    def env(self, **extra):
        env = dict(os.environ, FAKE_DIR=str(self.tmp), FAKE_BIN=str(self.bin), BOT_BIN=str(self.bin),
                   BOT_HEALTH_FILE=str(self.health), IDLE_INTERVAL='0', VERIFY_INTERVAL='0.2', VERIFY_TRIES='10',
                   RESTART_SETTLE='0.2',
                   NATIVE_MLS_BOT_SWAP_SYSTEMCTL=str(self.tmp / 'systemctl'),
                   NATIVE_MLS_BOT_SWAP_JOURNALCTL=str(self.tmp / 'journalctl'))
        env.update(extra)
        return env

    def swap(self, staged, digest=None, marker='watchdog_max', **extra):
        args = ['bash', str(SWAP), str(staged), digest or sha(staged)] + ([marker] if marker else [])
        return subprocess.run(args, env=self.env(**extra), capture_output=True, text=True, timeout=60)

    def calls(self):
        path = self.tmp / 'calls'
        return path.read_text().splitlines() if path.exists() else []

    def restarts(self):
        return [c for c in self.calls() if c.startswith('restart')]

    def last_result(self, proc):
        return [line for line in proc.stdout.splitlines() if line.startswith('RESULT=')][-1].split()[0]

    def test_swaps_the_running_binary_by_rename_and_checks_the_new_process(self):
        old = sha(self.bin)
        proc = self.swap(self.good)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.last_result(proc), 'RESULT=PASS')
        self.assertEqual(sha(self.bin), sha(self.good))
        self.assertEqual(sha(self.bin.with_name(f'native-mls-bot.old-{old[:16]}')), old, 'backup kept')
        self.assertEqual(self.restarts(), ['restart native-relay-bot'], 'only the bot restarts, once')
        pid = (self.tmp / 'pid.native-relay-bot').read_text().strip()
        self.assertEqual(sha(f'/proc/{pid}/exe'), sha(self.good), 'the new process runs the new file')
        self.assertNotIn('WARN', proc.stdout)
        self.assertNotIn('Text file busy', proc.stdout + proc.stderr)
        self.assertEqual([p.name for p in self.bin.parent.iterdir() if '.swap.' in p.name], [], 'no temp left')

    def test_unhealthy_room_rolls_back_by_rename(self):
        old = sha(self.bin)
        proc = self.swap(self.bad)
        self.assertEqual(proc.returncode, 5, proc.stdout + proc.stderr)
        self.assertEqual(self.last_result(proc), 'RESULT=ROLLED_BACK')
        self.assertEqual(sha(self.bin), old, 'old binary restored even though it was running')
        self.assertEqual(self.restarts(), ['restart native-relay-bot'] * 2)

    def test_busy_bridge_changes_nothing(self):
        self.set_occupancy('occupied')
        old = sha(self.bin)
        proc = self.swap(self.good, IDLE_TRIES='3')
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        self.assertEqual(self.last_result(proc), 'RESULT=ABORT_BUSY')
        self.assertEqual(sha(self.bin), old)
        self.assertEqual(self.restarts(), [])

    def test_refusals_touch_nothing(self):
        old = sha(self.bin)
        for args, code, result in (
            ({'digest': '0' * 64}, 65, 'RESULT=ABORT_SHA'),
            ({'marker': 'not-in-there'}, 8, 'RESULT=ABORT_NO_MARKER'),
        ):
            proc = self.swap(self.good, **args)
            self.assertEqual(proc.returncode, code, proc.stdout + proc.stderr)
            self.assertEqual(self.last_result(proc), result)
        self.health.unlink()
        proc = self.swap(self.good)
        self.assertEqual((proc.returncode, self.last_result(proc)), (6, 'RESULT=ABORT_NOHEALTH'), proc.stdout)
        self.assertEqual(sha(self.bin), old)
        self.assertEqual(self.restarts(), [])

    def test_same_binary_is_a_no_op(self):
        shutil.copy(self.bin, self.tmp / 'stage-same')
        proc = self.swap(self.tmp / 'stage-same', marker='')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.last_result(proc), 'RESULT=UNCHANGED')
        self.assertEqual(self.restarts(), [])

    def test_extra_units_on_the_same_file_restart_and_verify_too(self):
        # gwakga: hande-bunjang-bot runs the same file as the agent bot.
        self.start_unit('hande-bunjang-bot')
        proc = self.swap(self.good, BOT_EXTRA_UNITS='hande-bunjang-bot')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.restarts(), ['restart native-relay-bot', 'restart hande-bunjang-bot'])
        pid = (self.tmp / 'pid.hande-bunjang-bot').read_text().strip()
        self.assertEqual(sha(f'/proc/{pid}/exe'), sha(self.good))

    def test_a_user_unit_bridge_is_read_with_its_user(self):
        # gongmyoung: the bridge is that user's systemd --user unit.
        proc = self.swap(self.good, BRIDGE_USER='gongmyoung')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        bridge = [c for c in self.calls() if 'ccc-hande-bridge' in c]
        self.assertTrue(bridge and all(c.startswith('--user -M gongmyoung@ ') for c in bridge), bridge)


@unittest.skipUnless(shutil.which('bash'), 'needs bash')
class NativeMlsBotFleetDryRunTest(unittest.TestCase):
    def setUp(self):
        self.stage = Path(tempfile.mkdtemp(prefix='bot-fleet-'))
        self.addCleanup(shutil.rmtree, self.stage, True)
        for name in ('native-mls-bot-x86_64-gnu-abc', 'native-mls-bot-aarch64-musl-abc'):
            (self.stage / name).write_bytes(name.encode())
        (self.stage / 'SHA256SUMS').write_text(
            ''.join(f'{sha(self.stage / n)}  {n}\n' for n in sorted(p.name for p in self.stage.iterdir())))

    def fleet(self, order, *extra):
        return subprocess.run(['bash', str(FLEET), '--dry-run', str(self.stage), 'watchdog_max', *extra],
                              env=dict(os.environ, ORDER=order), capture_output=True, text=True, timeout=30)

    def test_order_options_become_the_swap_environment(self):
        proc = self.fleet('nosuk gwakga:extra=hande-bunjang-bot+other gongmyoung:bridge_user=gongmyoung daegyo:runit')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        plans = [line for line in proc.stdout.splitlines() if ' plan ' in line]
        x86 = f"bin=native-mls-bot-x86_64-gnu-abc sha={sha(self.stage / 'native-mls-bot-x86_64-gnu-abc')[:16]}"
        arm = f"bin=native-mls-bot-aarch64-musl-abc sha={sha(self.stage / 'native-mls-bot-aarch64-musl-abc')[:16]}"
        tail = ' marker=watchdog_max'
        self.assertEqual(plans, [
            f'nosuk plan mode=systemd {x86} env=[BOT_MODE=systemd]{tail}',
            f'gwakga plan mode=systemd {x86} env=[BOT_MODE=systemd BOT_EXTRA_UNITS=hande-bunjang-bot\\ other]{tail}',
            f'gongmyoung plan mode=systemd {x86} env=[BOT_MODE=systemd BRIDGE_USER=gongmyoung]{tail}',
            f'daegyo plan mode=runit {arm} env=[BOT_MODE=runit]{tail}',
        ])
        self.assertIn('FLEET_EXIT=PASS', proc.stdout)

    def test_unknown_option_halts_before_any_node(self):
        proc = self.fleet('nosuk:bogus dungae')
        self.assertIn('FLEET_EXIT=HALT', proc.stdout)
        self.assertNotIn('dungae plan', proc.stdout)

    def test_a_tampered_stage_is_refused(self):
        (self.stage / 'native-mls-bot-x86_64-gnu-abc').write_bytes(b'tampered')
        proc = self.fleet('nosuk')
        self.assertEqual(proc.returncode, 65, proc.stdout + proc.stderr)


if __name__ == '__main__':
    unittest.main()
