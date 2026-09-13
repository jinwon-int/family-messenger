#!/usr/bin/env python3
"""Stage-1 Tuwunel restore drill; isolated or synthetic environments only.

Replays the measured restore procedure: stop the service, move the database
directory aside, run the built-in one-shot restore (which shuts the server
down again instead of opening a listener), copy the preserved media directory
back, then start the service and wait for the client API. The restore run
creates an empty media directory, so the media copy uses "existing directory"
semantics (a plain 'cp -a src dst' would be skipped inside it; measured
2026-09-13). Stop/start commands are required arguments; this script never
guesses how a host runs its service.
"""
import argparse
import datetime
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import tomllib
import urllib.request

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from tuwunel_backup import CONFIG, load_config, parse_backup_ids, setting  # noqa: E402


def run_text(command, timeout=600):
    """Run a command and return combined output; stderr carries restore logs."""
    try:
        proc = subprocess.run(command, capture_output=True, text=True,
                              timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise RuntimeError('restore subprocess timed out') from None
    if proc.returncode:
        raise RuntimeError('restore subprocess failed with exit ' + str(proc.returncode))
    return proc.stdout + proc.stderr


def local_url(config_path):
    with open(config_path, 'rb') as f:
        config = tomllib.load(f)
    address = setting(config, 'address')
    if address not in ('127.0.0.1', 'localhost', '::1'):
        raise ValueError('restore probe requires a loopback bind')
    return 'http://127.0.0.1:' + str(setting(config, 'port'))


def probe(url, attempts=30, delay=1.0):
    """Wait for the client API to answer on loopback after the restart."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for attempt in range(attempts):
        try:
            with opener.open(url + '/_matrix/client/versions', timeout=5) as response:
                return response.status == 200
        except OSError:
            if attempt + 1 < attempts:
                time.sleep(delay)
    return False


def drill(config_path, binary, stop_command, start_command, backup_id=None,
          execute=None, check=None, base_url=None):
    """Run one restore drill; returns a record or raises with the state left put."""
    if execute is None:
        execute = run_text
    if not stop_command or not start_command:
        raise ValueError('stop and start service commands are required')
    database = load_config(config_path)
    if not database.is_dir() or database.is_symlink():
        raise ValueError('database directory missing at ' + str(database))
    listing = execute([binary, '-c', str(config_path), '--execute', 'server list-backups'])
    ids = parse_backup_ids(listing)
    if not ids:
        raise ValueError('no online backups found; refusing to drill')
    target = max(ids)
    if backup_id is not None:
        if backup_id not in ids:
            raise ValueError('backup id not found: ' + str(backup_id))
        target = backup_id
    execute(stop_command)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    saved = database.with_name(database.name + '.pre-restore-' + stamp)
    database.rename(saved)
    database.mkdir(parents=True)
    try:
        output = execute([binary, '-c', str(config_path), '--restore-backup',
                          '--maintenance', '--execute', 'server shutdown'])
        restored = re.search(r'backup_id=(\d+)', output)
        if restored is None or int(restored.group(1)) != target:
            raise RuntimeError('restore did not confirm backup id ' + str(target))
    except Exception:
        # Restored tree stays as-is for inspection; nothing is started.
        raise
    media_saved = saved / 'media'
    media_new = database / 'media'
    if media_saved.is_dir():
        # Existing-directory semantics: the restore run leaves an empty media dir.
        shutil.copytree(media_saved, media_new, symlinks=True, dirs_exist_ok=True)
    execute(start_command)
    if check is not None and not check(base_url or local_url(config_path)):
        raise RuntimeError('client API did not become ready after restore')
    return {'status': 'complete', 'backup_id': target,
            'preserved': saved.name, 'service': 'started'}


def parse(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', type=Path, default=CONFIG)
    p.add_argument('--binary', default='tuwunel')
    p.add_argument('--stop-command', required=True, help='서비스 정지 명령 (예: systemctl stop …)')
    p.add_argument('--start-command', required=True, help='서비스 시작 명령 (예: systemctl start …)')
    p.add_argument('--backup-id', type=int, help='복원할 온라인 백업 id(기본: 최신)')
    p.add_argument('--skip-probe', action='store_true', help='재시작 후 client API 확인 생략')
    p.add_argument('--yes', action='store_true', help='데이터베이스 교체에 동의 (필수)')
    return p.parse_args(argv)


def main(argv=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    try:
        if not args.yes:
            raise ValueError('this drill replaces the database; pass --yes')
        record = drill(args.config, args.binary,
                       shlex.split(args.stop_command), shlex.split(args.start_command),
                       backup_id=args.backup_id,
                       check=None if args.skip_probe else probe)
        print(json.dumps(record))
        return 0
    except (OSError, ValueError, KeyError, RuntimeError) as e:
        # Error type and static text only; tokens and subprocess output stay out.
        print('restore drill failed: ' + str(e), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
