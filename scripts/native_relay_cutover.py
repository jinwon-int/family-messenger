#!/usr/bin/env python3
"""Semi-automatic cutover of the native-mls relay to THIS host (#440 stage 1).

Run on the host that is about to become active (standby → active, or the
original host on failback). Owner decisions baked in: B = semi-automatic (the
script never changes anything without ``--confirm <token>`` printed by its own
plan step), C = c1 (restore with ``--bump-seq``), A = no APNs on the standby.

Order of operations, each recorded in the state file:

1. probe    — peer relay over the tailnet AND the public edge through
              Cloudflare Access (service token, redirects are NOT followed:
              an Access login page is not a healthy relay). Only
              ``relay-down`` (both fail) allows a cutover; ``edge-only`` /
              ``peer-unreachable`` / ``healthy`` stop here (exit 10).
              ``--skip-probe`` is for drills into throwaway directories.
2. plan     — newest inbox snapshot (with its sidecar), manifest summary, and
              the confirm token = sha256 of the WHOLE plan (archive, host,
              hostnames, tunnel target, fence record, bump). Without a
              matching ``--confirm`` nothing is changed (exit 11).
3. peer snapshot (optional, PLAN run only — the confirm run never takes a
   new snapshot, so the token always names an archive the operator saw) /
   peer stop (optional). A peer stop that does not succeed is fatal unless
   ``--peer-unreachable-ok`` — a peer we could not stop may still be serving.
4. restore  — ``native_relay_restore.py`` into the live directories with
              ``--bump-seq`` (relay unit must be inactive here).
5. fence    — set the TXT fence record to this host and wait until a public
              resolver returns it on N consecutive reads (resolver PoPs keep
              the old answer for its TTL — pre-create the record with TTL 60).
6. re-probe — peer and edge again; if either answers 200 now, STOP. A peer
              that came back while we restored would be a second writer.
7. start    — ``systemctl start`` the relay, wait for local ``/v2/health``
              (judged by health within ``--start-wait``, not by one exit code:
              the unit's own ExecStartPre may read a stale answer once and
              ``Restart=on-failure`` retries).
8. dns      — point every relay hostname's CNAME at this host's tunnel.
9. edge     — wait for the edge probe to answer 200 through the new path.
10. hooks   — client re-pointing commands (bots, bridges); failures are
              recorded, exit 3.

The script stops at the first failing step and leaves what it did in place —
there is no automatic undo for a half cutover; the record says exactly where
it stopped. Tokens are read from files and never printed; hook output is
redacted for token-like strings before it is recorded.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import native_relay_fence as fence  # noqa: E402
import native_relay_restore as restore_module  # noqa: E402

CF_API = 'https://api.cloudflare.com/client/v4'
EXIT_NOT_DOWN = 10
EXIT_UNCONFIRMED = 11
EXIT_HOOKS = 3
EXIT_FAILED = 1
REDACT_HEADER = re.compile(r'(?i)((?:authorization|x-auth-key|x-api-key)\s*[:=]\s*)[^"\'\n]+')
REDACT_VALUE = re.compile(r'(?i)(bearer\s+|(?:--?[\w-]*(?:token|key|secret|pass|pwd)[\w-]*|'
                          r'[\w-]*(?:token|key|secret|password|passwd|pass|pwd))\s*[=:]?\s+?|'
                          r'[\w-]*(?:token|key|secret|password|passwd|pass|pwd)[\w-]*\s*[=:]\s*)\S+')
REDACT_USERINFO = re.compile(r'(://)[^/\s:@]+:[^/\s@]+@')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


def describe(exc):
    return type(exc).__name__ + ': ' + str(exc)[:400]


def redact(text):
    """Best-effort: headers, bearer/token/key/secret/password assignments and flags, URL userinfo.

    Hooks must not carry secrets in arguments at all (paths and host names only); this only limits the damage.
    """
    text = REDACT_HEADER.sub(lambda m: m.group(1) + '<redacted>', text or '')
    text = REDACT_USERINFO.sub(lambda m: m.group(1) + '<redacted>@', text)
    return REDACT_VALUE.sub(lambda m: m.group(1) + '<redacted>', text)


def read_kv_file(path):
    """KEY=VALUE lines (env-file style); values never leave this process."""
    values = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        values[key.strip()] = value.strip().strip('"')
    return values


def http_status(url, headers=None, timeout=5, opener=None):
    """HTTP status without following redirects (3xx is returned as-is); None on transport failure."""
    request = urllib.request.Request(url, headers=headers or {})
    try:
        with (opener or OPENER.open)(request, timeout=timeout) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except (urllib.error.URLError, OSError):
        return None


def edge_headers(token_file):
    if not token_file:
        return {}
    kv = read_kv_file(token_file)
    return {'CF-Access-Client-Id': kv.get('CF_ACCESS_CLIENT_ID', ''),
            'CF-Access-Client-Secret': kv.get('CF_ACCESS_CLIENT_SECRET', '')}


def classify(peer_ok, edge_ok):
    """edge_ok None = not probed → never 'relay-down' (an unknown edge is not a dead edge)."""
    if edge_ok is None:
        return 'edge-unknown'
    if not peer_ok and not edge_ok:
        return 'relay-down'
    if peer_ok and not edge_ok:
        return 'edge-only'
    if not peer_ok and edge_ok:
        return 'peer-unreachable'
    return 'healthy'


def probe(args, status=http_status, sleep=time.sleep, tries=None):
    """tries × (peer, edge); a path counts as OK if ANY try answered 200."""
    tries = tries or args.probe_tries
    headers = edge_headers(args.edge_token_file)
    samples = []
    for attempt in range(tries):
        peer = status(args.peer_health, timeout=args.probe_timeout)
        edge = status(args.edge_health, headers=headers, timeout=args.probe_timeout) if args.edge_health else None
        samples.append({'peer': peer, 'edge': edge})
        if attempt + 1 < tries:
            sleep(args.probe_interval)
    peer_ok = any(s['peer'] == 200 for s in samples)
    edge_ok = any(s['edge'] == 200 for s in samples) if args.edge_health else None
    return {'classification': classify(peer_ok, edge_ok), 'samples': samples}


def cf_request(token, method, path, body=None, opener=None):
    data = json.dumps(body).encode('utf-8') if body is not None else None
    request = urllib.request.Request(CF_API + path, data=data, method=method, headers={
        'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with (opener or urllib.request.urlopen)(request, timeout=20) as response:
            payload = json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        raise RuntimeError('cloudflare api ' + method + ' ' + path + ' -> ' + str(exc.code)) from None
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise RuntimeError('cloudflare api ' + method + ' ' + path + ' failed: ' + type(exc).__name__) from None
    if not isinstance(payload, dict) or not payload.get('success'):
        errors = payload.get('errors') if isinstance(payload, dict) else None
        raise RuntimeError('cloudflare api ' + method + ' ' + path + ' not successful: ' + json.dumps(errors)[:300])
    return payload.get('result')


def dns_find(token, zone, name, rtype, opener=None):
    path = '/zones/' + zone + '/dns_records?type=' + rtype + '&name=' + name
    result = cf_request(token, 'GET', path, opener=opener)
    if isinstance(result, list) and result and isinstance(result[0], dict) and 'id' in result[0]:
        return result[0]
    return None


def dns_upsert(token, zone, name, rtype, content, proxied, ttl=60, opener=None):
    """Create or update one record; returns (action, record id). TXT content is compared unquoted."""
    body = {'type': rtype, 'name': name, 'content': content, 'ttl': ttl, 'proxied': proxied}
    existing = dns_find(token, zone, name, rtype, opener=opener)
    if existing:
        same = str(existing.get('content', '')).strip('"') == content and bool(existing.get('proxied')) == proxied
        if same and existing.get('ttl') == ttl:
            return 'unchanged', existing['id']
        cf_request(token, 'PUT', '/zones/' + zone + '/dns_records/' + existing['id'], body, opener=opener)
        return 'updated', existing['id']
    created = cf_request(token, 'POST', '/zones/' + zone + '/dns_records', body, opener=opener)
    if not isinstance(created, dict) or 'id' not in created:
        raise RuntimeError('cloudflare api create returned no record id')
    return 'created', created['id']


def latest_archive(inbox):
    """Newest archive that already has its .sha256 sidecar (rsync lands the archive first)."""
    archives = sorted(p for p in Path(inbox).glob('relay-*.tar.gz') if p.with_suffix('.gz.sha256').is_file())
    if not archives:
        raise RuntimeError('no complete snapshot archive (with .sha256) in ' + str(inbox))
    return archives[-1]


def confirm_token(planned):
    """Bound to everything the cutover will do, not just the archive."""
    material = {k: planned[k] for k in ('to', 'archive', 'archive_sha256', 'hostnames', 'tunnel_target',
                                        'fence_record', 'bump_seq')}
    return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()[:16]


def run_cmd(command, timeout, runner=None):
    """Never raises: timeouts and missing binaries come back as exit None with an error string."""
    try:
        proc = (runner or subprocess.run)(shlex.split(command), capture_output=True, text=True, timeout=timeout,
                                          check=False)
    except subprocess.TimeoutExpired:
        return {'command': redact(command), 'exit': None, 'error': 'timeout after ' + str(timeout) + 's'}
    except (OSError, ValueError) as exc:
        return {'command': redact(command), 'exit': None, 'error': describe(exc)}
    return {'command': redact(command), 'exit': proc.returncode, 'stderr': redact((proc.stderr or '')[-300:])}


def wait_until(predicate, timeout, interval, sleep=time.sleep, clock=time.monotonic):
    deadline = clock() + timeout
    while True:
        result = predicate()
        if result:
            return result
        if clock() >= deadline:
            return None
        sleep(interval)


def plan(args):
    archive = latest_archive(args.inbox)
    summary = restore_module.restore(restore_module.parse(['--archive', str(archive), '--summary-only']))
    planned = {'to': args.to, 'archive': str(archive), 'archive_sha256': summary['archive_sha256'],
               'manifest': summary['manifest'], 'bump_seq': args.bump_seq, 'hostnames': sorted(args.hostname),
               'tunnel_target': args.tunnel_target, 'fence_record': args.fence_record}
    planned['confirm'] = confirm_token(planned)
    return planned


def restore_args(args, archive):
    argv = ['--archive', str(archive), '--target-data-dir', args.target_data_dir,
            '--target-policy-dir', args.target_policy_dir, '--bump-seq', str(args.bump_seq), '--unit', args.unit]
    for flag, value in (('--target-static-dir', args.target_static_dir), ('--target-hande-dir', args.target_hande_dir),
                        ('--owner', args.owner)):
        if value:
            argv += [flag, value]
    if args.skip_unit_check:
        argv.append('--skip-unit-check')
    return restore_module.parse(argv)


def cutover(args, io=None):
    """Execute the cutover; returns the record dict. ``io`` bundles injectable side effects for tests."""
    io = io or {}
    status = io.get('status', http_status)
    opener = io.get('opener')
    runner = io.get('runner')
    sleep = io.get('sleep', time.sleep)
    clock = io.get('clock', time.monotonic)
    fence_check = io.get('fence_check', fence.check)
    started = utcnow()
    record = {'to': args.to, 'started_at': started.isoformat(timespec='seconds'), 'steps': [], 'status': 'running'}

    def step(name, fn):
        try:
            detail = fn()
            record['steps'].append({'step': name, 'ok': True, 'detail': detail})
            return detail
        except Exception as exc:  # noqa: BLE001 — every failure is recorded, then re-raised to stop
            record['steps'].append({'step': name, 'ok': False, 'error': describe(exc)})
            raise

    def probe_now(tries):
        return probe(args, status=status, sleep=sleep, tries=tries)

    try:
        if args.skip_probe:
            record['probe'] = {'classification': 'skipped'}
        else:
            record['probe'] = step('probe', lambda: probe_now(args.probe_tries))
            if record['probe']['classification'] != 'relay-down':
                record['status'] = 'not-down:' + record['probe']['classification']
                return record
        if args.peer_snapshot_cmd and not args.confirm and not args.dry_run:
            # Plan run only: the archive the operator confirms is the one that will be restored. The confirm run
            # never takes another snapshot, so a token can never point at an archive nobody looked at.
            step('peer_snapshot', lambda: run_cmd(args.peer_snapshot_cmd, 300, runner))
        planned = step('plan', lambda: plan(args))
        record['plan'] = planned
        if args.dry_run:
            record['status'] = 'dry-run'
            return record
        if args.confirm != planned['confirm']:
            record['status'] = 'unconfirmed'
            return record

        if args.peer_stop_cmd:
            def do_peer_stop():
                result = run_cmd(args.peer_stop_cmd, 120, runner)
                if result['exit'] != 0 and not args.peer_unreachable_ok:
                    raise RuntimeError('peer stop did not succeed (' + str(result.get('error') or result.get('stderr'))
                                       + '); a peer we could not stop may still be serving — '
                                       're-run with --peer-unreachable-ok only if the peer host is known dead')
                return result
            step('peer_stop', do_peer_stop)

        def do_restore():
            result = restore_module.restore(restore_args(args, planned['archive']), runner=runner)
            if not result['counts_match']:
                raise RuntimeError('restored counts do not match the manifest')
            return {'snapshot_id': result['snapshot_id'], 'rooms': result['rooms'],
                    'moved_aside': result['moved_aside']}
        step('restore', do_restore)

        dns_token = read_kv_file(args.cf_dns_token_file).get('CF_DNS_TOKEN') if args.cf_dns_token_file else None
        if not dns_token:
            raise RuntimeError('CF_DNS_TOKEN missing in ' + str(args.cf_dns_token_file))

        def do_fence():
            action, _ = dns_upsert(dns_token, args.cf_zone_id, args.fence_record, 'TXT', args.to, False,
                                   opener=opener)
            streak = {'n': 0}

            def settled():
                streak['n'] = streak['n'] + 1 if fence_check(args.to, args.fence_record)[0] == 0 else 0
                return streak['n'] >= args.fence_settle or None
            seen = wait_until(settled, args.fence_wait, 5, sleep=sleep, clock=clock)
            if not seen:
                raise RuntimeError('fence record did not resolve to ' + args.to + ' on ' + str(args.fence_settle)
                                   + ' consecutive reads within ' + str(args.fence_wait) + 's')
            return {'action': action, 'consecutive_reads': args.fence_settle}
        step('fence', do_fence)

        if not args.skip_probe:
            def do_reprobe():
                result = probe_now(1)
                if any(s['peer'] == 200 or s['edge'] == 200 for s in result['samples']):
                    raise RuntimeError('peer or edge answered 200 after the fence moved — a second writer '
                                       'would start; stop the peer relay and re-run from the fence step')
                return result
            step('reprobe', do_reprobe)

        def do_start():
            # A non-zero exit here is usually the unit's own ExecStartPre fence reading a stale answer;
            # Restart=on-failure retries in 30 s, so judge by local health within --start-wait, not by one exit code.
            result = run_cmd('systemctl start ' + args.unit, 60, runner)
            ok = wait_until(lambda: status(args.local_health, timeout=3) == 200 or None, args.start_wait, 2,
                            sleep=sleep, clock=clock)
            if not ok:
                raise RuntimeError('local /v2/health not 200 within ' + str(args.start_wait)
                                   + 's (systemctl start exit ' + str(result['exit']) + ': '
                                   + str(result.get('error') or result.get('stderr')) + ')')
            return {'health': 200, 'start_exit': result['exit']}
        step('start', do_start)

        def do_dns():
            changes = {}
            for host in planned['hostnames']:
                action, _ = dns_upsert(dns_token, args.cf_zone_id, host, 'CNAME', args.tunnel_target, True,
                                       opener=opener)
                changes[host] = action
            return changes
        step('dns', do_dns)

        if args.edge_health:
            headers = edge_headers(args.edge_token_file)

            def do_edge():
                ok = wait_until(lambda: status(args.edge_health, headers=headers, timeout=5) == 200 or None,
                                args.edge_wait, 10, sleep=sleep, clock=clock)
                if not ok:
                    raise RuntimeError('edge probe not 200 within ' + str(args.edge_wait) + 's')
                return {'health': 200}
            step('edge', do_edge)

        hook_failures = 0
        for command in args.client_hook:
            result = run_cmd(command, 120, runner)
            record['steps'].append({'step': 'client_hook', 'ok': result['exit'] == 0, 'detail': result})
            hook_failures += 0 if result['exit'] == 0 else 1
        record['status'] = 'complete' if not hook_failures else 'complete-with-hook-failures'
        return record
    except Exception as exc:  # noqa: BLE001
        record['status'] = 'failed'
        record['error'] = describe(exc)
        return record
    finally:
        record['finished_at'] = utcnow().isoformat(timespec='seconds')
        if args.state:
            write_record(args.state, record)


def write_record(state_dir, record):
    state = Path(state_dir)
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = record['started_at'].replace('+00:00', 'Z').replace(':', '')
    path = state / ('cutover-' + stamp + '.json')
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    os.chmod(path, 0o600)
    return path


class ArgFileParser(argparse.ArgumentParser):
    """@file: one argument per line; blank lines and '#' comments ignored; surrounding whitespace/CRLF stripped."""

    def convert_arg_line_to_args(self, arg_line):
        line = arg_line.strip()
        if not line or line.startswith('#'):
            return []
        return [line]


def parse(argv=None):
    parser = ArgFileParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                           fromfile_prefix_chars='@')
    parser.add_argument('--to', required=True, help='this host name as written in the fence record')
    parser.add_argument('--fence-record', required=True)
    parser.add_argument('--peer-health', required=True, help='peer relay /v2/health over the tailnet')
    parser.add_argument('--edge-health', help='public relay /v2/health through Cloudflare Access (required to probe)')
    parser.add_argument('--edge-token-file', help='CF_ACCESS_CLIENT_ID/SECRET file for --edge-health (never printed)')
    parser.add_argument('--probe-tries', type=int, default=3)
    parser.add_argument('--probe-interval', type=float, default=60.0)
    parser.add_argument('--probe-timeout', type=float, default=5.0)
    parser.add_argument('--skip-probe', action='store_true', help='drills: do not require relay-down (no re-probe)')
    parser.add_argument('--inbox', required=True, help='received snapshots directory')
    parser.add_argument('--target-data-dir', required=True)
    parser.add_argument('--target-policy-dir', required=True)
    parser.add_argument('--target-static-dir')
    parser.add_argument('--target-hande-dir')
    parser.add_argument('--bump-seq', type=int, default=1000, help='#440-C c1 (owner default 1000)')
    parser.add_argument('--owner', default='native-relay')
    parser.add_argument('--unit', default='native-relay')
    parser.add_argument('--skip-unit-check', action='store_true', help='drills into throwaway directories only')
    parser.add_argument('--local-health', default='http://127.0.0.1:18921/v2/health')
    parser.add_argument('--start-wait', type=float, default=120.0,
                        help='local health deadline; covers one Restart=on-failure cycle of the unit')
    parser.add_argument('--cf-zone-id')
    parser.add_argument('--cf-dns-token-file', help='file with CF_DNS_TOKEN=… (DNS edit scope only)')
    parser.add_argument('--hostname', action='append', default=[], help='relay hostname to re-point (repeatable)')
    parser.add_argument('--tunnel-target', help='<tunnel-id>.cfargotunnel.com of THIS host')
    parser.add_argument('--fence-wait', type=float, default=300.0,
                        help='resolver TTL window (pre-create the TXT with TTL 60)')
    parser.add_argument('--fence-settle', type=int, default=3, help='consecutive matching fence reads required')
    parser.add_argument('--edge-wait', type=float, default=180.0)
    parser.add_argument('--peer-snapshot-cmd',
                        help='PLAN run only: make the peer take one last snapshot before the plan is printed')
    parser.add_argument('--peer-stop-cmd',
                        help='stop the peer relay first; failure is fatal unless --peer-unreachable-ok')
    parser.add_argument('--peer-unreachable-ok', action='store_true',
                        help='the peer HOST is known dead (not just unreachable)')
    parser.add_argument('--client-hook', action='append', default=[], help='re-point bots/bridges (repeatable)')
    parser.add_argument('--state', help='record directory (default: <inbox>/../state)')
    parser.add_argument('--dry-run', action='store_true', help='probe + plan only, change nothing')
    parser.add_argument('--probe-only', action='store_true', help='print the probe classification and exit')
    parser.add_argument('--confirm', help='token printed by the plan step (semi-automatic gate)')
    args = parser.parse_args(argv)
    if not args.state:
        args.state = str(Path(args.inbox).parent / 'state')
    if args.probe_tries < 1:
        parser.error('--probe-tries must be >= 1')
    if not args.skip_probe and not args.edge_health:
        parser.error('--edge-health is required to probe (tailnet-only evidence cannot prove the relay is down); '
                     'use --skip-probe only for drills')
    if not (args.dry_run or args.probe_only):
        for name in ('cf_zone_id', 'cf_dns_token_file', 'tunnel_target'):
            if not getattr(args, name):
                parser.error('--' + name.replace('_', '-') + ' is required for a real cutover')
        if not args.hostname:
            parser.error('--hostname is required for a real cutover')
    return args


def main(argv=None):
    args = parse(argv)
    if args.probe_only:
        result = probe(args)
        print(json.dumps(result))
        return 0 if result['classification'] == 'relay-down' else EXIT_NOT_DOWN
    record = cutover(args)
    print(json.dumps(record, indent=2, sort_keys=True))
    status = record['status']
    if status.startswith('not-down'):
        return EXIT_NOT_DOWN
    if status == 'unconfirmed':
        print('\nre-run with --confirm ' + record['plan']['confirm'] + ' to execute the plan above', file=sys.stderr)
        return EXIT_UNCONFIRMED
    if status in ('dry-run', 'complete'):
        return 0
    if status == 'complete-with-hook-failures':
        return EXIT_HOOKS
    return EXIT_FAILED


if __name__ == '__main__':
    sys.exit(main())
