#!/usr/bin/env python3
"""Semi-automatic cutover of the native-mls relay to THIS host (#440 stage 1).

Run on the host that is about to become active (standby → active, or the
original host on failback). Owner decisions baked in: B = semi-automatic (the
script never changes anything without ``--confirm <token>`` printed by its own
plan step), C = c1 (restore with ``--bump-seq``), A = no APNs on the standby.

Order of operations, each recorded in the state file:

1. probe   — peer relay over the tailnet AND the public edge through
             Cloudflare Access (service token). Only ``relay-down`` (both
             fail) allows a cutover; ``edge-only`` / ``peer-unreachable`` /
             ``healthy`` stop here (exit 10). ``--skip-probe`` is for drills.
2. plan    — newest inbox snapshot, its manifest summary, the confirm token.
             Without a matching ``--confirm`` nothing is changed (exit 11).
3. peer snapshot / peer stop (optional, best effort — planned moves only).
4. restore — ``native_relay_restore.py`` into the live directories with
             ``--bump-seq`` (relay unit must be inactive here).
5. fence   — set the TXT fence record to this host and wait until a public
             resolver returns it (the relay's ExecStartPre reads the same).
6. start   — ``systemctl start`` the relay, wait for local ``/v2/health``.
7. dns     — point every relay hostname's CNAME at this host's tunnel.
8. edge    — wait for the edge probe to answer 200 through the new path.
9. hooks   — client re-pointing commands (bots, bridges); failures are
             recorded, not fatal.

The script stops at the first failing step and leaves what it did in place —
there is no automatic undo for a half cutover; the record says exactly where
it stopped. Tokens are read from files and never printed.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
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
EXIT_FAILED = 1


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


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
    request = urllib.request.Request(url, headers=headers or {})
    try:
        with (opener or urllib.request.urlopen)(request, timeout=timeout) as response:
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
    if not peer_ok and not edge_ok:
        return 'relay-down'
    if peer_ok and not edge_ok:
        return 'edge-only'
    if not peer_ok and edge_ok:
        return 'peer-unreachable'
    return 'healthy'


def probe(args, status=http_status, sleep=time.sleep):
    """tries × (peer, edge); a path counts as OK if ANY try answered 200."""
    headers = edge_headers(args.edge_token_file)
    samples = []
    for attempt in range(args.probe_tries):
        peer = status(args.peer_health, timeout=args.probe_timeout)
        edge = status(args.edge_health, headers=headers, timeout=args.probe_timeout) if args.edge_health else None
        samples.append({'peer': peer, 'edge': edge})
        if attempt + 1 < args.probe_tries:
            sleep(args.probe_interval)
    peer_ok = any(s['peer'] == 200 for s in samples)
    edge_ok = any(s['edge'] == 200 for s in samples)
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
        raise RuntimeError('cloudflare api ' + method + ' ' + path + ' failed: ' + str(exc)) from None
    if not payload.get('success'):
        raise RuntimeError('cloudflare api ' + method + ' ' + path + ' not successful: '
                           + json.dumps(payload.get('errors'))[:300])
    return payload.get('result')


def dns_find(token, zone, name, rtype, opener=None):
    path = '/zones/' + zone + '/dns_records?type=' + rtype + '&name=' + name
    result = cf_request(token, 'GET', path, opener=opener)
    return result[0] if result else None


def dns_upsert(token, zone, name, rtype, content, proxied, ttl=60, opener=None):
    """Create or update one record; returns (action, record id)."""
    body = {'type': rtype, 'name': name, 'content': content, 'ttl': ttl, 'proxied': proxied}
    existing = dns_find(token, zone, name, rtype, opener=opener)
    if existing:
        if existing.get('content') == content and bool(existing.get('proxied')) == proxied:
            return 'unchanged', existing['id']
        cf_request(token, 'PUT', '/zones/' + zone + '/dns_records/' + existing['id'], body, opener=opener)
        return 'updated', existing['id']
    created = cf_request(token, 'POST', '/zones/' + zone + '/dns_records', body, opener=opener)
    return 'created', created['id']


def latest_archive(inbox):
    archives = sorted(Path(inbox).glob('relay-*.tar.gz'))
    if not archives:
        raise RuntimeError('no snapshot archive in ' + str(inbox))
    return archives[-1]


def confirm_token(to, archive, digest):
    return hashlib.sha256((to + '|' + Path(archive).name + '|' + digest).encode()).hexdigest()[:12]


def run_cmd(command, timeout, runner=None):
    proc = (runner or subprocess.run)(shlex.split(command), capture_output=True, text=True, timeout=timeout,
                                      check=False)
    return {'command': command, 'exit': proc.returncode, 'stderr': (proc.stderr or '')[-300:]}


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
    token = confirm_token(args.to, archive, summary['archive_sha256'])
    return {'archive': str(archive), 'archive_sha256': summary['archive_sha256'], 'manifest': summary['manifest'],
            'confirm': token, 'bump_seq': args.bump_seq, 'hostnames': args.hostname,
            'tunnel_target': args.tunnel_target,
            'fence_record': args.fence_record, 'to': args.to}


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
            record['steps'].append({'step': name, 'ok': False, 'error': str(exc)[:500]})
            raise

    try:
        if args.skip_probe:
            record['probe'] = {'classification': 'skipped'}
        else:
            record['probe'] = step('probe', lambda: probe(args, status=status, sleep=sleep))
            if record['probe']['classification'] != 'relay-down':
                record['status'] = 'not-down:' + record['probe']['classification']
                return record
        planned = step('plan', lambda: plan(args))
        record['plan'] = planned
        if args.dry_run:
            record['status'] = 'dry-run'
            return record
        if args.confirm != planned['confirm']:
            record['status'] = 'unconfirmed'
            return record

        if args.peer_snapshot_cmd:
            step('peer_snapshot', lambda: run_cmd(args.peer_snapshot_cmd, 300, runner))
            planned = step('replan', lambda: plan(args))
            record['plan'] = planned
        if args.peer_stop_cmd:
            step('peer_stop', lambda: run_cmd(args.peer_stop_cmd, 120, runner))

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
            seen = wait_until(lambda: fence_check(args.to, args.fence_record)[0] == 0 or None,
                              args.fence_wait, 5, sleep=sleep, clock=clock)
            if not seen:
                raise RuntimeError('fence record did not resolve to ' + args.to + ' within '
                                   + str(args.fence_wait) + 's')
            return {'action': action}
        step('fence', do_fence)

        def do_start():
            result = run_cmd('systemctl start ' + args.unit, 60, runner)
            if result['exit']:
                raise RuntimeError('systemctl start failed: ' + result['stderr'])
            ok = wait_until(lambda: status(args.local_health, timeout=3) == 200 or None, args.start_wait, 1,
                            sleep=sleep, clock=clock)
            if not ok:
                raise RuntimeError('local /v2/health not 200 within ' + str(args.start_wait) + 's')
            return {'health': 200}
        step('start', do_start)

        def do_dns():
            changes = {}
            for host in args.hostname:
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
            hook_failures += 1 if result['exit'] else 0
        record['status'] = 'complete' if not hook_failures else 'complete-with-hook-failures'
        return record
    except Exception as exc:  # noqa: BLE001
        record['status'] = 'failed'
        record['error'] = str(exc)[:500]
        return record
    finally:
        record['finished_at'] = utcnow().isoformat(timespec='seconds')
        if args.state:
            write_record(args.state, record)


def write_record(state_dir, record):
    state = Path(state_dir)
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    name = 'cutover-' + record['started_at'].replace(':', '').replace('+00:00', 'Z') + '.json'
    path = state / name
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    os.chmod(path, 0o600)
    return path


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--to', required=True, help='this host name as written in the fence record')
    parser.add_argument('--fence-record', required=True)
    parser.add_argument('--peer-health', required=True, help='peer relay /v2/health over the tailnet')
    parser.add_argument('--edge-health', help='public relay /v2/health through Cloudflare Access')
    parser.add_argument('--edge-token-file', help='CF_ACCESS_CLIENT_ID/SECRET file for --edge-health (never printed)')
    parser.add_argument('--probe-tries', type=int, default=3)
    parser.add_argument('--probe-interval', type=float, default=60.0)
    parser.add_argument('--probe-timeout', type=float, default=5.0)
    parser.add_argument('--skip-probe', action='store_true', help='drills: do not require relay-down')
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
    parser.add_argument('--start-wait', type=float, default=30.0)
    parser.add_argument('--cf-zone-id')
    parser.add_argument('--cf-dns-token-file', help='file with CF_DNS_TOKEN=… (DNS edit scope only)')
    parser.add_argument('--hostname', action='append', default=[], help='relay hostname to re-point (repeatable)')
    parser.add_argument('--tunnel-target', help='<tunnel-id>.cfargotunnel.com of THIS host')
    parser.add_argument('--fence-wait', type=float, default=120.0)
    parser.add_argument('--edge-wait', type=float, default=180.0)
    parser.add_argument('--peer-snapshot-cmd', help='best-effort: make the peer take one last snapshot first')
    parser.add_argument('--peer-stop-cmd', help='best-effort: stop the peer relay first (planned moves)')
    parser.add_argument('--client-hook', action='append', default=[], help='re-point bots/bridges (repeatable)')
    parser.add_argument('--state', help='record directory (default: <inbox>/../state)')
    parser.add_argument('--dry-run', action='store_true', help='probe + plan only, change nothing')
    parser.add_argument('--probe-only', action='store_true', help='print the probe classification and exit')
    parser.add_argument('--confirm', help='token printed by the plan step (semi-automatic gate)')
    args = parser.parse_args(argv)
    if not args.state:
        args.state = str(Path(args.inbox).parent / 'state')
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
        print('\nre-run with --confirm ' + record['plan']['confirm'] + ' to execute the cutover above', file=sys.stderr)
        return EXIT_UNCONFIRMED
    if status in ('dry-run', 'complete'):
        return 0
    return EXIT_FAILED


if __name__ == '__main__':
    sys.exit(main())
