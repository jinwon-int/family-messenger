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


if __name__ == '__main__':
    unittest.main()
