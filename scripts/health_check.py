#!/usr/bin/env python3
"""Stage-1 operations health check for the family messenger plane (timer-run, read-only).

Probe set for a systemd timer: homeserver client API URLs, required systemd units,
freshness of the newest COMPLETE paired-backup record written by tuwunel_backup.py,
and (bot node) freshness of the fleet_matrix sync loop's meta.health mark. One line
of JSON goes to stdout; exit 0 healthy, 1 unhealthy. With --alert-admin a notice is
sent to the homeserver's admin room ONLY on a healthy<->unhealthy transition, tracked
in a 0600 state file, so an hourly timer does not spam the room. A failed notice is
recorded, never raised. Secrets and message content never reach the output; the HTTP
function, unit runner, sqlite opener and clock are injectable for tests.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import time
import urllib.error
import urllib.request

from tuwunel_admin_room import AdminRoom
from tuwunel_config import load_admin_token, load_tuwunel_config

MAX_DETAIL = 400  # notice length guard; details are static phrases and paths, never content


GET_HEADERS = {'User-Agent': 'family-messenger-health/1'}


def fetch(url):
    """GET a URL and return the HTTP status code; no redirects, no proxy, 10s timeout.

    The custom User-Agent matters: Cloudflare answers 403 to the default
    Python-urllib UA on the tunnel (measured 2026-09-16 from the bot node),
    which would make every remote probe report the homeserver as down.
    """
    req = urllib.request.Request(url, method='GET', headers=GET_HEADERS)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=10) as response:
            return response.status
    except urllib.error.HTTPError as e:
        return e.code


def run_unit(name):
    """Return systemctl is-active output (stripped); injectable in tests."""
    import subprocess
    return subprocess.run(['systemctl', 'is-active', name], capture_output=True, text=True).stdout.strip()


def newest_complete_record(state_dir):
    """Newest complete tuwunel-*.json record: (pair, created_at datetime UTC) or None.

    Failed runs never write a record json, so unparseable or incomplete files are
    skipped rather than treated as freshness; the newest complete pair decides.
    """
    candidates = sorted(state_dir.glob('tuwunel-*.json')) if state_dir.is_dir() else []
    for path in reversed(candidates):
        if path.is_symlink():
            continue
        try:
            record = json.loads(path.read_text(encoding='utf-8'))
            created = datetime.datetime.strptime(record['created_at'], '%Y%m%dT%H%M%SZ').replace(
                tzinfo=datetime.timezone.utc)
            if record.get('status') == 'complete':
                return record.get('pair', path.stem), created
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return None


def bot_health_age(db_path, now):
    """Seconds since the bot's last meta.health mark; raises when unreadable or not ready."""
    info = db_path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('bot state is not a regular file')
    db = sqlite3.connect('file:' + str(db_path) + '?mode=ro', uri=True, timeout=2)
    try:
        row = db.execute("SELECT value FROM meta WHERE key='health'").fetchone()
    finally:
        db.close()
    if row is None:
        raise ValueError('bot state has no health mark')
    mark = json.loads(row[0])
    if mark.get('state') != 'ready':
        raise ValueError('bot health state is ' + str(mark.get('state')))
    updated = mark.get('updated')
    if not isinstance(updated, (int, float)):
        raise ValueError('bot health mark has no timestamp')
    return now - updated


def transition_alert(args, failed_names, unhealthy, now):
    """Send an admin-room notice on a status change; 'sent'/'failed'/'unchanged'/'recorded'.

    The first run only records the baseline: a fresh install must not alert-storm
    the admin room with a status it has never seen.
    """
    path = Path(args.state_file)
    previous = None
    if path.is_file() and not path.is_symlink():
        try:
            previous = json.loads(path.read_text(encoding='utf-8')).get('status')
        except (OSError, ValueError):
            previous = None
    status = 'unhealthy' if unhealthy else 'healthy'
    if previous == status:
        return 'unchanged'
    text = None
    if previous is not None:
        text = ('family messenger health: ' + ('UNHEALTHY — ' + ', '.join(failed_names)
                if unhealthy else 'recovered — all checks pass'))
        try:
            loaded = load_tuwunel_config(args.config)
            room = AdminRoom(loaded['base'], loaded['server_name'], load_admin_token(args.admin_token_file))
            room.notice(text[:MAX_DETAIL])
        except (OSError, ValueError, KeyError, RuntimeError):
            write_state(path, status, now)
            return 'failed'
    write_state(path, status, now)
    return 'sent' if text else 'recorded'


def write_state(path, status, now):
    path.parent.mkdir(mode=0o700, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError('untrusted health state file path')
    if path.parent.is_symlink() or path.parent.stat().st_mode & 0o077:
        raise ValueError('untrusted health state directory')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as out:
        os.fchmod(out.fileno(), 0o600)
        json.dump({'status': status, 'updated': now}, out)


def run_checks(args, now, fetch_fn, unit_fn):
    checks = []
    for url in args.url:
        try:
            code = fetch_fn(url)
            checks.append({'name': 'url ' + url, 'ok': code == 200, 'detail': 'HTTP ' + str(code)})
        except OSError as e:
            checks.append({'name': 'url ' + url, 'ok': False, 'detail': 'error: ' + type(e).__name__})
    for unit in args.require_active:
        state = unit_fn(unit)
        checks.append({'name': 'unit ' + unit, 'ok': state == 'active', 'detail': state or 'no output'})
    if args.backup_state:
        record = newest_complete_record(Path(args.backup_state))
        if record is None:
            checks.append({'name': 'backup-freshness', 'ok': False, 'detail': 'no complete backup record'})
        else:
            pair, created = record
            age_h = (now - created.timestamp()) / 3600
            ok = age_h <= args.max_backup_age_hours
            checks.append({'name': 'backup-freshness', 'ok': ok,
                           'detail': 'pair %s %.1fh old (max %.0fh)' % (pair, age_h, args.max_backup_age_hours)})
    if args.bot_state:
        try:
            age_s = bot_health_age(Path(args.bot_state), now)
            ok = age_s <= args.max_bot_age_seconds
            checks.append({'name': 'bot-freshness', 'ok': ok,
                           'detail': 'ready, %.0fs old (max %.0fs)' % (age_s, args.max_bot_age_seconds)})
        except (OSError, ValueError, KeyError, TypeError, sqlite3.Error) as e:
            checks.append({'name': 'bot-freshness', 'ok': False, 'detail': type(e).__name__ + ': ' + str(e)})
    return checks


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--url', action='append', default=[], metavar='URL',
                   help='client API URL that must answer HTTP 200 (repeatable)')
    p.add_argument('--require-active', action='append', default=[], metavar='UNIT',
                   help='systemd unit that must be active (repeatable)')
    p.add_argument('--backup-state', metavar='DIR', help='tuwunel_backup.py record directory to watch')
    p.add_argument('--max-backup-age-hours', type=float, default=26.0, metavar='H')
    p.add_argument('--bot-state', metavar='FILE', help='fleet_matrix inbox sqlite with meta.health')
    p.add_argument('--max-bot-age-seconds', type=float, default=600.0, metavar='S')
    p.add_argument('--alert-admin', action='store_true', help='notify the admin room on status transitions')
    p.add_argument('--config', metavar='FILE', help='homeserver toml for --alert-admin')
    p.add_argument('--admin-token-file', metavar='FILE', help='admin token file for --alert-admin')
    p.add_argument('--state-file', metavar='FILE', help='0600 transition state file for --alert-admin')
    args = p.parse_args(argv)
    if not (args.url or args.require_active or args.backup_state or args.bot_state):
        p.error('at least one of --url, --require-active, --backup-state, --bot-state is required')
    if args.alert_admin and not (args.config and args.admin_token_file and args.state_file):
        p.error('--alert-admin requires --config, --admin-token-file and --state-file')
    return args


def main(argv=None, fetch_fn=fetch, unit_fn=run_unit, clock=time.time):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    now = clock()
    checks = run_checks(args, now, fetch_fn, unit_fn)
    unhealthy = any(not c['ok'] for c in checks)
    result = {'status': 'unhealthy' if unhealthy else 'healthy', 'updated': now, 'checks': checks}
    if args.alert_admin:
        failed_names = [c['name'] for c in checks if not c['ok']]
        try:
            result['alert'] = transition_alert(args, failed_names, unhealthy, now)
        except (OSError, ValueError) as e:
            result['alert'] = 'failed: ' + type(e).__name__
    print(json.dumps(result))
    return 1 if unhealthy else 0


if __name__ == '__main__':
    raise SystemExit(main())
