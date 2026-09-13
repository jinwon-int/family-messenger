#!/usr/bin/env python3
"""Stage-1 Tuwunel paired backup: built-in online backup plus a restic pair.

Drives the homeserver's own online database backup on the RUNNING instance
through the admin room (see tuwunel_admin_room.py), refuses to continue unless
its verify command confirms every file present, then snapshots the built-in
backup directory (``database_backup_path``) plus config (database side) and the
media directory (media side) as a restic pair. The online backup does not
contain media (measured 2026-09-13), so the media snapshot is mandatory, not
optional. Nothing here prunes, forgets, or deletes. The restic repository and
password come from the environment (RESTIC_*); no hostnames are hardcoded.
"""
import argparse
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

from check_storage import GIB, measure
from tuwunel_admin_room import AdminRoom
from tuwunel_config import (
    TUWUNEL_CONFIG, TUWUNEL_TOKEN, backup_directory, load_admin_token, load_tuwunel_config,
)

STATE = Path('/var/lib/family-messenger-backups')  # default for --state
FREE_RESERVE = 10 * GIB  # source filesystem floor; restic destination capacity is separate


def validate_sources(loaded):
    """Reject missing directories, links (including ancestors), special files and a nested backup dir."""
    info = loaded['config_path'].lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('homeserver config is not a regular file')
    database = loaded['database']
    backups = backup_directory(loaded)  # required; refuses a path inside database_path
    measure(database)  # rejects symlinks, nested filesystems, and special files
    if not backups.is_dir() or backups.is_symlink():
        raise ValueError('database_backup_path directory missing')
    measure(backups)
    media = database / 'media'
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


def online_backup(admin):
    """Trigger the built-in online backup on the live server and demand a passing verify.

    ``admin`` exposes backup_database/list_backups/verify_backup returning the
    server's reply text (AdminRoom). Phrase checks are repeated here so a
    different transport cannot weaken the fail-closed contract.
    """
    if 'done' not in admin.backup_database().lower():
        raise RuntimeError('backup-database did not report Done')
    ids = parse_backup_ids(admin.list_backups())
    if not ids:
        raise RuntimeError('no completed backup found after backup-database')
    if 'all files present' not in admin.verify_backup().lower():
        raise RuntimeError('backup verification did not confirm all files present')
    return ids[-1]


def snapshot_id(output):
    summaries = [record for line in output.splitlines() if line.strip()
                 for record in [json.loads(line)] if record.get('message_type') == 'summary']
    if len(summaries) != 1 or not summaries[0].get('snapshot_id'):
        raise RuntimeError('restic did not confirm a snapshot')
    return summaries[0]['snapshot_id']


def backup_pair(loaded, execute, admin, online=None):
    """Database-side snapshot first, then media; never return a half pair."""
    if online is None:
        online = online_backup
    backups, media = validate_sources(loaded)
    backup_id = online(admin)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    pair = 'tuwunel-' + stamp + '-' + secrets.token_hex(4)
    common = ['restic', 'backup', '--json', '--tag', 'production', '--tag', pair]
    database_snapshot = snapshot_id(execute(common + ['--tag', 'database', str(backups),
                                                      str(loaded['config_path'])]))
    media_snapshot = snapshot_id(execute(common + ['--tag', 'media', str(media)]))
    return {'pair': pair, 'backup_id': backup_id, 'database_snapshot': database_snapshot,
            'media_snapshot': media_snapshot, 'created_at': stamp, 'status': 'complete'}


def parse(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', type=Path, default=TUWUNEL_CONFIG, help='홈서버 설정 파일 (tuwunel.toml)')
    p.add_argument('--state', type=Path, default=STATE, help='백업 기록·잠금 디렉터리 (0700)')
    p.add_argument('--admin-token-file', type=Path, default=TUWUNEL_TOKEN, help='admin 토큰 파일 (0600)')
    return p.parse_args(argv)


def main(argv=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    os.umask(0o077)
    try:
        loaded = load_tuwunel_config(args.config)
        _, free, _ = measure(backup_directory(loaded))
        if free < FREE_RESERVE:
            raise ValueError('source filesystem below reserve; refusing backup')
        admin = AdminRoom(loaded['base'], loaded['server_name'], load_admin_token(args.admin_token_file))
        state = args.state
        state.mkdir(mode=0o700, exist_ok=True)
        if state.is_symlink() or state.stat().st_uid != os.getuid() or state.stat().st_mode & 0o077:
            raise ValueError('untrusted backup state directory')
        fd = os.open(state / 'tuwunel-backup.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as lock:
            os.fchmod(lock.fileno(), 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            record = backup_pair(loaded, run, admin)
            fd = os.open(state / (record['pair'] + '.json'),
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
