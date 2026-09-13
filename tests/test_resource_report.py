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
        (root / 'compose.yaml').write_text(
            'services:\n  db:\n    image: example/db:1@sha256:aa\n'
            '  app:\n    image: ghcr.io/example/app:v2@sha256:bb\n')

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
            self.assertEqual(
                report['images'],
                ['example/db:1@sha256:aa', 'ghcr.io/example/app:v2@sha256:bb'])

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


class DockerStatsParsingTests(unittest.TestCase):
    def test_stats_line_is_reduced_to_safe_numbers(self):
        line = ('{"BlockIO":"1.2MB / 0B","CPUPerc":"0.15%","Container":"demo",'
                '"ID":"abcdef123456","MemPerc":"1.20%","MemUsage":"12.5MiB / 512MiB",'
                '"Name":"family-demo-synapse-1","NetIO":"0B / 0B",'
                '"PIDs":"7"}')
        parsed = rr.parse_docker_stats_line(line)
        self.assertEqual(parsed['name'], 'family-demo-synapse-1')
        self.assertEqual(parsed['memory_used_bytes'], int(12.5 * 1024 * 1024))
        self.assertEqual(parsed['memory_limit_bytes'], 512 * 1024 * 1024)
        self.assertEqual(parsed['cpu_percent'], 0.15)

    def test_unreadable_memory_figure_is_refused(self):
        with self.assertRaises(ValueError):
            rr.parse_memory('about a bucket')


if __name__ == '__main__':
    unittest.main()
