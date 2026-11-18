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

Attachment ciphertext ("blobs", file-v2 — server/blobs.go) lives outside the
database as ``<data-dir>/blobs/<room>/<id>`` and is far too large to repeat in
every 5-minute archive (each file up to ~50 MiB, immutable, named by its own
sha256). It travels as an incremental mirror instead: each push target keeps
``<target>/blobs/<room>/<id>`` next to the archives, filled with
``rsync --ignore-existing`` and never deleted by a push. WHICH files go is
decided by the ``mls_blobs`` rows of the database COPY, not by listing the live
directory, so an archive and its blobs agree; the same rows are written beside
the archive as ``relay-<time>.tar.gz.blobs`` (``<room>/<id> <size>`` per line)
for ``--push-latest`` and for the receiving host's retention. A row whose file
is gone because the relay pruned the row after the copy is fine; a row that is
still live without a usable file is reported (count and ``room/id-prefix``
only) and the run ends non-zero. ``blobs/.tmp`` (uploads in flight) is never
listed, links are never followed, and nothing becomes a path before the room
and id pass the relay's own rules.

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
import stat
import subprocess
import sys
import tarfile
import tempfile

DB_NAME = 'native-mls-v2.db'
POLICY_RE = re.compile(r'^policy-(\d{6})\.json$')
ARCHIVE_RE = re.compile(r'^relay-(\d{8}T\d{6}Z)\.tar\.gz$')
SUMMARY_TABLES = ('mls_events', 'mls_cursors', 'mls_members', 'mls_keypackages', 'mls_lobby_keypackages',
                  'push_devices')
BLOB_DIR = 'blobs'
# server/blobs.go blobPath: room by the identifier rule (devicepolicy.IsIdentifier, 64 max), id = lowercase
# hex sha256. Neither admits a dot or a slash, so '.tmp', '..' and absolute paths cannot be spelled.
BLOB_ROOM_RE = re.compile(r'[A-Za-z0-9_-]{1,64}')
BLOB_ID_RE = re.compile(r'[0-9a-f]{64}')
BLOB_EXAMPLES = 10


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


def blob_relpath(room, blob_id):
    """``<room>/<id>`` of one blob row. The only way a row becomes a path: anything else is refused."""
    if not (isinstance(room, str) and isinstance(blob_id, str)
            and BLOB_ROOM_RE.fullmatch(room) and BLOB_ID_RE.fullmatch(blob_id)):
        raise ValueError('unsafe blob row refused: %.24r/%.16r' % (room, blob_id))
    return room + '/' + blob_id


def blob_label(room, blob_id):
    """What a report may name: the room and the first 12 hex digits of the id."""
    return room + '/' + blob_id[:12]


def blob_rows(db_path):
    """``([(room, id, size)], refused)`` from ``mls_blobs`` of a database copy; a relay older than #499 has none."""
    conn = sqlite3.connect('file:' + str(db_path) + '?mode=ro', uri=True, timeout=5)
    try:
        if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='mls_blobs'").fetchone():
            return [], 0
        found = conn.execute('SELECT room, id, size FROM mls_blobs ORDER BY room, id').fetchall()
    finally:
        conn.close()
    rows = []
    for room, blob_id, size in found:
        try:
            blob_relpath(room, blob_id)
        except ValueError:
            continue
        if isinstance(size, int) and size >= 0:
            rows.append((room, blob_id, size))
    return rows, len(found) - len(rows)


def blob_root(directory):
    """``<directory>/blobs`` if it is a real directory, None if absent; a link is refused."""
    root = Path(directory) / BLOB_DIR
    if root.is_symlink():
        raise ValueError('symlinked blob directory refused: ' + str(root))
    return root if root.is_dir() else None


def locate_blob(root, room, blob_id):
    """``(path, lstat)`` of ``<root>/<room>/<id>`` reached without a link, else ``(None, 'absent' | 'unsafe')``.

    ``root`` is a ``blobs`` directory. It and the room directory must be real directories and the file a
    regular file; whatever cannot be examined counts as unsafe, never as absent.
    """
    directory = Path(root) / blob_relpath(room, blob_id).split('/')[0]
    try:
        for parent in (root, directory):
            if not stat.S_ISDIR(os.lstat(parent).st_mode):
                return None, 'unsafe'
        info = os.lstat(directory / blob_id)
    except FileNotFoundError:
        return None, 'absent'
    except OSError:
        return None, 'unsafe'
    if not stat.S_ISREG(info.st_mode):
        return None, 'unsafe'
    return directory / blob_id, info


def live_blob_keys(data_dir):
    """``{(room, id)}`` the running relay still has a row for; None when that cannot be read."""
    try:
        return {(room, blob_id) for room, blob_id, _ in blob_rows(Path(data_dir) / DB_NAME)[0]}
    except sqlite3.Error:
        return None


def collect_blobs(data_dir, rows, refused=0):
    """Sort the snapshot's blob rows by what is on disk now: ``(report, [(relative, size)] to ship)``.

    ``pruned``: the file is gone and so is the live row (expired after the copy) — expected, not shipped.
    ``missing``: the file is gone but the relay still has the row. ``unsafe``: a link, a special file, a
    size that differs from the row, or a path ``refuse_secret`` rejects. Only ``pruned`` keeps a run clean.
    """
    report = {'rows': len(rows) + refused, 'bytes': sum(size for _, _, size in rows), 'listed': 0, 'pruned': 0,
              'missing': 0, 'unsafe': 0, 'refused': refused, 'examples': []}
    root = Path(data_dir) / BLOB_DIR
    present = []
    absent = []
    for room, blob_id, size in rows:
        path, info = locate_blob(root, room, blob_id)
        if path is None and info == 'absent':
            absent.append((room, blob_id))
            continue
        try:
            if path is None or info.st_size != size:
                raise ValueError('unusable blob file')
            refuse_secret(path)
        except ValueError:
            report['unsafe'] += 1
            report['examples'].append(blob_label(room, blob_id))
            continue
        present.append((blob_relpath(room, blob_id), size))
    live = live_blob_keys(data_dir) if absent else set()
    for room, blob_id in absent:
        if live is not None and (room, blob_id) not in live:
            report['pruned'] += 1
        else:
            report['missing'] += 1
            report['examples'].append(blob_label(room, blob_id))
    report['listed'] = len(present)
    report['examples'] = report['examples'][:BLOB_EXAMPLES]
    report['clean'] = not (report['missing'] or report['unsafe'] or report['refused'])
    return report, present


def blob_list_path(archive):
    return Path(archive).with_suffix('.gz.blobs')


def write_blob_list(archive, rows):
    path = blob_list_path(archive)
    path.write_text(''.join('%s %d\n' % (blob_relpath(room, blob_id), size) for room, blob_id, size in rows))
    os.chmod(path, 0o600)
    return path


def read_blob_list(path):
    """Rows of a ``.blobs`` sidecar, None when the archive has none (made before blobs were carried)."""
    try:
        lines = Path(path).read_text().splitlines()
    except FileNotFoundError:
        return None
    rows = []
    for line in lines:
        relative, _, size = line.partition(' ')
        room, _, blob_id = relative.partition('/')
        if blob_relpath(room, blob_id) != relative or not re.fullmatch(r'\d{1,18}', size):
            raise ValueError('malformed blob list: ' + str(path))
        rows.append((room, blob_id, int(size)))
    return rows


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


def pack(staging, manifest, dest, blobs=None):
    (staging / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    os.chmod(staging / 'manifest.json', 0o600)
    archive = Path(dest) / (manifest['id'] + '.tar.gz')
    partial = archive.with_suffix('.gz.partial')
    with tarfile.open(partial, 'w:gz') as tar:
        tar.add(staging, arcname=manifest['id'])
    os.chmod(partial, 0o600)
    partial.rename(archive)
    if blobs is not None:
        write_blob_list(archive, blobs)  # before the checksum: a finished archive always has its list
    digest = sha256_file(archive)
    checksum = archive.with_suffix('.gz.sha256')
    checksum.write_text(digest + '  ' + archive.name + '\n')
    os.chmod(checksum, 0o600)
    return archive, checksum, digest


def push(archive, checksum, target, ssh_key=None, timeout=600, runner=None, bwlimit=None):
    """rsync the pair to user@host:/dir; a failing target is reported, never retried silently.

    ``bwlimit`` (KiB/s) caps the transfer for a receiver on a thin line (#426: gongmyoung).
    """
    files = [str(archive)] + [str(p) for p in (blob_list_path(archive),) if p.is_file()] + [str(checksum)]
    return rsync(['-a', '--chmod=F600'], files, target, ssh_key, timeout, runner, bwlimit)


def rsync(options, sources, target, ssh_key, timeout, runner, bwlimit, listing=None):
    ssh = 'ssh -o BatchMode=yes -o ConnectTimeout=15' + (' -i ' + ssh_key if ssh_key else '')
    command = ['rsync'] + options
    if bwlimit:
        command.append('--bwlimit=' + str(int(bwlimit)))
    command += ['-e', ssh] + sources + [target.rstrip('/') + '/']
    extra = {} if listing is None else {'input': listing}
    run = runner or subprocess.run
    try:
        proc = run(command, capture_output=True, text=True, timeout=timeout, check=False, **extra)
    except subprocess.TimeoutExpired:
        return {'target': target, 'ok': False, 'error': 'timeout'}
    if proc.returncode:
        return {'target': target, 'ok': False, 'error': 'rsync exit ' + str(proc.returncode),
                'stderr': (proc.stderr or '')[-400:]}
    return {'target': target, 'ok': True}


def push_blobs(data_dir, rows, target, ssh_key=None, runner=None, bwlimit=None):
    """Fill ``<target>/blobs/<room>/<id>`` with the listed files the target does not have yet.

    Same destination as the archives, so a receiving account confined to that directory needs nothing new.
    ``--ignore-existing``: a blob never changes, so a file already there is never rewritten and nothing is
    ever deleted from the mirror by a push (its retention is the receiving host's ``--prune-only``). No
    ``-a``: without ``-l`` rsync skips links, without ``-t`` the mirror's mtime is the arrival time, and
    without ``-p`` existing directories keep their modes while new ones get 0700/0600. The files on disk
    are looked up again right before each transfer; a file that disappears in between fails this push only.
    """
    present = collect_blobs(data_dir, rows)[1]
    if not present:
        return {'ok': True, 'listed': 0}
    timeout = push_timeout(sum(size for _, size in present), bwlimit)
    listing = ''.join(BLOB_DIR + '/' + relative + '\n' for relative, _ in present)
    result = rsync(['--files-from=-', '--ignore-existing', '--chmod=D700,F600'], [str(Path(data_dir)) + '/'],
                   target, ssh_key, timeout, runner, bwlimit, listing=listing)
    del result['target']
    result['listed'] = len(present)
    return result


def push_all(archive, checksum, args, rows, runner=None):
    """Archive first (the RPO), then that target's blobs; a target that refused the archive is not tried twice."""
    timeout = push_timeout(archive.stat().st_size, args.bwlimit)
    pushes = []
    for target in args.push:
        result = push(archive, checksum, target, args.ssh_key, timeout=timeout, runner=runner, bwlimit=args.bwlimit)
        if rows and not args.data_dir:
            result['blobs'] = {'ok': False, 'error': 'no --data-dir: blobs not sent'}
        elif rows and not result['ok']:
            result['blobs'] = {'ok': False, 'error': 'skipped: archive push failed'}
        elif rows:
            try:
                result['blobs'] = push_blobs(args.data_dir, rows, target, args.ssh_key, runner, args.bwlimit)
            except (ValueError, OSError) as exc:  # the next target still gets its archive
                result['blobs'] = {'ok': False, 'error': type(exc).__name__}
        pushes.append(result)
    return timeout, pushes


def push_status(pushes, blobs):
    if not all(p['ok'] and p.get('blobs', {'ok': True})['ok'] for p in pushes):
        return 'push-failed'
    return 'complete' if not blobs or blobs['clean'] else 'blobs-incomplete'


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
        for victim in (path, path.with_suffix('.gz.sha256'), blob_list_path(path)):
            if victim.exists():
                victim.unlink()
        removed.append(path.name)
    for stray in Path(dest).glob('relay-*.tar.gz.blobs'):
        if archive_time(stray.with_suffix('')) and not stray.with_suffix('').exists():
            stray.unlink()  # a list whose archive an older prune already removed
    return removed


def prune_blob_mirror(dest, keep_hours, now=None):
    """Receiving host: delete mirrored blob files that no archive still kept in ``dest`` lists.

    Runs after ``prune`` so the mirror follows the archives' retention: a blob stays as long as any
    kept archive could need it at a restore. Nothing is deleted unless every kept archive has a
    readable list and there is at least one (archives from before blobs were carried, a half-arrived
    push, or a directory that is not an inbox at all leave the mirror alone), nor a file that arrived
    within ``keep_hours`` (its archive may still be on the way). Only ``<room>/<64 hex>`` regular
    files are touched. Returns None when ``dest`` has no mirror.
    """
    mirror = blob_root(dest)
    if mirror is None:
        return None
    archives = [p for p in Path(dest).glob('relay-*.tar.gz') if archive_time(p)]
    kept = set()
    unlisted = 0
    for path in archives:
        try:
            rows = read_blob_list(blob_list_path(path))
        except (OSError, ValueError):
            rows = None
        if rows is None:
            unlisted += 1
        else:
            kept.update(blob_relpath(room, blob_id) for room, blob_id, _ in rows)
    if not archives or unlisted:
        return {'removed': 0, 'skipped': '%d of %d archive(s) have a blob list' % (len(archives) - unlisted,
                                                                                 len(archives))}
    cutoff = (now or utcnow()).timestamp() - keep_hours * 3600
    removed = 0
    for directory in sorted(mirror.iterdir()):
        if not BLOB_ROOM_RE.fullmatch(directory.name) or not stat.S_ISDIR(directory.lstat().st_mode):
            continue
        for entry in sorted(directory.iterdir()):
            info = entry.lstat()
            if (BLOB_ID_RE.fullmatch(entry.name) and stat.S_ISREG(info.st_mode) and info.st_mtime <= cutoff
                    and directory.name + '/' + entry.name not in kept):
                entry.unlink()
                removed += 1
        if directory.lstat().st_mtime <= cutoff:
            try:
                directory.rmdir()  # only a room directory that has been empty for keep_hours
            except OSError:
                pass
    return {'removed': removed}


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
        rows, refused = blob_rows(staging / 'data' / DB_NAME)  # the copy decides which blobs belong to it
        archive, checksum, digest = pack(staging, manifest, dest, blobs=rows)
    finally:
        shutil.rmtree(staging_root, ignore_errors=True)
    blobs = collect_blobs(args.data_dir, rows, refused)[0]
    pushes = push_all(archive, checksum, args, rows)[1]
    removed = prune(dest, args.keep_hours, args.keep_days)
    payload = {
        'id': manifest['id'], 'status': push_status(pushes, blobs), 'blobs': blobs,
        'archive': str(archive), 'archive_sha256': digest, 'size': archive.stat().st_size,
        'started_at': started.isoformat(timespec='seconds'),
        'finished_at': utcnow().isoformat(timespec='seconds'),
        'policy_revision': manifest['policy_revision'], 'db': manifest['db'],
        'pushes': pushes, 'pruned': removed,
    }
    record(args.state, payload)
    return payload


def push_timeout(size_bytes, bwlimit, floor=600):
    """Seconds allowed for one capped transfer: 1.5x the time the cap needs, plus 2 min, never below ``floor``."""
    if not bwlimit:
        return floor
    return max(floor, int(size_bytes / 1024 / int(bwlimit) * 1.5) + 120)


def latest_archive(dest):
    """Newest archive whose ``.sha256`` sidecar exists and names it (``pack`` writes the sidecar last)."""
    archives = sorted(((archive_time(p), p) for p in Path(dest).glob('relay-*.tar.gz') if archive_time(p)),
                      reverse=True)
    for when, path in archives:
        checksum = path.with_suffix('.gz.sha256')
        try:
            line = checksum.read_text().split()
        except OSError:
            continue
        if len(line) == 2 and line[1] == path.name and re.fullmatch(r'[0-9a-f]{64}', line[0]):
            return when, path, checksum, line[0]
    return None


def push_latest(args, now=None, runner=None):
    """#426: ship the newest finished archive to slow receivers on their own schedule.

    The 5-minute snapshot keeps its fast receivers; a thin-line receiver gets the newest archive from a
    separate, rarer timer with ``--bwlimit`` so a long capped transfer never holds the snapshot lock.
    Nothing is created or pruned here. An archive older than ``--max-age-minutes`` is refused (RPO alarm).
    The blobs that archive lists are mirrored to the same targets; that needs ``--data-dir`` (where the
    files are), and without it a list that is not empty makes the run fail rather than pass without them.
    """
    now = now or utcnow()
    found = latest_archive(args.dest)
    if not found:
        raise RuntimeError('no finished archive in ' + str(args.dest))
    when, archive, checksum, digest = found
    age_min = (now - when).total_seconds() / 60
    if age_min > args.max_age_minutes:
        raise RuntimeError('newest archive %s is %.0f min old (max %d)' % (archive.name, age_min, args.max_age_minutes))
    # The archive's own list says which blobs belong to it; None = made before blobs were carried.
    rows = read_blob_list(blob_list_path(archive))
    blobs = collect_blobs(args.data_dir, rows)[0] if rows and args.data_dir else None
    timeout, pushes = push_all(archive, checksum, args, rows, runner=runner)
    payload = {'mode': 'push-latest', 'at': now.isoformat(timespec='seconds'), 'archive': archive.name,
               'archive_sha256': digest, 'size': archive.stat().st_size, 'bwlimit': args.bwlimit,
               'timeout': timeout, 'status': push_status(pushes, blobs), 'blobs': blobs, 'pushes': pushes}
    state = Path(args.state)
    state.mkdir(parents=True, exist_ok=True)
    tmp = state / 'push-latest.json.tmp'
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n')
    os.chmod(tmp, 0o600)
    tmp.rename(state / 'push-latest.json')
    return payload


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--data-dir', help='relay -data-dir (holds ' + DB_NAME + ' and blobs/)')
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
    parser.add_argument('--prune-only', action='store_true',
                        help='apply retention to --dest (archives, then its blobs/ mirror) and exit')
    parser.add_argument('--fence', help='this host name; snapshot only when the fence TXT names it (#440 stage 1)')
    parser.add_argument('--fence-record', help='fence TXT FQDN (required with --fence)')
    parser.add_argument('--bwlimit', type=int, help='rsync --bwlimit in KiB/s for every --push of this run (#426)')
    parser.add_argument('--push-latest', action='store_true',
                        help='no new snapshot: push the newest finished archive in --dest to --push targets (#426)')
    parser.add_argument('--max-age-minutes', type=int, default=30,
                        help='--push-latest refuses an archive older than this (default 30)')
    args = parser.parse_args(argv)
    if bool(args.fence) != bool(args.fence_record):
        parser.error('--fence and --fence-record go together')
    if args.bwlimit is not None and args.bwlimit <= 0:
        parser.error('--bwlimit must be a positive KiB/s value')
    if args.push_latest and args.prune_only:
        parser.error('--push-latest and --prune-only are exclusive')
    if args.push_latest and not args.push:
        parser.error('--push-latest needs at least one --push')
    if not args.state:
        args.state = str(Path(args.dest).parent / 'state')
    if not args.prune_only and not args.push_latest and not (args.data_dir and args.policy_dir):
        parser.error('--data-dir and --policy-dir are required unless --prune-only')
    return args


def fence_state(args):
    """0 = active here (snapshot), 1 = another host is active (skip quietly, still prune --dest — #749),
    2 = unreadable (skip loudly, touch nothing).

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
        removed = prune(args.dest, args.keep_hours, args.keep_days)
        try:
            mirror = prune_blob_mirror(args.dest, args.keep_hours)
        except (ValueError, OSError) as exc:
            print(json.dumps({'pruned': removed}))
            print('blob mirror prune failed: ' + str(exc), file=sys.stderr)
            return 1
        print(json.dumps({'pruned': removed, 'blob_mirror': mirror}))
        return 0
    fenced = fence_state(args)
    if fenced == 1:
        # #749: a standby still owns the archives it made while it was active. The snapshot step is
        # skipped, but retention must keep running or they never expire (seoseo kept 91 after the
        # 11-06 cutover). Pruning only deletes this script's own archives under --dest.
        try:
            removed = prune(args.dest, args.keep_hours, args.keep_days)
        except OSError as exc:
            print('standby prune failed: ' + str(exc), file=sys.stderr)
            return 1
        if removed:
            print(json.dumps({'pruned': removed}))
        return 0
    if fenced:
        return 1
    Path(args.state).mkdir(parents=True, exist_ok=True)
    if args.push_latest:
        # Own lock: a capped transfer may run for many minutes and must not block the 5-minute snapshot.
        with open(Path(args.state) / '.push-lock', 'w') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print('another push-latest is running', file=sys.stderr)
                return 2
            try:
                payload = push_latest(args)
            except (ValueError, RuntimeError, sqlite3.Error, OSError) as exc:
                print('push-latest failed: ' + str(exc), file=sys.stderr)
                return 1
        print(json.dumps({k: payload[k] for k in ('archive', 'archive_sha256', 'bwlimit', 'timeout', 'blobs',
                                                   'pushes')}))
        return finish(payload)
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
                                               'blobs', 'pushes', 'pruned')}))
    return finish(payload)


def finish(payload):
    blobs = payload['blobs']
    if blobs and not blobs['clean']:
        print('blobs: rows=%(rows)d listed=%(listed)d pruned=%(pruned)d missing=%(missing)d unsafe=%(unsafe)d '
              'refused=%(refused)d INCOMPLETE' % blobs
              + (' (' + ', '.join(blobs['examples']) + ')' if blobs['examples'] else ''), file=sys.stderr)
    return 0 if payload['status'] == 'complete' else 1


if __name__ == '__main__':
    sys.exit(main())
