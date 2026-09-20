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
    vault = False
    history = False
    aggregate = False
    aggregate_history = False
    successor = False
    custody = False
    confirmation = False
    welcome = False
    peer = False
    candidate = False
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = self.root / ('server/internal/chat/confirmationassets' if self.confirmation else 'server/internal/chat/welcomeassets' if self.welcome else 'server/internal/chat/custodyassets' if self.custody else 'server/internal/chat/peerassets' if self.peer else 'server/internal/chat/candidateassets' if self.candidate else 'server/internal/chat/successorassets' if self.successor else 'server/internal/chat/aggregatehistoryassets' if self.aggregate_history else 'server/internal/chat/aggregateassets' if self.aggregate else 'server/internal/chat/historyassets_v5' if self.history else 'server/internal/chat/vaultassets' if self.vault else 'server/internal/chat/mlsassets')
        self.output.parent.mkdir(parents=True)
        self.manifest = self.output.parent / ('confirmation_bundle.json' if self.confirmation else 'welcome_bundle.json' if self.welcome else 'custody_bundle.json' if self.custody else 'peer_bundle.json' if self.peer else 'candidate_bundle.json' if self.candidate else 'successor_bundle.json' if self.successor else 'aggregate_history_bundle.json' if self.aggregate_history else 'aggregate_bundle.json' if self.aggregate else 'history_bundle.json' if self.history else 'vault_bundle.json' if self.vault else 'mls_bundle.json')
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        self.sources = []
        pin = json.loads((m.ROOT/'server/internal/chat/confirmation_bundle.json').read_text()) if self.confirmation else json.loads((m.ROOT/'server/internal/chat/welcome_bundle.json').read_text()) if self.welcome else json.loads((m.ROOT/'server/internal/chat/custody_bundle.json').read_text()) if self.custody else json.loads((m.ROOT/'server/internal/chat/peer_bundle.json').read_text()) if self.peer else json.loads((m.ROOT/'server/internal/chat/candidate_bundle.json').read_text()) if self.candidate else json.loads((m.ROOT/'server/internal/chat/successor_bundle.json').read_text()) if self.successor else json.loads((m.ROOT/'server/internal/chat/aggregate_history_bundle.json').read_text()) if self.aggregate_history else json.loads((m.ROOT/'server/internal/chat/aggregate_bundle.json').read_text()) if self.aggregate else json.loads((m.ROOT/'server/internal/chat/history_bundle.json').read_text()) if self.history else json.loads((m.ROOT/'server/internal/chat/vault_bundle.json').read_text()) if self.vault else json.loads(json.dumps(PIN))
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
            m.prepare(self.bundle, vault=self.vault,history=self.history,aggregate=self.aggregate,aggregate_history=self.aggregate_history,successor=self.successor,candidate=self.candidate,peer=self.peer,custody=self.custody,welcome=self.welcome,confirmation=self.confirmation)

    def test_exact_create_reuse_and_check(self):
        with self.assertRaises(ValueError):
            m.prepare(self.bundle, True, vault=self.vault,history=self.history,aggregate=self.aggregate,aggregate_history=self.aggregate_history,successor=self.successor,candidate=self.candidate,peer=self.peer,custody=self.custody,welcome=self.welcome,confirmation=self.confirmation)
        m.prepare(self.bundle, vault=self.vault,history=self.history,aggregate=self.aggregate,aggregate_history=self.aggregate_history,successor=self.successor,candidate=self.candidate,peer=self.peer,custody=self.custody,welcome=self.welcome,confirmation=self.confirmation)
        before = {p.name: (p.stat().st_ino, p.read_bytes()) for p in self.output.iterdir()}
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in self.output.iterdir()))
        m.prepare(self.bundle, True, vault=self.vault,history=self.history,aggregate=self.aggregate,aggregate_history=self.aggregate_history,successor=self.successor,candidate=self.candidate,peer=self.peer,custody=self.custody,welcome=self.welcome,confirmation=self.confirmation)
        m.prepare(self.bundle, vault=self.vault,history=self.history,aggregate=self.aggregate,aggregate_history=self.aggregate_history,successor=self.successor,candidate=self.candidate,peer=self.peer,custody=self.custody,welcome=self.welcome,confirmation=self.confirmation)
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
            m.prepare(link, vault=self.vault,history=self.history,aggregate=self.aggregate,aggregate_history=self.aggregate_history,successor=self.successor,candidate=self.candidate,peer=self.peer,custody=self.custody,welcome=self.welcome,confirmation=self.confirmation)
        self.assertFalse(self.output.exists())

    def test_unknown_corrupt_unsafe_output_retained(self):
        m.prepare(self.bundle, vault=self.vault,history=self.history,aggregate=self.aggregate,aggregate_history=self.aggregate_history,successor=self.successor,candidate=self.candidate,peer=self.peer,custody=self.custody,welcome=self.welcome,confirmation=self.confirmation)
        unknown = self.output / 'unknown'
        unknown.write_bytes(b'retain')
        self.rejected()
        self.assertEqual(unknown.read_bytes(), b'retain')
        unknown.rename(self.root / 'retained-unknown')
        p = self.output / self.sources[0].name
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
        m.prepare(self.bundle, vault=self.vault,history=self.history,aggregate=self.aggregate,aggregate_history=self.aggregate_history,successor=self.successor,candidate=self.candidate,peer=self.peer,custody=self.custody,welcome=self.welcome,confirmation=self.confirmation)

    def test_unsafe_lock_and_duplicate_manifest_denied(self):
        lock = self.output.parent / '.mls-build.lock'
        lock.symlink_to(self.manifest)
        self.rejected()
        lock.unlink()
        self.manifest.write_text(self.manifest.read_text().replace('"version":', '"version": 7, "version":', 1))
        self.rejected()
        self.assertFalse(self.output.exists())

    def test_reordered_fields_rejected_before_output(self):
        original = self.manifest.read_bytes()
        pin = json.loads(original)
        top = {k:pin[k] for k in ('files','version','worker_state')}
        entry = json.loads(original)
        entry['files'][0] = {k:entry['files'][0][k] for k in ('source','sha256','bytes','type','url','file')}
        for changed in (top,entry):
            self.manifest.write_text(json.dumps(changed,indent=2)+'\n')
            self.rejected()
            self.assertFalse(self.output.exists())
        self.manifest.write_bytes(original)
        m.prepare(self.bundle,vault=self.vault,history=self.history,aggregate=self.aggregate,aggregate_history=self.aggregate_history,successor=self.successor,candidate=self.candidate,peer=self.peer,custody=self.custody,welcome=self.welcome,confirmation=self.confirmation)
        self.assertTrue(self.output.exists())

    def test_symlinked_lock_parent_rejects_before_creating_files(self):
        original = self.output.parent
        retained = self.root / 'retained-chat'
        original.rename(retained)
        original.symlink_to(retained, target_is_directory=True)
        before = set(retained.iterdir())
        self.rejected()
        self.assertEqual(before, set(retained.iterdir()))
        self.assertFalse((retained / '.mls-build.lock').exists())

class VaultAssetPreparationTests(AssetPreparationTests):
    vault = True

    def test_vault_driver_notices_and_profile_substitution_denied(self):
        for leaf in ('native-vault-store.js','THIRD-PARTY-NOTICES.txt','SODIUM-NOTICES.txt'):
            source = next(p for p in self.sources if p.name == leaf and 'device-keystore' in str(p))
            original = source.read_bytes()
            source.write_bytes(b'X'*len(original))
            self.rejected()
            self.assertFalse(self.output.exists())
            source.write_bytes(original)
        pin = json.loads(self.manifest.read_text())
        pin['files'][-1]['source'] = 'experiments/openmls-browser/THIRD-PARTY-NOTICES.txt'
        self.manifest.write_text(json.dumps(pin))
        self.rejected()
        self.assertFalse(self.output.exists())

    def test_closed_manifest_rejected_before_output(self):
        original = self.manifest.read_bytes()
        changes = [('version',1),('worker_state',True),('url','/../outside'),('type','text/html'),('bytes',True),('sha256','f'*63)]
        for field,value in changes:
            pin=json.loads(original)
            if field in ('version','worker_state'):pin[field]=value
            else:pin['files'][-1][field]=value
            self.manifest.write_text(json.dumps(pin,indent=2)+'\n')
            self.rejected()
            self.assertFalse(self.output.exists())
        self.manifest.write_bytes(original)

    def test_vault_does_not_touch_legacy_output(self):
        legacy = self.output.parent/'mlsassets'
        legacy.mkdir(mode=0o700)
        (legacy/'retained').write_bytes(b'previous prepared bundle')
        m.prepare(self.bundle, vault=True)
        self.assertEqual((legacy/'retained').read_bytes(), b'previous prepared bundle')
        self.assertEqual(len(list(self.output.iterdir())),15)

class HistoryAssetPreparationTests(AssetPreparationTests):
    history = True

    def test_history_profiles_and_test_code_are_not_substitutable(self):
        original=self.manifest.read_bytes()
        for field,value in [('version',2),('version',3),('source','tests/fixtures/native-history/forge-worker.js'),('url','/history-forge-worker.js')]:
            pin=json.loads(original)
            if field=='version':pin[field]=value
            else:pin['files'][-1][field]=value
            self.manifest.write_text(json.dumps(pin,indent=2)+'\n')
            self.rejected();self.assertFalse(self.output.exists())
        self.manifest.write_bytes(original)
        for name in ('mlsassets','vaultassets','historyassets','aggregateassets'):
            old=self.output.parent/name;old.mkdir(mode=0o700);(old/'retained').write_bytes(b'previous bundle')
        m.prepare(self.bundle,history=True)
        self.assertEqual(len(list(self.output.iterdir())),21)
        for name in ('mlsassets','vaultassets','historyassets','aggregateassets'):self.assertEqual((self.output.parent/name/'retained').read_bytes(),b'previous bundle')

    def test_history_workers_and_private_output_links_denied(self):
        source=next(p for p in self.sources if p.name=='history-export-worker.js')
        saved=source.read_bytes();source.write_bytes(b'X'*len(saved));self.rejected();self.assertFalse(self.output.exists());source.write_bytes(saved)
        m.prepare(self.bundle,history=True)
        p=self.output/'history-worker.js';retained=self.root/'retained-worker';p.rename(retained);p.symlink_to(retained)
        self.rejected();self.assertTrue(p.is_symlink());self.assertTrue(retained.exists())
        with self.assertRaises(ValueError):m.prepare(self.bundle,vault=True,history=True)

class AggregateAssetPreparationTests(AssetPreparationTests):
    aggregate = True

    def test_independent_profile_preserves_all_previous_outputs(self):
        for name in ('mlsassets','vaultassets','historyassets','historyassets_v5'):
            old=self.output.parent/name;old.mkdir(mode=0o700);(old/'retained').write_bytes(b'previous bundle')
        m.prepare(self.bundle,aggregate=True)
        self.assertEqual(len(list(self.output.iterdir())),14)
        for name in ('mlsassets','vaultassets','historyassets','historyassets_v5'):
            self.assertEqual((self.output.parent/name/'retained').read_bytes(),b'previous bundle')
        for other in ('vault','history'):
            with self.assertRaises(ValueError):m.prepare(self.bundle,aggregate=True,**{other:True})

    def test_generic_or_instrumented_driver_and_other_profile_denied(self):
        original=self.manifest.read_bytes()
        for source in ('experiments/device-keystore/bundle/native-aggregate-vault.js','artifacts/aggregate-store-instrumented.js'):
            pin=json.loads(original);next(e for e in pin['files'] if e['file']=='aggregate-store.js')['source']=source
            self.manifest.write_text(json.dumps(pin,indent=2)+'\n');self.rejected();self.assertFalse(self.output.exists())
        pin=json.loads(original);pin['version']=3
        self.manifest.write_text(json.dumps(pin,indent=2)+'\n');self.rejected();self.assertFalse(self.output.exists())
        self.manifest.write_bytes(original)
        source=next(p for p in self.sources if p.name=='aggregate-store.js');raw=source.read_bytes();source.write_bytes(b'X'*len(raw))
        self.rejected();self.assertFalse(self.output.exists())

class AggregateHistoryAssetPreparationTests(AssetPreparationTests):
    aggregate_history = True

    def test_preserves_every_prior_output_and_rejects_mixed_selection(self):
        names=('mlsassets','vaultassets','historyassets','historyassets_v5','aggregateassets')
        for name in names:
            old=self.output.parent/name;old.mkdir(mode=0o700);(old/'retained').write_bytes(b'old bundle')
        m.prepare(self.bundle,aggregate_history=True)
        self.assertEqual(len(list(self.output.iterdir())),20)
        for name in names:self.assertEqual((self.output.parent/name/'retained').read_bytes(),b'old bundle')
        for flag in ('vault','history','aggregate'):
            with self.assertRaises(ValueError):m.prepare(self.bundle,aggregate_history=True,**{flag:True})

    def test_closed_recovery_sources_and_versions(self):
        original=self.manifest.read_bytes()
        for field,value in [('version',4),('version',5),('source','tests/fixtures/native-history/aggregate-forge-worker.js'),('url','/aggregate-history-forge-worker.js')]:
            pin=json.loads(original)
            if field=='version':pin[field]=value
            else:pin['files'][-1][field]=value
            self.manifest.write_text(json.dumps(pin,indent=2)+'\n')
            self.rejected();self.assertFalse(self.output.exists())
        self.manifest.write_bytes(original)
        m.prepare(self.bundle,aggregate_history=True)
        p=self.output/'aggregate-history-worker.js';retained=self.root/'old-worker';p.rename(retained);p.symlink_to(retained)
        self.rejected();self.assertTrue(p.is_symlink());self.assertTrue(retained.exists())

class SuccessorAssetPreparationTests(AssetPreparationTests):
    successor = True

    def test_successor_closed_sources_old_profiles_and_outputs(self):
        original=self.manifest.read_bytes()
        for field,value in [('version',6),('source','artifacts/closure-instrumented.js'),('url','/main.js')]:
            pin=json.loads(original)
            if field=='version':pin[field]=value
            else:next(e for e in pin['files'] if e['file']=='successor-closure-store.js')[field]=value
            self.manifest.write_text(json.dumps(pin,indent=2)+'\n');self.rejected();self.assertFalse(self.output.exists())
        self.manifest.write_bytes(original)
        for name in ('mlsassets','vaultassets','historyassets_v5','aggregateassets','aggregatehistoryassets'):
            old=self.output.parent/name;old.mkdir(mode=0o700);(old/'retained').write_bytes(b'prior bundle')
        m.prepare(self.bundle,successor=True)
        self.assertEqual(len(list(self.output.iterdir())),23)
        for name in ('mlsassets','vaultassets','historyassets_v5','aggregateassets','aggregatehistoryassets'):
            self.assertEqual((self.output.parent/name/'retained').read_bytes(),b'prior bundle')
        for flag in ('vault','history','aggregate','aggregate_history'):
            with self.assertRaises(ValueError):m.prepare(self.bundle,successor=True,**{flag:True})

class CandidateAssetPreparationTests(AssetPreparationTests):
    candidate = True

    def test_independent_candidate_profile(self):
        m.prepare(self.bundle,candidate=True)
        self.assertEqual(len(list(self.output.iterdir())),15)
        for flag in ("vault","history","aggregate","aggregate_history","successor"):
            with self.assertRaises(ValueError):m.prepare(self.bundle,candidate=True,**{flag:True})

class PeerAssetPreparationTests(AssetPreparationTests):
    peer = True

    def test_independent_peer_profile(self):
        m.prepare(self.bundle,peer=True)
        self.assertEqual(len(list(self.output.iterdir())),14)
        for flag in ('vault','history','aggregate','aggregate_history','successor','candidate'):
            with self.assertRaises(ValueError):m.prepare(self.bundle,peer=True,**{flag:True})

class CustodyAssetPreparationTests(AssetPreparationTests):
    custody = True

    def test_independent_custody_profile(self):
        m.prepare(self.bundle,custody=True)
        self.assertEqual(len(list(self.output.iterdir())),22)
        for flag in ("vault","history","aggregate","aggregate_history","successor","candidate","peer"):
            with self.assertRaises(ValueError):m.prepare(self.bundle,custody=True,**{flag:True})

class WelcomeAssetPreparationTests(AssetPreparationTests):
    welcome = True

    def test_independent_welcome_profile(self):
        m.prepare(self.bundle,welcome=True)
        self.assertEqual(len(list(self.output.iterdir())),31)
        for flag in ("vault","history","aggregate","aggregate_history","successor","candidate","peer","custody"):
            with self.assertRaises(ValueError):m.prepare(self.bundle,welcome=True,**{flag:True})

    def test_manifest_limit_is_scoped_to_new_profile(self):
        raw=(m.ROOT/'server/internal/chat/welcome_bundle.json').read_bytes()
        self.assertGreater(len(raw),8192)
        m.parse_manifest(raw,welcome=True)
        for options in ({},{'custody':True}):
            with self.assertRaises(ValueError):m.parse_manifest(raw,**options)
        with self.assertRaises(ValueError):m.parse_manifest(b' '*12289,welcome=True)

class ConfirmationAssetTests(AssetPreparationTests):
    confirmation = True

    def test_confirmation_profile_limits_and_exclusion(self):
        m.prepare(self.bundle,confirmation=True)
        self.assertEqual(len(list(self.output.iterdir())),22)
        for flag in ('vault','history','aggregate','aggregate_history','successor','candidate','peer','custody','welcome'):
            with self.assertRaises(ValueError):m.prepare(self.bundle,confirmation=True,**{flag:True})
        with self.assertRaises(ValueError):m.parse_manifest(b' '*8193,confirmation=True)
        raw=(m.ROOT/'server/internal/chat/confirmation_bundle.json').read_bytes()
        self.assertLess(len(raw),8192)
        for flag in ('welcome','custody','peer','candidate','successor'):
            with self.assertRaises(ValueError):m.parse_manifest(raw,**{flag:True})
