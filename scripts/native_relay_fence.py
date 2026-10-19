#!/usr/bin/env python3
"""Single-writer fence for the native-mls relay (#440 stage 1).

Exactly one host may run ``native-relay`` at a time: the relay is a single
SQLite writer and every room's epoch/seq must stay monotonic, so two live
relays would fork the MLS state. The fence is a public DNS TXT record
(``_native-relay-active.<domain>``) whose content is the name of the host that
is allowed to serve. Both hosts carry this script in two roles:

* ``ExecStartPre`` of the relay unit (start side): exit 0 = this host is
  active, 1 = another host is named, 2 = the record could not be read. Any
  failure to read is a refusal (fail-closed): a host that cannot prove it is
  the active one does not start the relay.
* a one-minute timer with ``--stop-unit native-relay`` (stop side): when the
  record positively names ANOTHER host (exit 1) on ``--stop-after`` consecutive
  runs (default 3 > a 60 s TTL), the unit is stopped, so a relay that was
  already running when the fence moved — e.g. the old host rebooting after a
  cutover — loses. One stale resolver answer right after a cutover must not
  stop the host that just started. A lookup failure (exit 2) does NOT stop a
  running relay: a DoH outage must not take the active host down. The watch
  run itself exits 0 unless a stop it attempted failed.

The record is read over DNS-over-HTTPS from a public resolver (Cloudflare by
default) so a stale local cache cannot answer. Empty names and empty TXT
values are refused: an unset ``FENCE_SELF`` must never match an empty record.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_RESOLVER = 'https://cloudflare-dns.com/dns-query'
TXT = 16


def read_txt(record, resolver=DEFAULT_RESOLVER, timeout=5, opener=None):
    """Return the TXT strings of record (list), or raise RuntimeError on any lookup failure."""
    url = resolver + '?' + urllib.parse.urlencode({'name': record, 'type': 'TXT'})
    request = urllib.request.Request(url, headers={'accept': 'application/dns-json'})
    try:
        with (opener or urllib.request.urlopen)(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode('utf-8'))
        if payload.get('Status') != 0:
            raise RuntimeError('fence lookup status ' + str(payload.get('Status')))
        values = []
        for answer in payload.get('Answer') or []:
            if answer.get('type') == TXT:
                values.append(str(answer.get('data', '')).strip().strip('"'))
    except (urllib.error.URLError, OSError, ValueError, AttributeError, TypeError, KeyError) as exc:
        raise RuntimeError('fence lookup failed: ' + repr(exc)) from None
    if not values:
        raise RuntimeError('fence record has no TXT answer: ' + record)
    return values


def active_host(record, **kwargs):
    """The single host named by the record; more than one value or an empty value is a refusal."""
    values = read_txt(record, **kwargs)
    if len(values) != 1:
        raise RuntimeError('fence record is ambiguous: ' + ', '.join(values))
    if not values[0]:
        raise RuntimeError('fence record is empty')
    return values[0]


def check(expect, record, **kwargs):
    """Return (exit_code, message): 0 active here, 1 another host named, 2 unreadable."""
    if not expect or not expect.strip():
        return 2, 'fence: --expect must not be empty'
    try:
        active = active_host(record, **kwargs)
    except RuntimeError as exc:
        return 2, str(exc)
    if active == expect:
        return 0, 'fence: ' + expect + ' is active'
    return 1, 'fence: active host is ' + active + ', not ' + expect


def update_streak(path, code):
    """Consecutive exit-1 readings persisted across timer runs; anything else resets to 0."""
    streak = 0
    try:
        streak = int(json.loads(Path(path).read_text()).get('streak', 0))
    except (OSError, ValueError, AttributeError, TypeError):
        streak = 0
    streak = streak + 1 if code == 1 else 0
    try:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(json.dumps({'streak': streak, 'last_code': code}) + '\n')
    except OSError:
        pass
    return streak


def unit_active(unit, runner=None):
    proc = (runner or subprocess.run)(['systemctl', 'is-active', unit], capture_output=True, text=True, check=False)
    return (proc.stdout or '').strip() in ('active', 'activating', 'reloading')


def stop_if_fenced_out(code, unit, streak=1, stop_after=1, runner=None):
    """Stop side: only a positive 'another host is active' (1), seen stop_after times in a row, stops the unit.

    A single stale resolver answer right after a cutover must not stop the host that just started serving
    (public resolvers keep the old TXT for its TTL); 2 (unreadable) never stops anything. Returns None when
    nothing was done, otherwise {'stopped', 'exit'} — exit 0 also when the unit was already inactive.
    """
    if code != 1 or streak < stop_after:
        return None
    if not unit_active(unit, runner):
        return {'stopped': unit, 'exit': 0, 'already_inactive': True}
    proc = (runner or subprocess.run)(['systemctl', 'stop', unit], capture_output=True, text=True, check=False)
    return {'stopped': unit, 'exit': proc.returncode}


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--expect', required=True, help='this host name as written in the TXT record')
    parser.add_argument('--record', required=True, help='fence record FQDN, e.g. _native-relay-active.example.test')
    parser.add_argument('--resolver', default=DEFAULT_RESOLVER, help='DoH endpoint (application/dns-json)')
    parser.add_argument('--timeout', type=float, default=5.0)
    parser.add_argument('--stop-unit', help='stop side: stop this unit when another host is named (exit 1 only)')
    parser.add_argument('--stop-after', type=int, default=3,
                        help='consecutive exit-1 timer runs before stopping (> resolver TTL in minutes)')
    parser.add_argument('--streak-file', default='/var/lib/native-relay/fence-watch.json')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse(argv)
    code, message = check(args.expect, args.record, resolver=args.resolver, timeout=args.timeout)
    print(message, file=sys.stderr if code else sys.stdout)
    if args.stop_unit:
        streak = update_streak(args.streak_file, code)
        action = stop_if_fenced_out(code, args.stop_unit, streak, args.stop_after)
        if action:
            print('fence: stopped ' + args.stop_unit + ' (exit ' + str(action['exit']) + ', streak ' + str(streak)
                  + ')', file=sys.stderr)
        elif code == 1:
            print('fence: streak ' + str(streak) + '/' + str(args.stop_after) + ' before stopping', file=sys.stderr)
        # the watch unit "fails" only when a stop it attempted failed — the standby's normal state is exit 0
        return 3 if action and action['exit'] else 0
    return code


if __name__ == '__main__':
    sys.exit(main())
