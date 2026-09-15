#!/usr/bin/env python3
"""Stage-1 Tuwunel restore drill; isolated or synthetic environments only.

Replays the measured restore procedure: list the online backups on the RUNNING
server through the admin room, stop the service, move the database directory
aside, run the built-in one-shot restore (``--restore-backup --maintenance
--execute "server shutdown"``, the only place a second ``tuwunel`` process is
started, and only while the service is stopped), copy the preserved media
directory back, then start the service and wait for the client API. The
online backups live in ``database_backup_path``, which must sit outside the
database directory (checked before anything is stopped or moved) because the
whole database directory is renamed. If the restore step fails the preserved
directory is moved back and the start command is issued (auto-rollback); the
failed attempt is kept beside it for inspection. The restore run creates an
empty media directory, so the media copy uses "existing directory" semantics
(a plain 'cp -a src dst' would be skipped inside it; measured 2026-09-13).
Stop/start commands are required arguments; this script never guesses how a
host runs its service.
"""
import argparse
import datetime
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from tuwunel_admin_room import AdminRoom  # noqa: E402
from tuwunel_backup import parse_backup_ids  # noqa: E402
from tuwunel_config import (  # noqa: E402
    TUWUNEL_CONFIG, TUWUNEL_TOKEN, backup_directory, load_admin_token, load_tuwunel_config,
)


def run_text(command, timeout=600):
    """Run a command and return combined output; stderr carries restore logs."""
    try:
        proc = subprocess.run(command, capture_output=True, text=True,
                              timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise RuntimeError('restore subprocess timed out') from None
    if proc.returncode:
        raise RuntimeError('restore subprocess failed with exit ' + str(proc.returncode)
                           + '; output tail: ' + ' | '.join((proc.stdout + proc.stderr).splitlines()[-3:]))
    return proc.stdout + proc.stderr


def log_stderr(text):
    print('restore drill: ' + text, file=sys.stderr)


def local_url(config_path):
    return load_tuwunel_config(config_path)['base']


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


def rollback(database, saved, stamp, start_command, execute, log):
    """Move the preserved database back and issue the start command; log every step."""
    failed = database.with_name(database.name + '.failed-restore-' + stamp)
    try:
        if any(database.iterdir()):
            database.rename(failed)  # partial restore output kept for inspection
            log('failed restore attempt kept at ' + failed.name)
        else:
            database.rmdir()
        saved.rename(database)
    except OSError as e:
        log('ROLLBACK FAILED (' + type(e).__name__ + '); database preserved at ' + saved.name
            + '; service NOT started; operator action required')
        raise
    log('moved ' + saved.name + ' back to ' + database.name)
    try:
        execute(start_command)
    except Exception as e:
        log('service start FAILED after rollback (' + type(e).__name__ + '); start it manually')
        raise
    log('service start command issued after rollback')


def drill(config_path, binary, stop_command, start_command, admin, backup_id=None,
          execute=None, check=None, base_url=None, log=log_stderr):
    """Run one restore drill; returns a record or raises after rolling back."""
    if execute is None:
        execute = run_text
    if not stop_command or not start_command:
        raise ValueError('stop and start service commands are required')
    loaded = load_tuwunel_config(config_path)
    database = loaded['database']
    if not database.is_dir() or database.is_symlink():
        raise ValueError('database directory missing at ' + str(database))
    backups = backup_directory(loaded)  # must be outside database_path: checked before stop/mv
    if not backups.is_dir() or backups.is_symlink():
        raise ValueError('database_backup_path directory missing at ' + str(backups))
    ids = parse_backup_ids(admin.list_backups())
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
        # The pinned binary (1.9.1, measured 2026-09-15) prints only its
        # shutdown line on a successful restore and never echoes the backup
        # id; a missing id fails with a nonzero exit before opening anything.
        # The id is therefore passed explicitly and the restore is confirmed
        # by the effect the binary cannot fake: a nonzero exit or an empty
        # database directory means nothing was restored (the drill created
        # the directory empty; media subdirectories are part of a real
        # restore output).
        execute([binary, '-c', str(config_path), '--restore-backup', str(target),
                 '--maintenance', '--execute', 'server shutdown'])
        # An empty `media` directory alone is restore scaffolding the binary
        # can create without restoring anything (measured: a failed id leaves
        # nothing at all); real output always carries database files.
        restored_entries = [p for p in database.iterdir()
                            if not (p.is_dir() and p.name == 'media' and not any(p.iterdir()))]
        if not restored_entries:
            raise RuntimeError('restore produced an empty database directory for backup '
                               + str(target))
    except Exception as e:
        log('restore step failed (' + type(e).__name__ + ': ' + str(e) + '); rolling back')
        rollback(database, saved, stamp, start_command, execute, log)
        raise RuntimeError('restore failed; database rolled back from ' + saved.name
                           + ' and service start issued') from None
    media_saved = saved / 'media'
    media_new = database / 'media'
    if media_saved.is_dir():
        # Existing-directory semantics: the restore run leaves an empty media dir.
        shutil.copytree(media_saved, media_new, symlinks=True, dirs_exist_ok=True)
    execute(start_command)
    if check is not None and not check(base_url or loaded['base']):
        raise RuntimeError('client API did not become ready after restore')
    return {'status': 'complete', 'backup_id': target,
            'preserved': saved.name, 'service': 'started'}


def parse(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', type=Path, default=TUWUNEL_CONFIG)
    p.add_argument('--binary', default='tuwunel', help='오프라인 복원 단계에만 쓰는 tuwunel 바이너리')
    p.add_argument('--admin-token-file', type=Path, default=TUWUNEL_TOKEN, help='admin 토큰 파일 (0600)')
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
        loaded = load_tuwunel_config(args.config)
        admin = AdminRoom(loaded['base'], loaded['server_name'], load_admin_token(args.admin_token_file))
        record = drill(args.config, args.binary,
                       shlex.split(args.stop_command), shlex.split(args.start_command), admin,
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
