"""deploy/native-relay/native-relay-repoint — 봇 릴레이 재지정 훅 (#440 ⑤ · #699 P0-d).

v1 은 env 파일 전체를 NATIVE_RELAY_URL 한 줄로 덮어썼다. 릴레이 호스트(서서·순욱)에서는
/etc/native-relay/relay.env 가 릴레이 자신의 Access 설정(ISSUER·AUD·JWKS)이라, 훅을 그대로 쓰면
다음 릴레이 재시작이 깨진다. 또 native-relay-bot 하나만 알아서 서서 알림 봇·곽가 번개장터 봇·
Termux(runit) 봇은 재지정할 수 없었다. 여기서는 (1) 다른 줄·권한 유지, (2) 여러 유닛 차례 재시작,
(3) runit + svlogd 준비 확인, (4) 미기동 릴레이·relay_unreachable 거부, (5) 설정 없을 때 v1 동작을 본다.
"""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / 'deploy' / 'native-relay' / 'native-relay-repoint'
URL = 'http://100.104.18.61:18921'
OLD = 'http://100.88.73.41:18921'


def write_exec(path, body):
    path.write_text('#!/usr/bin/env bash\n' + body)
    path.chmod(0o755)


@unittest.skipUnless(shutil.which('bash'), 'needs bash')
class NativeRelayRepointTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='relay-repoint-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.state = self.tmp / 'state'
        self.state.mkdir()
        self.calls = self.tmp / 'calls.log'
        self.env_file = self.tmp / 'relay.env'
        # systemd 대역: 유닛별 PID 파일, restart 는 PID +1. journal 은 FAKE_EVENT 를 낸다.
        write_exec(self.tmp / 'systemctl', f'''
S={self.state}; echo "systemctl $*" >> {self.calls}
case "$1" in
  show) u="${{@: -1}}"; cat "$S/$u.pid" 2>/dev/null || echo 100;;
  restart) p=$(cat "$S/$2.pid" 2>/dev/null || echo 100); echo $((p+1)) > "$S/$2.pid";;
  is-active) echo active;;
esac
''')
        write_exec(self.tmp / 'journalctl', 'echo "{\\"event\\":\\"${FAKE_EVENT:-steward_ready}\\"}"\n')
        write_exec(self.tmp / 'curl', f'echo "curl ${{@: -1}}" >> {self.calls}; printf "${{FAKE_HEALTH:-200}}"\n')
        # runit 대역: sv restart 는 PID +1 하고 로그 디렉터리 current 에 FAKE_EVENT 한 줄을 붙인다.
        self.svdir = self.tmp / 'service'
        self.svdir.mkdir()
        write_exec(self.tmp / 'sv', f'''
S={self.state}; echo "sv $*" >> {self.calls}; n=$(basename "$2")
case "$1" in
  status) echo "run: $2: (pid $(cat "$S/$n.pid" 2>/dev/null || echo 200)) 5s";;
  restart) p=$(cat "$S/$n.pid" 2>/dev/null || echo 200); echo $((p+1)) > "$S/$n.pid"
           echo "@4000 {{\\"event\\":\\"${{FAKE_EVENT:-steward_ready}}\\"}}" >> "$(cat "$S/$n.logdir")/current";;
esac
''')

    def run_hook(self, *args, conf=None, **env_extra):
        conf_path = self.tmp / 'repoint.conf'
        if conf is not None:
            conf_path.write_text(conf)
        env = dict(os.environ, NATIVE_RELAY_REPOINT_CONF=str(conf_path),
                   NATIVE_RELAY_REPOINT_SYSTEMCTL=str(self.tmp / 'systemctl'),
                   NATIVE_RELAY_REPOINT_JOURNALCTL=str(self.tmp / 'journalctl'),
                   NATIVE_RELAY_REPOINT_SV=str(self.tmp / 'sv'),
                   NATIVE_RELAY_REPOINT_CURL=str(self.tmp / 'curl'),
                   READY_TIMEOUT='3', **env_extra)
        return subprocess.run(['bash', str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=60)

    def calls_list(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def systemd_conf(self, units):
        return f'REPOINT_ENV_FILE={self.env_file}\nREPOINT_UNITS="{units}"\n'

    def test_relay_host_env_keeps_other_lines_and_mode(self):
        self.env_file.write_text('NATIVE_RELAY_ISSUER=https://issuer.example\nNATIVE_RELAY_AUD=aud\n'
                                 f'NATIVE_RELAY_URL={OLD}\nNATIVE_RELAY_JWKS=https://issuer.example/certs\n')
        self.env_file.chmod(0o600)
        proc = self.run_hook(URL, conf=self.systemd_conf('native-relay-bot.service'))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        lines = self.env_file.read_text().splitlines()
        for keep in ('NATIVE_RELAY_ISSUER=https://issuer.example', 'NATIVE_RELAY_AUD=aud',
                     'NATIVE_RELAY_JWKS=https://issuer.example/certs'):
            self.assertIn(keep, lines, 'relay Access settings must survive the repoint')
        self.assertEqual([ln for ln in lines if ln.startswith('NATIVE_RELAY_URL=')], [f'NATIVE_RELAY_URL={URL}'])
        self.assertEqual(stat.S_IMODE(self.env_file.stat().st_mode), 0o600, 'mode preserved')
        self.assertTrue(list(self.tmp.glob('relay.env.bak-*')), 'backup written')
        self.assertEqual(list(self.tmp.glob('relay.env.repoint.*')), [], 'no temp left')
        self.assertTrue(proc.stdout.strip().startswith('repointed:'), 'stdout stays one v1-style line')

    def test_repeat_repoint_does_not_pile_up_comment_lines(self):
        self.env_file.write_text(f'NATIVE_RELAY_URL={OLD}\n')
        conf = self.systemd_conf('native-relay-bot.service')
        self.assertEqual(self.run_hook(URL, conf=conf).returncode, 0)
        self.assertEqual(self.run_hook(OLD, conf=conf).returncode, 0)
        text = self.env_file.read_text()
        self.assertEqual(text.count('# written by native-relay-repoint'), 1)
        self.assertEqual(text.count('NATIVE_RELAY_URL='), 1)

    def test_multiple_units_restart_in_order_and_all_ready(self):
        self.env_file.write_text(f'NATIVE_RELAY_URL={OLD}\n')
        proc = self.run_hook(URL, conf=self.systemd_conf('native-relay-bot.service hande-card-bot.service '
                                                         'hande-fleet-alerts-bot.service'))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        restarts = [c for c in self.calls_list() if c.startswith('systemctl restart')]
        self.assertEqual(restarts, ['systemctl restart native-relay-bot.service',
                                    'systemctl restart hande-card-bot.service',
                                    'systemctl restart hande-fleet-alerts-bot.service'])
        self.assertEqual(proc.stderr.count('ready: '), 3)

    def test_relay_unreachable_fails_after_writing(self):
        self.env_file.write_text(f'NATIVE_RELAY_URL={OLD}\n')
        proc = self.run_hook(URL, conf=self.systemd_conf('native-relay-bot.service'), FAKE_EVENT='relay_unreachable')
        self.assertEqual(proc.returncode, 1)
        self.assertIn('relay_unreachable', proc.stderr)

    def test_unhealthy_target_is_refused_without_touching_env(self):
        self.env_file.write_text(f'NATIVE_RELAY_URL={OLD}\n')
        before = self.env_file.read_text()
        proc = self.run_hook(URL, conf=self.systemd_conf('native-relay-bot.service'), FAKE_HEALTH='502')
        self.assertEqual(proc.returncode, 69)
        self.assertEqual(self.env_file.read_text(), before)
        self.assertFalse([c for c in self.calls_list() if 'restart' in c])

    def test_same_url_is_a_noop(self):
        self.env_file.write_text(f'NATIVE_RELAY_URL={URL}\n')
        proc = self.run_hook(URL, conf=self.systemd_conf('native-relay-bot.service'))
        self.assertEqual(proc.returncode, 0)
        self.assertIn('unchanged', proc.stdout)
        self.assertEqual(self.calls_list(), [])

    def test_runit_services_ready_from_svlogd(self):
        envf = self.tmp / 'bot-relay.env'
        envf.write_text(f'NATIVE_RELAY_URL={OLD}\n')
        entries = []
        for name in ('native-relay-bot', 'hande-insta-bot'):
            logdir = self.tmp / f'logs-{name}'
            logdir.mkdir()
            (logdir / 'current').write_text('@4000 {"event":"steward_ready"}\n')  # old line must not count
            (self.state / f'{name}.logdir').write_text(str(logdir))
            entries.append(f'{name}:{logdir}')
        conf = (f'REPOINT_ENV_FILE={envf}\nREPOINT_SUPERVISOR=runit\nREPOINT_SVDIR={self.svdir}\n'
                f'REPOINT_UNITS="{" ".join(entries)}"\n')
        proc = self.run_hook(URL, conf=conf)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual([c for c in self.calls_list() if c.startswith('sv restart')],
                         [f'sv restart {self.svdir}/native-relay-bot', f'sv restart {self.svdir}/hande-insta-bot'])
        self.assertIn(f'NATIVE_RELAY_URL={URL}', envf.read_text())

    def test_runit_old_ready_line_alone_is_not_enough(self):
        envf = self.tmp / 'bot-relay.env'
        envf.write_text(f'NATIVE_RELAY_URL={OLD}\n')
        logdir = self.tmp / 'logs'
        logdir.mkdir()
        (logdir / 'current').write_text('@4000 {"event":"steward_ready"}\n')
        (self.state / 'native-relay-bot.logdir').write_text(str(logdir))
        conf = (f'REPOINT_ENV_FILE={envf}\nREPOINT_SUPERVISOR=runit\nREPOINT_SVDIR={self.svdir}\n'
                f'REPOINT_UNITS="native-relay-bot:{logdir}"\n')
        proc = self.run_hook(URL, conf=conf, FAKE_EVENT='booting')
        self.assertEqual(proc.returncode, 1, 'a steward_ready line from before the restart must not pass')

    def test_without_conf_defaults_to_v1_unit_and_path(self):
        proc = self.run_hook('--check')  # no conf file written
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('env=/etc/native-relay/relay.env', proc.stdout)
        self.assertIn('unit=native-relay-bot.service', proc.stdout)

    def test_termux_prefix_conf_is_the_default_path(self):
        prefix = self.tmp / 'usr'
        (prefix / 'etc' / 'native-relay').mkdir(parents=True)
        envf = self.tmp / 'termux-relay.env'
        (prefix / 'etc' / 'native-relay' / 'repoint.conf').write_text(
            f'REPOINT_ENV_FILE={envf}\nREPOINT_SUPERVISOR=runit\nREPOINT_UNITS="native-relay-bot:/x"\n')
        env = dict(os.environ, PREFIX=str(prefix), NATIVE_RELAY_REPOINT_SV=str(self.tmp / 'sv'))
        env.pop('NATIVE_RELAY_REPOINT_CONF', None)
        proc = subprocess.run(['bash', str(SCRIPT), '--check'], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(f'env={envf}', proc.stdout)
        self.assertIn('supervisor=runit', proc.stdout)

    def test_rejects_non_tailnet_url(self):
        proc = self.run_hook('https://relay.example.com', conf=self.systemd_conf('native-relay-bot.service'))
        self.assertEqual(proc.returncode, 65)


if __name__ == '__main__':
    unittest.main()
