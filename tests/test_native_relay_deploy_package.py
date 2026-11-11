import re
import unittest
from pathlib import Path

PKG = Path(__file__).parents[1] / 'deploy' / 'native-relay'

# Every native-relay template that invokes a repo script, with the script it must point at.
EXPECTED = {
    'native-relay-snapshot.service': 'native_relay_snapshot.py',
    'native-relay-snapshot-prune.service': 'native_relay_snapshot.py',
    'native-relay-fence-watch.service': 'native_relay_fence.py',
    '30-fence.conf.example': 'native_relay_fence.py',
    'cutover.args.example': 'native_relay_cutover.py',
}


class NativeRelayCheckoutPathTests(unittest.TestCase):
    # #426 follow-up: relay hosts (seoseo, soonwook) check the repo out at /opt/family-messenger.
    # The homeserver path /opt/family-messenger-tuwunel does not exist there, so the templates as
    # written failed and each installed host carried a drop-in or a hand-edited unit instead.

    def test_templates_use_relay_host_checkout(self):
        for name, script in EXPECTED.items():
            with self.subTest(name=name):
                text = (PKG / name).read_text(encoding='utf-8')
                self.assertIn('/opt/family-messenger/scripts/%s ' % script, text)

    def test_no_homeserver_checkout_path_in_package(self):
        offenders = []
        for path in sorted(PKG.iterdir()):
            if not path.is_file() or path.name == 'README.md':  # README explains the old path
                continue
            text = path.read_text(encoding='utf-8')
            if 'family-messenger-tuwunel' in text:
                offenders.append(path.name)
        self.assertEqual(offenders, [])

    def test_every_script_reference_is_listed(self):
        # A new template that calls a repo script must be added to EXPECTED (and so to the path check).
        pattern = re.compile(r'/opt/[^\s/]+/scripts/\w+\.py')
        for path in sorted(PKG.iterdir()):
            if not path.is_file():
                continue
            if pattern.search(path.read_text(encoding='utf-8')):
                with self.subTest(name=path.name):
                    self.assertIn(path.name, EXPECTED)


class NativeRelaySnapshotRetentionTests(unittest.TestCase):
    # 2026-11-11: the receiving-host prune ran once a day (05:10), so 5-minute snapshots piled up for a whole
    # day between runs (gongmyoung inbox ~35-40G before dawn at 121 MB each). Seoseo had already moved to
    # hourly with a drop-in; the template is now the source of truth for that.

    @staticmethod
    def _timer_values(name, key):
        return [line.split('=', 1)[1].strip() for line in (PKG / name).read_text(encoding='utf-8').splitlines()
                if line.startswith(key + '=')]

    def test_prune_timer_runs_hourly(self):
        self.assertEqual(self._timer_values('native-relay-snapshot-prune.timer', 'OnCalendar'), ['hourly'])

    def test_prune_jitter_stays_well_inside_the_hour(self):
        delays = self._timer_values('native-relay-snapshot-prune.timer', 'RandomizedDelaySec')
        self.assertEqual(len(delays), 1)
        match = re.fullmatch(r'(\d+)(min|s)?', delays[0])
        self.assertIsNotNone(match, delays[0])
        seconds = int(match.group(1)) * (60 if match.group(2) == 'min' else 1)
        self.assertLessEqual(seconds, 15 * 60)

    def test_receiving_host_keeps_the_same_window_as_the_sender(self):
        env = dict(line.split('=', 1) for line in (PKG / 'snapshot.env.example').read_text(encoding='utf-8').splitlines()
                   if re.match(r'SNAPSHOT_KEEP_(HOURS|DAYS)=', line))
        service = (PKG / 'native-relay-snapshot-prune.service').read_text(encoding='utf-8')
        self.assertIn('--keep-hours %s ' % env['SNAPSHOT_KEEP_HOURS'].strip(), service)
        self.assertIn('--keep-days %s' % env['SNAPSHOT_KEEP_DAYS'].strip(), service)


if __name__ == '__main__':
    unittest.main()
