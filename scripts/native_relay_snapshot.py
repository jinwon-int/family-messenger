#!/usr/bin/env python3
"""Stage-0 off-host snapshot of the native-mls v2 relay (#440).

The relay keeps every delivery fact in one SQLite file (``native-mls-v2.db``,
``_journal_mode=DELETE`` + ``_txlock=immediate`` — see server/store.go) plus the
device-policy chain directory (``policy-NNNNNN.json``). Neither had an off-host
copy before #440, so a host loss meant losing the relay outright. This script
takes a consistent copy of the RUNNING relay with the SQLite online-backup API
(no service stop, no lock held longer than one page copy), adds the policy
chain, the served web bundles and the unit drop-ins, writes a sha256 manifest
with a per-room summary (``epoch``/``revision``/``last_seq``), packs it as one
archive and ships it to each ``--push`` target with rsync over ssh. Retention
is local only (``--prune`` on the receiving host trims its own copy).

Never included: the APNs ``.p8`` key (owner decision #440-A — the standby runs
without push). Any ``.p8`` or anything under an ``apns`` directory is refused,
not silently skipped. No hostnames, tokens or paths are hardcoded.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tarfile
import tempfile

DB_NAME = 'native-mls-v2.db'
POLICY_RE = re.compile(r'^policy-(\d{6})\.json$')
ARCHIVE_RE = re.compile(r'^relay-(\d{8}T\d{6}Z)\.tar\.gz$')
SUMMARY_TABLES = ('mls_events', 'mls_cursors', 'mls_members', 'mls_keypackages', 'mls_lobby_keypackages',
                  'push_devices')


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


def snapshot_id(now=None):
    return 'relay-' + (now or utcnow()).strftime('%Y%m%dT%H%M%SZ')


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def refuse_secret(path):
    """Fail closed on anything that looks like the APNs key (#440-A: never copied)."""
    text = str(path)
    if text.endswith('.p8') or any(part.lower() == 'apns' for part in Path(text).parts):
        raise ValueError('refusing to include APNs material: ' + text)


def walk_regular(root):
    """Yield (relative, absolute) regular files under root; links and special files are refused."""
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('not a directory: ' + str(root))
    for current, dirs, files in os.walk(root):
        for name in dirs:
            if (Path(current) / name).is_symlink():
                raise ValueError('symlinked directory refused: ' + str(Path(current) / name))
        for name in sorted(files):
            absolute = Path(current) / name
            info = absolute.lstat()
            if not os.path.stat.S_ISREG(info.st_mode):
                raise ValueError('non-regular file refused: ' + str(absolute))
            refuse_secret(absolute)
            yield absolute.relative_to(root), absolute


def online_backup(source_db, dest_db, busy_timeout_ms=5000):
    """Copy the live database with sqlite's backup API; readers never block the relay's writer."""
    src = sqlite3.connect('file:' + str(source_db) + '?mode=ro', uri=True, timeout=busy_timeout_ms / 1000)
    try:
        dst = sqlite3.connect(str(dest_db))
        try:
            src.backup(dst)
            dst.commit()
        finally:
            dst.close()
    finally:
        src.close()
    os.chmod(dest_db, 0o600)


def summarize_db(db_path):
    """Per-room counters (what a restore must never roll back, store.go:202) plus table counts."""
    conn = sqlite3.connect('file:' + str(db_path) + '?mode=ro', uri=True)
    try:
        integrity = conn.execute('PRAGMA integrity_check').fetchone()[0]
        rooms = {}
        for room, epoch, revision, last_seq in conn.execute(
                'SELECT room, epoch, revision, last_seq FROM mls_rooms ORDER BY room'):
            rooms[room] = {'epoch': epoch, 'revision': revision, 'last_seq': last_seq}
        existing = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        counts = {}
        for table in SUMMARY_TABLES:
            if table in existing:
                counts[table] = conn.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0]
    finally:
        conn.close()
    return {'integrity': integrity, 'rooms': rooms, 'counts': counts}


def policy_revision(policy_dir):
    revisions = [int(m.group(1)) for m in (POLICY_RE.match(p.name) for p in Path(policy_dir).iterdir()) if m]
    return max(revisions) if revisions else 0


def stage(args, staging):
    """Assemble the snapshot tree under staging; returns the manifest dict."""
    files = {}

    def add(relative, absolute, mode=None):
        target = staging / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(absolute, target)
        os.chmod(target, mode if mode is not None else 0o600)
        files[str(relative)] = {'sha256': sha256_file(target), 'size': target.stat().st_size}

    source_db = Path(args.data_dir) / DB_NAME
    if source_db.is_symlink() or not source_db.is_file():
        raise ValueError('relay database missing: ' + str(source_db))
    (staging / 'data').mkdir(mode=0o700)
    copied_db = staging / 'data' / DB_NAME
    online_backup(source_db, copied_db)
    files['data/' + DB_NAME] = {'sha256': sha256_file(copied_db), 'size': copied_db.stat().st_size}
    summary = summarize_db(copied_db)
    if summary['integrity'] != 'ok':
        raise RuntimeError('integrity_check on the copied database: ' + summary['integrity'])

    for relative, absolute in walk_regular(args.policy_dir):
        add(Path('policy') / relative, absolute)
    for label, directory in (('static', args.static_dir), ('hande', args.hande_dir), ('dropin', args.dropin_dir)):
        if directory:
            for relative, absolute in walk_regular(directory):
                add(Path(label) / relative, absolute, 0o644)
    if args.env_file:
        env = Path(args.env_file)
        refuse_secret(env)
        if env.is_symlink() or not env.is_file():
            raise ValueError('env file missing: ' + str(env))
        add(Path('env') / env.name, env)

    return {
        'format': 'native-relay-snapshot/1',
        'id': staging.name,
        'created_at': utcnow().isoformat(timespec='seconds'),
        'source_host': socket.gethostname(),
        'policy_revision': policy_revision(args.policy_dir),
        'db': summary,
        'files': files,
    }


def pack(staging, manifest, dest):
    (staging / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    os.chmod(staging / 'manifest.json', 0o600)
    archive = Path(dest) / (manifest['id'] + '.tar.gz')
    partial = archive.with_suffix('.gz.partial')
    with tarfile.open(partial, 'w:gz') as tar:
        tar.add(staging, arcname=manifest['id'])
    os.chmod(partial, 0o600)
    partial.rename(archive)
    digest = sha256_file(archive)
    checksum = archive.with_suffix('.gz.sha256')
    checksum.write_text(digest + '  ' + archive.name + '\n')
    os.chmod(checksum, 0o600)
    return archive, checksum, digest


def push(archive, checksum, target, ssh_key=None, timeout=600, runner=None):
    """rsync the pair to user@host:/dir; a failing target is reported, never retried silently."""
    ssh = 'ssh -o BatchMode=yes -o ConnectTimeout=15' + (' -i ' + ssh_key if ssh_key else '')
    command = ['rsync', '-a', '--chmod=F600', '-e', ssh, str(archive), str(checksum), target.rstrip('/') + '/']
    run = runner or subprocess.run
    try:
        proc = run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return {'target': target, 'ok': False, 'error': 'timeout'}
    if proc.returncode:
        return {'target': target, 'ok': False, 'error': 'rsync exit ' + str(proc.returncode),
                'stderr': (proc.stderr or '')[-400:]}
    return {'target': target, 'ok': True}


def archive_time(path):
    match = ARCHIVE_RE.match(path.name)
    if not match:
        return None
    return datetime.datetime.strptime(match.group(1), '%Y%m%dT%H%M%SZ').replace(tzinfo=datetime.timezone.utc)


def prune(dest, keep_hours, keep_days, now=None):
    """Keep every archive younger than keep_hours, then one per UTC day up to keep_days; delete the rest.

    Only files named by this script are touched. Returns the deleted archive names.
    """
    now = now or utcnow()
    archives = sorted(((archive_time(p), p) for p in Path(dest).glob('relay-*.tar.gz') if archive_time(p)),
                      reverse=True)
    kept_days = set()
    removed = []
    for when, path in archives:
        age = now - when
        if age <= datetime.timedelta(hours=keep_hours):
            continue
        day = when.date()
        if age <= datetime.timedelta(days=keep_days) and day not in kept_days:
            kept_days.add(day)
            continue
        for victim in (path, path.with_suffix('.gz.sha256')):
            if victim.exists():
                victim.unlink()
        removed.append(path.name)
    return removed


def record(state_dir, payload):
    state_dir = Path(state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    path = state_dir / (payload['id'] + '.json')
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n')
    os.chmod(path, 0o600)
    latest = state_dir / 'latest.json'
    tmp = latest.with_suffix('.json.tmp')
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n')
    os.chmod(tmp, 0o600)
    tmp.rename(latest)
    skipped = state_dir / 'skipped-latest.json'
    if skipped.exists():
        skipped.unlink()
    return path


def snapshot(args):
    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True, mode=0o700)
    started = utcnow()
    staging_root = tempfile.mkdtemp(prefix='.staging-', dir=dest)
    try:
        staging = Path(staging_root) / snapshot_id(started)
        staging.mkdir(mode=0o700)
        manifest = stage(args, staging)
        archive, checksum, digest = pack(staging, manifest, dest)
    finally:
        shutil.rmtree(staging_root, ignore_errors=True)
    pushes = [push(archive, checksum, target, args.ssh_key) for target in args.push]
    removed = prune(dest, args.keep_hours, args.keep_days)
    payload = {
        'id': manifest['id'], 'status': 'complete' if all(p['ok'] for p in pushes) else 'push-failed',
        'archive': str(archive), 'archive_sha256': digest, 'size': archive.stat().st_size,
        'started_at': started.isoformat(timespec='seconds'),
        'finished_at': utcnow().isoformat(timespec='seconds'),
        'policy_revision': manifest['policy_revision'], 'db': manifest['db'],
        'pushes': pushes, 'pruned': removed,
    }
    record(args.state, payload)
    return payload


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--data-dir', help='relay -data-dir (holds ' + DB_NAME + ')')
    parser.add_argument('--policy-dir', help='relay -device-state directory (policy chain)')
    parser.add_argument('--static-dir', help='relay -static-dir (relay-app bundle); optional')
    parser.add_argument('--hande-dir', help='relay -hande-dir (hande web app); optional')
    parser.add_argument('--dropin-dir', help='systemd drop-in directory of the relay unit; optional')
    parser.add_argument('--env-file', help='relay EnvironmentFile (issuer/aud/jwks); optional')
    parser.add_argument('--dest', required=True, help='local archive directory (0700)')
    parser.add_argument('--state', help='success-record directory (default: <dest>/../state)')
    parser.add_argument('--push', action='append', default=[], help='rsync target user@host:/dir (repeatable)')
    parser.add_argument('--ssh-key', help='private key path for --push (value never printed)')
    parser.add_argument('--keep-hours', type=int, default=6)
    parser.add_argument('--keep-days', type=int, default=30)
    parser.add_argument('--prune-only', action='store_true', help='apply retention to --dest and exit')
    parser.add_argument('--fence', help='this host name; snapshot only when the fence TXT names it (#440 stage 1)')
    parser.add_argument('--fence-record', help='fence TXT FQDN (required with --fence)')
    args = parser.parse_args(argv)
    if bool(args.fence) != bool(args.fence_record):
        parser.error('--fence and --fence-record go together')
    if not args.state:
        args.state = str(Path(args.dest).parent / 'state')
    if not args.prune_only and not (args.data_dir and args.policy_dir):
        parser.error('--data-dir and --policy-dir are required unless --prune-only')
    return args


def fence_state(args):
    """0 = active here (snapshot), 1 = another host is active (skip quietly), 2 = unreadable (skip loudly).

    An unproven host neither serves nor snapshots, but the active host losing snapshots during a DoH
    outage must be visible: 2 is reported as a failure so the timer/watchdog sees the RPO eroding.
    """
    if not args.fence:
        return 0
    from native_relay_fence import check
    code, message = check(args.fence, args.fence_record)
    if code:
        print('snapshot skipped — ' + message, file=sys.stderr)
        state = Path(args.state)
        state.mkdir(parents=True, exist_ok=True)
        skipped = state / 'skipped-latest.json'
        skipped.write_text(json.dumps({'at': utcnow().isoformat(timespec='seconds'), 'fence_exit': code,
                                       'message': message}) + '\n')
        os.chmod(skipped, 0o600)
    return code


def main(argv=None):
    args = parse(argv)
    if args.prune_only:
        print(json.dumps({'pruned': prune(args.dest, args.keep_hours, args.keep_days)}))
        return 0
    fenced = fence_state(args)
    if fenced:
        return 0 if fenced == 1 else 1
    Path(args.state).mkdir(parents=True, exist_ok=True)
    with open(Path(args.state) / '.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('another snapshot is running', file=sys.stderr)
            return 2
        try:
            payload = snapshot(args)
        except (ValueError, RuntimeError, sqlite3.Error, OSError) as exc:
            print('snapshot failed: ' + str(exc), file=sys.stderr)
            return 1
    print(json.dumps({k: payload[k] for k in ('id', 'status', 'archive', 'archive_sha256', 'policy_revision',
                                               'pushes', 'pruned')}))
    return 0 if payload['status'] == 'complete' else 1


if __name__ == '__main__':
    sys.exit(main())
