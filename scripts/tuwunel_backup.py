#!/usr/bin/env python3
"""Stage-1 Tuwunel paired backup: built-in online backup plus a restic pair.

Drives the homeserver's own online database backup, refuses to continue unless
its verify command confirms every file present, then snapshots the built-in
backup directory plus config (database side) and the media directory (media
side) as a restic pair. The online backup does not contain media (measured
2026-09-13), so the media snapshot is mandatory, not optional. Nothing here
prunes, forgets, or deletes. The restic repository and password come from the
environment (RESTIC_*); no hostnames are hardcoded.
"""
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import subprocess
import sys
import tomllib

from check_storage import GIB, measure

ROOT = Path(__file__).resolve().parents[1]
STATE = Path('/var/lib/family-messenger-backups')
CONFIG = ROOT / '.runtime/tuwunel/tuwunel.toml'
FREE_RESERVE = 10 * GIB  # source filesystem floor; restic destination capacity is separate


def setting(config, *keys):
    """Read a config key from either top level or the legacy [global] section."""
    sections = [config]
    if isinstance(config.get('global'), dict):
        sections.append(config['global'])
    for section in sections:
        node = section
        for key in keys:
            if not isinstance(node, dict) or key not in node:
                node = None
                break
            node = node[key]
        if node is not None:
            return node
    raise KeyError('.'.join(keys))


def load_config(path):
    with open(path, 'rb') as f:
        config = tomllib.load(f)
    return Path(setting(config, 'database', 'path'))


def validate_sources(config_path, database):
    """Reject missing directories, links (including ancestors), and special files."""
    info = config_path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('homeserver config is not a regular file')
    measure(database)  # rejects symlinks, nested filesystems, and special files
    backups = database / 'backups'
    media = database / 'media'
    if not backups.is_dir() or backups.is_symlink():
        raise ValueError('backups directory missing under database path')
    if not media.is_dir() or media.is_symlink():
        raise ValueError('media directory missing under database path')
    return backups, media


def run(command):
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        stdout, _ = proc.communicate(timeout=1200)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
        raise RuntimeError('backup subprocess timed out') from None
    if proc.returncode:
        raise RuntimeError('backup subprocess failed with exit ' + str(proc.returncode))
    return stdout


def parse_backup_ids(output):
    """Extract ids from list-backups output (lines like '#1 ...')."""
    return sorted({int(found) for found in re.findall(r'#(\d+)', output)})


def online_backup(config_path, execute):
    """Trigger the built-in online backup and demand a passing verify."""
    prefix = ['tuwunel', '-c', str(config_path), '--execute']
    execute(prefix + ['server backup-database'])
    ids = parse_backup_ids(execute(prefix + ['server list-backups']))
    if not ids:
        raise RuntimeError('no completed backup found after backup-database')
    verify = execute(prefix + ['server verify-backup'])
    if 'all files present' not in verify.lower():
        raise RuntimeError('backup verification did not confirm all files present')
    return ids[-1]


def snapshot_id(output):
    summaries = [record for line in output.splitlines() if line.strip()
                 for record in [json.loads(line)] if record.get('message_type') == 'summary']
    if len(summaries) != 1 or not summaries[0].get('snapshot_id'):
        raise RuntimeError('restic did not confirm a snapshot')
    return summaries[0]['snapshot_id']


def backup_pair(config_path, execute, online=None):
    """Database-side snapshot first, then media; never return a half pair."""
    if online is None:
        online = online_backup
    database = load_config(config_path)
    backups, media = validate_sources(config_path, database)
    backup_id = online(config_path, execute)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    pair = 'tuwunel-' + stamp + '-' + secrets.token_hex(4)
    common = ['restic', 'backup', '--json', '--tag', 'production', '--tag', pair]
    database_snapshot = snapshot_id(execute(common + ['--tag', 'database', str(backups), str(config_path)]))
    media_snapshot = snapshot_id(execute(common + ['--tag', 'media', str(media)]))
    return {'pair': pair, 'backup_id': backup_id, 'database_snapshot': database_snapshot,
            'media_snapshot': media_snapshot, 'created_at': stamp, 'status': 'complete'}


def main():
    os.umask(0o077)
    try:
        _, free, _ = measure(ROOT / '.runtime')
        if free < FREE_RESERVE:
            raise ValueError('source filesystem below reserve; refusing backup')
        STATE.mkdir(mode=0o700, exist_ok=True)
        if STATE.is_symlink() or STATE.stat().st_uid != os.getuid() or STATE.stat().st_mode & 0o077:
            raise ValueError('untrusted backup state directory')
        fd = os.open(STATE / 'tuwunel-backup.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as lock:
            os.fchmod(lock.fileno(), 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            record = backup_pair(CONFIG, run)
            fd = os.open(STATE / (record['pair'] + '.json'),
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as out:
                os.fchmod(out.fileno(), 0o600)
                json.dump(record, out)
                out.flush()
                os.fsync(out.fileno())
            print(json.dumps(record))
        return 0
    except (OSError, ValueError, KeyError, RuntimeError) as e:
        # Error type only; subprocess stderr, tokens, and config contents stay out.
        print('backup failed: ' + type(e).__name__ + ': ' + str(e), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
