#!/usr/bin/env python3
"""Off-host homeserver watchdog (#412 plan A): probes the homeserver from ANOTHER node.

2026-10-18: the hosting provider hypervisor-rebooted the homeserver host for 12 minutes.
The public endpoint answered Cloudflare 530 and every bridge restart-looped, yet nobody
was alerted, because the existing ``family-messenger-health`` timer runs ON the homeserver
host and reports through the homeserver itself. This script runs on a different node
(the dual-channel one, whose Telegram bridge still delivers while Matrix is down) and
never depends on the homeserver for its own alert path.

Two independent probes per run, each with a short timeout and no shelling out:

* external — ``GET <homeserver-url>/_matrix/client/versions`` through the public edge
  (Cloudflare). Up only for a 2xx answer whose JSON carries a ``versions`` key; the
  HTTP status (including Cloudflare 5xx such as 530) is recorded either way.
* host — a plain TCP connect to ``<host>:<port>`` over the private network (e.g. the
  Tailscale address, port 22). Reachable or not; nothing is sent.

Classification: both up -> ``up``; external down + host up -> ``edge`` (tunnel /
Cloudflare / tuwunel-only problem); host down -> ``host_down`` (whatever the edge says).

Debounce: a state becomes *confirmed* only after ``--threshold`` consecutive identical
observations (default 3; with a 1-minute timer that is a <=3-minute detection delay).
The JSON state file (``--state``) keeps the recent observations, the confirmed state and
when it began, the last alert time per state, and a pending alert to retry.

Alerts are ccc push-spool records (``--push-spool``), one JSON file each, written
atomically; the node's bridge delivers them. Codes: ``homeserver_down`` (into
host_down), ``homeserver_edge`` (into edge), ``homeserver_recovered`` (back to up).
While a bad state persists the same code is re-sent every ``--realert-hours``
(default 6). The very first confirmation of ``up`` after install is silent.

Exit status: 0 whenever the run itself worked (whatever the homeserver state);
1 on I/O failure (state file, spool record), 2 on usage errors. The probe functions
and the clock are injectable for tests; no secrets are read or written.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import socket
import sys
import time
import urllib.error
import urllib.request

from push_spool import write_spool_record

DEFAULT_HOMESERVER_URL = 'https://matrix.seoyoon-family.com'
DEFAULT_STATE = '/var/lib/family-messenger-watchdog/state.json'
VERSIONS_PATH = '/_matrix/client/versions'
# Cloudflare answers 403 to the default Python-urllib UA (measured 2026-09-16, see health_check.py).
GET_HEADERS = {'User-Agent': 'family-messenger-watchdog/1'}
MAX_BODY = 65536
MAX_TEXT = 400

UP, EDGE, HOST_DOWN = 'up', 'edge', 'host_down'
STATES = (UP, EDGE, HOST_DOWN)
BAD_STATES = (EDGE, HOST_DOWN)
ALERT_CODES = {HOST_DOWN: 'homeserver_down', EDGE: 'homeserver_edge', UP: 'homeserver_recovered'}
STATE_VERSION = 1


# --- probes -------------------------------------------------------------------------

def probe_external(url, timeout):
    """GET <url>/_matrix/client/versions via the public edge; never raises.

    Returns ``{'ok', 'http', 'detail'}``: ok only for 2xx + JSON ``versions`` key.
    ``http`` is the status code (Cloudflare 5xx included) or None when no HTTP answer
    came back (DNS, TCP, TLS, timeout).
    """
    req = urllib.request.Request(url.rstrip('/') + VERSIONS_PATH, method='GET', headers=GET_HEADERS)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as response:
            status = response.status
            body = response.read(MAX_BODY)
    except urllib.error.HTTPError as e:
        return {'ok': False, 'http': e.code, 'detail': 'HTTP %d' % e.code}
    except (OSError, ValueError) as e:  # URLError/timeout are OSError; ValueError = bad URL
        return {'ok': False, 'http': None, 'detail': 'error: ' + type(e).__name__}
    try:
        data = json.loads(body)
        has_versions = isinstance(data, dict) and 'versions' in data
    except ValueError:
        has_versions = False
    ok = 200 <= status < 300 and has_versions
    return {'ok': ok, 'http': status, 'detail': 'HTTP %d%s' % (status, '' if has_versions else ' (no versions key)')}


def probe_host(host, port, timeout):
    """TCP connect to host:port over the private network; never raises, sends nothing."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
    except OSError as e:
        return {'ok': False, 'detail': 'tcp/%d %s' % (port, type(e).__name__)}
    return {'ok': True, 'detail': 'tcp/%d connect ok' % port}


def classify(external_ok, host_ok):
    if not host_ok:
        return HOST_DOWN
    return UP if external_ok else EDGE


# --- state file ---------------------------------------------------------------------

def read_state(path):
    """The previous state dict, or {} (missing, symlink, unreadable, malformed, not an object)."""
    if path.is_symlink() or not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_state(path, state):
    """0600 JSON state file under a private (0700) directory, written atomically."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError('untrusted watchdog state file path')
    if path.parent.is_symlink() or path.parent.stat().st_mode & 0o077:
        raise ValueError('untrusted watchdog state directory')
    tmp = path.with_name('.' + path.name + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w') as out:
            os.fchmod(out.fileno(), 0o600)
            json.dump(state, out)
            out.flush()
            os.fsync(out.fileno())
        os.rename(tmp, path)
    except BaseException:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


# --- decision -----------------------------------------------------------------------

def _number(value, default):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else default


def advance(prev, candidate, now, threshold, realert_seconds):
    """Pure state step: (new_state_dict, alert) where alert is None or {'code', 'kind'}.

    * ``transition``: the last ``threshold`` observations all equal ``candidate`` and it
      differs from the confirmed state. Into edge/host_down -> alert; back to up ->
      recovered alert, except when nothing was confirmed before (fresh install).
    * ``realert``: the confirmed state is bad and the last alert for it is older than
      ``realert_seconds``.
    * ``retry``: a previous spool write failed; resend only while the code still matches
      the confirmed state (a stale pending alert is dropped).
    """
    confirmed = prev.get('state') if prev.get('state') in STATES else None
    since = _number(prev.get('since'), now)
    raw_alerts = prev.get('last_alert') if isinstance(prev.get('last_alert'), dict) else {}
    last_alert = {k: _number(v, None) for k, v in raw_alerts.items() if k in STATES}
    last_alert = {k: v for k, v in last_alert.items() if v is not None}
    observations = [o for o in (prev.get('observations') or []) if isinstance(o, dict) and o.get('state') in STATES]
    observations = observations[-(threshold - 1):] if threshold > 1 else []
    observations.append({'ts': now, 'state': candidate})
    streak = 0
    for obs in reversed(observations):
        if obs['state'] != candidate:
            break
        streak += 1
    transition = streak >= threshold and candidate != confirmed
    alert = None
    previous_state, previous_since = confirmed, since
    if transition:
        since = _number(observations[-threshold]['ts'], now)
        if candidate in BAD_STATES or confirmed is not None:
            alert = {'code': ALERT_CODES[candidate], 'kind': 'transition'}
        confirmed = candidate
    elif confirmed in BAD_STATES:
        last = last_alert.get(confirmed)
        if last is not None and now - last >= realert_seconds:
            alert = {'code': ALERT_CODES[confirmed], 'kind': 'realert'}
    pending = prev.get('pending') if isinstance(prev.get('pending'), str) else None
    if alert is None and pending and confirmed is not None and pending == ALERT_CODES[confirmed]:
        alert = {'code': pending, 'kind': 'retry'}
    if alert is not None:
        alert.update({'state': confirmed, 'since': since, 'previous_state': previous_state,
                      'previous_since': previous_since})
    state = {'version': STATE_VERSION, 'state': confirmed, 'since': since, 'observations': observations,
             'streak': streak, 'last_alert': last_alert, 'pending': None, 'updated': now,
             'candidate': candidate, 'transition': transition}
    return state, alert


# --- alert text and record ----------------------------------------------------------

def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def human_duration(seconds):
    seconds = max(0.0, float(seconds))
    if seconds >= 3600:
        return '%.1fh' % (seconds / 3600)
    if seconds >= 60:
        return '%.0fm' % (seconds / 60)
    return '%.0fs' % seconds


def alert_text(node, alert, now, external, host, threshold):
    """One line for the owner; host addresses and secrets never appear in it."""
    head = 'homeserver watchdog [%s]: ' % node
    state = alert['state']
    if state == UP:
        was = alert.get('previous_state') or 'down'
        # Outage length = from the first bad observation to the first good one (the recovery streak start).
        outage = _number(alert.get('since'), now) - _number(alert.get('previous_since'), now)
        body = 'RECOVERED — external %s, private host reachable (was %s for %s)' % (
            external['detail'], was, human_duration(outage))
    elif state == HOST_DOWN:
        body = 'HOST DOWN — private host probe failed (%s), external %s' % (host['detail'], external['detail'])
    else:
        body = ('EDGE DOWN — private host reachable but external GET %s failed (%s): '
                'check Cloudflare tunnel / tuwunel' % (VERSIONS_PATH, external['detail']))
    if alert['kind'] == 'transition':
        body += '; %d/%d consecutive probes, since %s' % (threshold, threshold, iso(alert['since']))
    elif state != UP:
        body += '; still %s for %s (since %s)' % (state, human_duration(now - alert['since']), iso(alert['since']))
    return (head + body)[:MAX_TEXT]


def spool_alert(spool, node, alert, text, now):
    """Write one push-spool record for ``alert``; returns the file name."""
    code = alert['code']
    marker = 'transition' if alert['kind'] == 'transition' else str(int(now))
    record = {'version': 1, 'event': 'health-alert', 'code': code, 'kind': alert['kind'],
              'node': node, 'recipient': 'owner', 'ts': iso(now), 'status': alert['state'],
              'text': text,
              'dedup': 'homeserver-watchdog:%s:%d:%s' % (code, int(alert['since']), marker)}
    name = 'health-alert-%s-%d.json' % (code, int(now * 1000))
    return write_spool_record(spool, name, record)


# --- run ----------------------------------------------------------------------------

def run(args, now, external, host):
    """One cycle after the probes: debounce, alert, persist. Returns (summary, exit_code)."""
    candidate = classify(external['ok'], host['ok'])
    path = Path(args.state)
    prev = read_state(path)
    state, alert = advance(prev, candidate, now, args.threshold, args.realert_hours * 3600)
    state['last'] = {'external': external, 'host': host}
    summary = {'state': state['state'], 'candidate': candidate, 'streak': state['streak'],
               'threshold': args.threshold, 'transition': state['transition'],
               'since': state['since'], 'external': external, 'host': host, 'updated': now, 'alert': 'none'}
    code = 0
    if alert is not None:
        text = alert_text(args.push_node, alert, now, external, host, args.threshold)
        summary['text'] = text
        if args.push_spool:
            try:
                summary['record'] = spool_alert(args.push_spool, args.push_node, alert, text, now)
                summary['alert'] = '%s:%s' % (alert['kind'], alert['code'])
                state['last_alert'][alert['state']] = now
            except (OSError, ValueError) as e:
                summary['alert'] = 'failed: ' + type(e).__name__
                state['pending'] = alert['code']
                code = 1
        else:
            summary['alert'] = 'unspooled:%s:%s' % (alert['kind'], alert['code'])
            state['last_alert'][alert['state']] = now
    write_state(path, state)
    return summary, code


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--homeserver-url', default=DEFAULT_HOMESERVER_URL, metavar='URL',
                   help='public base URL probed at /_matrix/client/versions (default %(default)s)')
    p.add_argument('--host', required=True, metavar='HOST',
                   help='homeserver host address on the private network (e.g. its Tailscale IP)')
    p.add_argument('--host-port', type=int, default=22, metavar='PORT', help='TCP port for the host probe (default 22)')
    p.add_argument('--timeout', type=float, default=10.0, metavar='S', help='per-probe timeout in seconds (default 10)')
    p.add_argument('--threshold', type=int, default=3, metavar='N',
                   help='consecutive identical observations that confirm a state (default 3)')
    p.add_argument('--realert-hours', type=float, default=6.0, metavar='H',
                   help='repeat the alert every H hours while edge/host_down persists (default 6)')
    p.add_argument('--state', default=DEFAULT_STATE, metavar='FILE', help='JSON state file (default %(default)s)')
    p.add_argument('--push-spool', metavar='DIR',
                   help='ccc push spool directory; alerts are written there as health-alert records')
    p.add_argument('--push-node', default=socket.gethostname().split('.')[0], metavar='NAME',
                   help='node label in the alert (default: short hostname)')
    p.add_argument('--once', action='store_true', help='run one probe cycle and exit (the only mode; default)')
    p.add_argument('--json', action='store_true', help='print the run summary as one JSON line')
    args = p.parse_args(argv)
    if not args.host.strip():
        p.error('--host must not be empty')
    if not (args.homeserver_url.startswith('https://') or args.homeserver_url.startswith('http://')):
        p.error('--homeserver-url must be an http(s) URL')
    if args.threshold < 1:
        p.error('--threshold must be >= 1')
    if args.realert_hours <= 0:
        p.error('--realert-hours must be positive')
    if args.timeout <= 0:
        p.error('--timeout must be positive')
    if not 0 < args.host_port < 65536:
        p.error('--host-port must be 1..65535')
    return args


def main(argv=None, external_fn=probe_external, host_fn=probe_host, clock=time.time):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    now = clock()
    external = external_fn(args.homeserver_url, args.timeout)
    host = host_fn(args.host, args.host_port, args.timeout)
    try:
        summary, code = run(args, now, external, host)
    except (OSError, ValueError) as e:
        print('homeserver watchdog failed: ' + type(e).__name__ + ': ' + str(e), file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(summary))
    else:
        print('%s (candidate %s %d/%d) external=%s host=%s alert=%s' % (
            summary['state'], summary['candidate'], summary['streak'], summary['threshold'],
            external['detail'], host['detail'], summary['alert']))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
