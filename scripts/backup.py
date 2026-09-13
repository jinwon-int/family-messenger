#!/usr/bin/env python3
"""Paired encrypted DB/files backups; no pruning or media deletion."""
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import signal
import stat
import subprocess
import sys
import traceback

from check_storage import measure, GIB

ROOT = Path(__file__).resolve().parents[1]
STATE = Path('/var/lib/family-messenger-backups')
# systemd loads /etc/family-messenger/backup.env (EnvironmentFile=) into the process
# environment; restic reads RESTIC_* from there and the same file must name the target.
ENV_FILE = '/etc/family-messenger/backup.env'
TARGET_HOST = re.compile(r'(?:[a-z_][a-z0-9_-]{0,31}@)?[A-Za-z0-9][A-Za-z0-9.-]{0,252}')
TARGET_PATH = re.compile(r'/[A-Za-z0-9._/-]*')
DIRECTORIES = ('.runtime', 'web', 'scripts', 'deploy')
FILES = ('.env', 'compose.yaml', '.runtime/postgres.env', '.runtime/element.json',
         '.runtime/installation.json', '.runtime/synapse/homeserver.yaml',
         '.runtime/synapse/log.config', '.runtime/synapse/server.signing.key')


def validate_sources(root):
    for name in DIRECTORIES:
        measure(root/name)  # Reject missing dirs, links (including ancestors), and special files.
    signatures = {}
    for name in FILES:
        info = (root/name).lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('required backup source is not a regular file')
        signatures[name] = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
    return signatures


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
        raise RuntimeError('backup subprocess failed with exit '+str(proc.returncode))
    return stdout


def snapshot_id(output):
    summaries = [r for line in output.splitlines() if line.strip()
                 for r in [json.loads(line)] if r.get('message_type') == 'summary']
    if len(summaries) != 1 or not summaries[0].get('snapshot_id'):
        raise RuntimeError('restic did not confirm a snapshot')
    return summaries[0]['snapshot_id']


def backup_pair(root, execute=run):
    # Uploads store immutable originals before committing their DB references.
    # Do not run media purge, password/config changes, or upgrades during this job.
    signatures = validate_sources(root)
    config = json.loads((root/'.runtime/synapse/homeserver.yaml').read_text())
    if config.get('media_retention'):
        raise ValueError('online backup requires media retention/purge disabled')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    pair = 'pair-'+stamp+'-'+secrets.token_hex(4)
    common = ['restic', 'backup', '--json', '--tag', 'production', '--tag', pair]
    database = snapshot_id(execute(common+['--tag', 'database', '--stdin-filename',
        'postgres.dump', '--stdin-from-command', '--', 'docker', 'compose',
        '--project-directory', str(root), 'exec', '-T', 'postgres', 'pg_dump',
        '-U', 'synapse', '-d', 'synapse', '-Fc']))
    files = snapshot_id(execute(common+['--tag', 'files', '--']+
        [str(root/p) for p in ('.runtime', '.env', 'compose.yaml', 'web', 'scripts', 'deploy')]))
    if validate_sources(root) != signatures:
        raise RuntimeError('configuration changed during backup; pair not complete')
    return {'pair': pair, 'database_snapshot': database, 'files_snapshot': files,
            'created_at': stamp, 'status': 'complete'}


def backup_target(env):
    """Target host/path for the free-space precheck; absent or odd values fail closed."""
    host = env.get('BACKUP_TARGET_HOST', '')
    path = env.get('BACKUP_TARGET_PATH', '')
    if not TARGET_HOST.fullmatch(host):
        raise ValueError('BACKUP_TARGET_HOST missing or invalid; set it in '+ENV_FILE)
    if not TARGET_PATH.fullmatch(path) or '..' in path.split('/'):
        raise ValueError('BACKUP_TARGET_PATH missing or not an absolute path; set it in '+ENV_FILE)
    return host, path


def remote_free_bytes(host, path, execute=run):
    probe = 'import shutil; print(shutil.disk_usage(%r).free)' % path
    output = execute(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', host,
                      'python3 -c '+shlex.quote(probe)])
    try:
        return int(output.strip())
    except ValueError:
        raise RuntimeError('backup target did not report free space') from None


def main(execute=run, env=None, root=ROOT, state=STATE):
    os.umask(0o077)
    env = os.environ if env is None else env
    try:
        host, path = backup_target(env)
        state.mkdir(mode=0o700, exist_ok=True)
        if (state.is_symlink() or state.stat().st_uid != os.getuid()
                or state.stat().st_mode & 0o077):
            raise ValueError('untrusted backup state directory')
        fd = os.open(state/'backup.lock', os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as lock:
            os.fchmod(lock.fileno(), 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX|fcntl.LOCK_NB)
            retained, free, _ = measure(root/'.runtime')
            if free < 100*GIB:
                raise ValueError('source filesystem reserve below 100GiB')
            if remote_free_bytes(host, path, execute) < retained + 80*GIB:
                raise ValueError('backup filesystem lacks full media size plus 80GiB reserve')
            record = backup_pair(root, execute)
            fd = os.open(state/(record['pair']+'.json'),
                         os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as f:
                os.fchmod(f.fileno(), 0o600)
                json.dump(record, f)
                f.flush()
                os.fsync(f.fileno())
            print(json.dumps(record))
        return 0
    except (OSError, ValueError, RuntimeError) as e:
        # stdout keeps the machine-readable record; stderr (journal) gets the cause.
        # Messages come from this script, errno/paths or exit codes only: neither DB
        # output nor credentials/subprocess stderr are ever part of them.
        print(json.dumps({'status': 'failed', 'error_type': type(e).__name__}))
        print(type(e).__name__+': '+str(e), file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
