#!/usr/bin/env python3
"""Restore (or drill-restore) a native-relay snapshot made by native_relay_snapshot.py (#440).

Verifies the archive against its ``.sha256`` sidecar and every member against
the embedded manifest before anything is written, extracts without following
links or escaping the target, refuses to touch a host whose relay unit is
active (a running relay would be writing the same SQLite file), moves any
existing target directories aside (never deletes), and copies the tree in.

``--bump-seq N`` is owner decision #440-C (c1): after a restore from an older
snapshot the relay would otherwise re-issue sequence numbers that clients have
already consumed and the clients would skip those events silently (iOS
RoomSyncEngine halts only when the relay is AHEAD of the cursor). Raising
``mls_rooms.last_seq`` by N on every room turns the silent loss into an explicit
``history_gap`` halt that the operator can see and repair. store.go:202 states
last_seq must never go backwards; this keeps that promise across a restore.

``--relay-binary`` runs a loopback drill: start the restored tree with
``-access-mode disabled``, wait for ``/v2/health``, compare counts with the
manifest, stop. Isolated environments only — never on the live data directory.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from native_relay_snapshot import DB_NAME, sha256_file, summarize_db  # noqa: E402

LABELS = ('data', 'policy', 'static', 'hande', 'dropin', 'env')


def verify_archive(archive, checksum=None):
    checksum = Path(checksum) if checksum else Path(archive).with_suffix('.gz.sha256')
    if not checksum.is_file():
        raise ValueError('checksum sidecar missing: ' + str(checksum))
    expected = checksum.read_text().split()[0]
    actual = sha256_file(archive)
    if actual != expected:
        raise ValueError('archive sha256 mismatch: expected ' + expected + ' got ' + actual)
    return actual


def safe_extract(archive, into):
    """Extract only regular files/directories whose paths stay inside one top-level snapshot dir."""
    into = Path(into)
    top = None
    with tarfile.open(archive, 'r:gz') as tar:
        for member in tar.getmembers():
            parts = Path(member.name).parts
            if not parts or parts[0] in ('', '.', '..') or any(p == '..' for p in parts) or member.name.startswith('/'):
                raise ValueError('unsafe member path: ' + member.name)
            if not (member.isreg() or member.isdir()):
                raise ValueError('non-regular member refused: ' + member.name)
            top = top or parts[0]
            if parts[0] != top:
                raise ValueError('archive holds more than one snapshot: ' + member.name)
        tar.extractall(into, filter='data')
    if not top:
        raise ValueError('empty archive')
    return into / top


def verify_tree(root):
    manifest = json.loads((Path(root) / 'manifest.json').read_text())
    if manifest.get('format') != 'native-relay-snapshot/1':
        raise ValueError('unknown snapshot format')
    for relative, meta in manifest['files'].items():
        path = Path(root) / relative
        if not path.is_file():
            raise ValueError('manifest file missing: ' + relative)
        actual = sha256_file(path)
        if actual != meta['sha256']:
            raise ValueError('sha256 mismatch for ' + relative)
    return manifest


def unit_active(unit, runner=None):
    proc = (runner or subprocess.run)(['systemctl', 'is-active', unit], capture_output=True, text=True, check=False)
    return (proc.stdout or '').strip() == 'active'


def move_aside(target, stamp):
    target = Path(target)
    if target.is_symlink():
        raise ValueError('target is a symlink: ' + str(target))
    if target.exists() and any(target.iterdir()):
        aside = target.with_name(target.name + '.pre-restore-' + stamp)
        target.rename(aside)
        return str(aside)
    return None


def copy_label(root, label, target, dir_mode, file_mode):
    source = Path(root) / label
    if not source.is_dir():
        return False
    target = Path(target)
    target.mkdir(parents=True, exist_ok=True)
    os.chmod(target, dir_mode)
    for current, dirs, files in os.walk(source):
        rel = Path(current).relative_to(source)
        for name in dirs:
            (target / rel / name).mkdir(exist_ok=True)
            os.chmod(target / rel / name, dir_mode)
        for name in files:
            shutil.copyfile(Path(current) / name, target / rel / name)
            os.chmod(target / rel / name, file_mode)
    return True


def bump_seq(db_path, amount):
    """c1: raise every room's last_seq by amount; returns {room: (before, after)}."""
    if amount < 0:
        raise ValueError('--bump-seq must be >= 0')
    conn = sqlite3.connect(str(db_path), timeout=5)
    try:
        before = {room: seq for room, seq in conn.execute('SELECT room, last_seq FROM mls_rooms')}
        if amount:
            conn.execute('UPDATE mls_rooms SET last_seq = last_seq + ?', (amount,))
            conn.commit()
        after = {room: seq for room, seq in conn.execute('SELECT room, last_seq FROM mls_rooms')}
    finally:
        conn.close()
    return {room: {'before': before[room], 'after': after[room]} for room in before}


def chown_tree(root, owner):
    for current, dirs, files in os.walk(root):
        shutil.chown(current, owner, owner)
        for name in files:
            shutil.chown(Path(current) / name, owner, owner)


def probe(url, timeout=3):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except (urllib.error.URLError, OSError):
        return None


def drill(binary, data_dir, policy_dir, port, wait=20):
    """Start the restored tree on loopback with Access disabled, wait for /v2/health, stop."""
    command = [str(binary), '-addr', '127.0.0.1:' + str(port), '-data-dir', str(data_dir),
               '-device-state', str(policy_dir), '-access-mode', 'disabled']
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            start_new_session=True)
    status = None
    deadline = time.monotonic() + wait
    try:
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                break
            status = probe('http://127.0.0.1:' + str(port) + '/v2/health')
            if status == 200:
                break
            time.sleep(0.5)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    output = (proc.stdout.read() if proc.stdout else '')[-2000:]
    return {'health': status, 'exit': proc.returncode, 'log_tail': output}


def restore(args, runner=None):
    digest = verify_archive(args.archive, args.sha256_file)
    stamp = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    with tempfile.TemporaryDirectory(prefix='relay-restore-') as tmp:
        root = safe_extract(args.archive, tmp)
        manifest = verify_tree(root)
        if args.summary_only:
            return {'archive_sha256': digest, 'manifest': {k: manifest[k] for k in
                                                          ('id', 'created_at', 'source_host', 'policy_revision', 'db')}}
        if not args.skip_unit_check and unit_active(args.unit, runner):
            raise RuntimeError('relay unit ' + args.unit + ' is active; stop it before restoring')
        targets = {'data': args.target_data_dir, 'policy': args.target_policy_dir,
                   'static': args.target_static_dir, 'hande': args.target_hande_dir}
        modes = {'data': (0o700, 0o600), 'policy': (0o700, 0o600), 'static': (0o755, 0o644), 'hande': (0o755, 0o644)}
        aside = {}
        restored = []
        for label, target in targets.items():
            if not target or not (root / label).is_dir():
                continue
            aside[label] = move_aside(target, stamp)
            copy_label(root, label, target, *modes[label])
            restored.append(label)
        db_path = Path(args.target_data_dir) / DB_NAME
        bumped = bump_seq(db_path, args.bump_seq)
        summary = summarize_db(db_path)
        if args.owner:
            for label in ('data', 'policy'):
                if targets[label] and label in restored:
                    chown_tree(targets[label], args.owner)
        result = {
            'archive_sha256': digest, 'snapshot_id': manifest['id'], 'snapshot_created_at': manifest['created_at'],
            'restored': restored, 'moved_aside': aside, 'bump_seq': args.bump_seq, 'rooms': bumped,
            'db': summary, 'manifest_db': manifest['db'], 'policy_revision': manifest['policy_revision'],
        }
        counts_match = summary['counts'] == manifest['db']['counts'] and summary['integrity'] == 'ok'
        result['counts_match'] = counts_match
        if args.relay_binary:
            result['drill'] = drill(args.relay_binary, args.target_data_dir, args.target_policy_dir,
                                    args.drill_port)
        return result


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--archive', required=True)
    parser.add_argument('--sha256-file', help='default: <archive>.sha256 beside it')
    parser.add_argument('--summary-only', action='store_true', help='verify and print the manifest; write nothing')
    parser.add_argument('--target-data-dir')
    parser.add_argument('--target-policy-dir')
    parser.add_argument('--target-static-dir')
    parser.add_argument('--target-hande-dir')
    parser.add_argument('--bump-seq', type=int, default=0, help='#440-C c1: add N to every room last_seq')
    parser.add_argument('--owner', help='chown data/policy trees to this user (e.g. native-relay)')
    parser.add_argument('--unit', default='native-relay', help='systemd unit that must be inactive')
    parser.add_argument('--skip-unit-check', action='store_true', help='drill into throwaway directories only')
    parser.add_argument('--relay-binary', help='run a loopback drill with this native-mls-relay binary')
    parser.add_argument('--drill-port', type=int, default=18999)
    args = parser.parse_args(argv)
    if not args.summary_only and not (args.target_data_dir and args.target_policy_dir):
        parser.error('--target-data-dir and --target-policy-dir are required unless --summary-only')
    return args


def main(argv=None):
    args = parse(argv)
    try:
        result = restore(args)
    except (ValueError, RuntimeError, sqlite3.Error, OSError, tarfile.TarError) as exc:
        print('restore failed: ' + str(exc), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    ok = args.summary_only or (result['counts_match'] and (not args.relay_binary or result['drill']['health'] == 200))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
