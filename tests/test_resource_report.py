import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    'resource_report', ROOT / 'scripts' / 'resource_report.py')
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)

SHA_A = 'a' * 64
SHA_B = 'b' * 64


class CensusTests(unittest.TestCase):
    def write_manifests(self, root):
        (root / 'server').mkdir()
        (root / 'server' / 'go.mod').write_text(
            'module example/server\n\ngo 1.27.1\n\nrequire (\n'
            '\texample.com/direct v1.2.3\n\tother.example/direct v0.1.0\n)\n')
        (root / 'server' / 'go.sum').write_text(
            'example.com/direct v1.2.3 h1:x=\n'
            'example.com/direct v1.2.3/go.mod h1:y=\n'
            'example.com/indirect v9.9.9 h1:z=\n')
        record = root / rr.WASM_RECORD
        record.parent.mkdir(parents=True)
        record.write_text(json.dumps({
            'schema': 'fixture.v1', 'external_direct': 8, 'external_transitive': 151,
            'full_lock_external_packages': 197, 'scope': 'fixture scope'}))
        (root / 'requirements-matrix.txt').write_text(
            'matrix-nio[e2e]==0.25.2\n# comment\n\n')
        (root / 'requirements-native-test.txt').write_text(
            '# Browser verification only; not a messenger runtime dependency.\n'
            'playwright==1.62.0\n')
        # Live homeserver manifest: the pinned Tuwunel single binary replaced the
        # archived compose image census (archive/synapse-stack/).
        pins = root / 'deploy' / 'tuwunel' / 'tuwunel.pins.json'
        pins.parent.mkdir(parents=True)
        pins.write_text(json.dumps({
            'version': 'v1.9.1',
            'release_url': 'https://github.com/matrix-construct/tuwunel/releases/tag/v1.9.1',
            'assets': {'deb': {'name': 'v1.9.1-fixture.deb', 'size': 40373354,
                               'sha256': SHA_A, 'status': 'verified'}},
            'binary': {'path_in_deb': 'usr/sbin/tuwunel', 'size': 107045776,
                       'sha256': SHA_B, 'static': True}}))

    def test_census_counts_direct_and_indirect_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_manifests(root)
            report = rr.census(root)
            self.assertEqual(report['schema'], 'family.resource.census.v1')
            self.assertEqual([d['module'] for d in report['go']['direct']],
                             ['example.com/direct', 'other.example/direct'])
            # go.sum pins both the binary and /go.mod hashes of one module;
            # the census counts distinct modules, not hash lines.
            self.assertEqual(report['go']['distinct_summed_modules'], 2)
            self.assertEqual(report['wasm']['status'], 'archived')
            self.assertEqual(report['wasm']['external_direct'], 8)
            self.assertEqual(report['wasm']['external_transitive'], 151)
            self.assertEqual(
                [p['pin'] for p in report['python']],
                ['matrix-nio[e2e]==0.25.2', 'playwright==1.62.0'])
            self.assertEqual(report['tuwunel']['version'], 'v1.9.1')
            self.assertEqual(report['tuwunel']['asset']['name'], 'v1.9.1-fixture.deb')
            self.assertEqual(report['tuwunel']['asset']['sha256'], SHA_A)
            self.assertEqual(report['tuwunel']['binary']['path_in_deb'], 'usr/sbin/tuwunel')
            self.assertEqual(report['tuwunel']['binary']['sha256'], SHA_B)
            self.assertTrue(report['tuwunel']['binary']['static'])
            self.assertEqual(report['tuwunel']['record'], 'deploy/tuwunel/tuwunel.pins.json')

    def test_archived_wasm_record_is_skipped_with_a_note_not_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_manifests(root)
            (root / rr.WASM_RECORD).unlink()
            report = rr.census(root)
            self.assertEqual(report['wasm']['status'], 'skipped')
            self.assertIn('archived', report['wasm']['note'])
            self.assertEqual(report['wasm']['record'], 'archive/experiments/openmls-browser/dependencies.json')
            self.assertNotIn('external_direct', report['wasm'])
            # The live manifests are still counted in full.
            self.assertEqual(report['go']['distinct_summed_modules'], 2)

    def test_census_requires_every_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'server').mkdir()
            # No fallback: a missing manifest must fail loudly, never emit a
            # partial census that could be mistaken for the full record.
            with self.assertRaises(FileNotFoundError):
                rr.census(root)

    def test_census_requires_the_homeserver_pins(self):
        # Unlike the archived WASM record, the Tuwunel pin is a live manifest:
        # without it the census fails instead of reporting an unpinned homeserver.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_manifests(root)
            (root / 'deploy' / 'tuwunel' / 'tuwunel.pins.json').unlink()
            with self.assertRaises(FileNotFoundError):
                rr.census(root)


class WatchTests(unittest.TestCase):
    def test_watch_records_only_the_command_subtree(self):
        # The grandchild `sleep` process belongs to the measured subtree; the
        # unittest runner itself is the parent and must never be counted.
        command = [sys.executable, '-c',
                   "import subprocess; subprocess.run(['sleep', '0.5'])"]
        report = rr.watch(command, poll_seconds=0.02)
        self.assertEqual(report['schema'], 'family.resource.watch.v1')
        self.assertEqual(report['exit_code'], 0)
        self.assertGreaterEqual(report['max_descendant_process_count'], 1)
        self.assertGreaterEqual(report['distinct_descendant_pids'], 1)
        self.assertIn('sleep', report['descendant_comm_names'])
        self.assertGreater(report['peak_descendant_rss_bytes'], 0)
        self.assertGreater(report['wall_seconds'], 0)

    def test_watch_reports_failing_command_exit_code(self):
        report = rr.watch([sys.executable, '-c', 'raise SystemExit(7)'],
                          grace_seconds=0.0)
        self.assertEqual(report['exit_code'], 7)
        self.assertEqual(report['max_descendant_process_count'], 0)


if __name__ == '__main__':
    unittest.main()
