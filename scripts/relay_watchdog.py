#!/usr/bin/env python3
"""Off-host native-relay watchdog (#426, sibling of homeserver_watchdog.py #412 A).

Once agent chat moves to 「한데」 the native relay is a single point of failure for both
agent and family chat, so it needs the same kind of watchdog as the homeserver: one that
does not depend on the relay for its own alert path ("the relay is down" cannot be
announced through the relay).

Two independent probes per run, each with a short timeout and no shelling out:

* direct — ``GET <direct-url>/v2/health`` over the private network (the relay's tailnet
  address and port, the same path the node bots use). Up only for HTTP 200 whose JSON is
  ``{"ok": true}``.
* edge — ``GET <edge-url>/v2/health`` through the public edge (Cloudflare tunnel +
  Access, the path the owner apps use). Redirects are never followed.

  - With ``--access-env FILE`` (a 0600 env file carrying ``CF_ACCESS_CLIENT_ID`` and
    ``CF_ACCESS_CLIENT_SECRET``, the same keys as the bot service-token files) the probe
    passes Access and must see the relay's own ``200 {"ok": true}`` -- this verifies the
    tunnel end to end.
  - Without it, Access answers before the origin, so ``3xx``/``401``/``403`` only prove
    the edge is alive (mode ``edge-only``); a dead tunnel behind Access is then NOT
    detected. ``5xx`` (e.g. Cloudflare 530/502) or no HTTP answer is down in both modes.

Classification: direct down -> ``relay_down`` (relay process or its host; whatever the
edge says); direct up + edge down -> ``edge`` (tunnel / Cloudflare only; node bots keep
working, owner apps do not); both up -> ``up``.

Debounce, state file, re-alert and retry semantics are the homeserver watchdog's
(``advance``/``read_state``/``write_state`` are shared): ``--threshold`` consecutive
identical observations confirm a state (default 3, i.e. <=3 minutes on a 1-minute
timer), a bad state is re-alerted every ``--realert-hours`` (default 6), a failed spool
write is retried while the state still matches, and the first ``up`` after install is
silent. Alerts are ccc push-spool ``health-alert`` records with codes ``relay_down``,
``relay_edge`` and ``relay_recovered``; the node's bridge delivers them.

Exit status: 0 whenever the run itself worked (whatever the relay state); 1 on I/O
failure (state file, spool record, unreadable access env), 2 on usage errors. Secret
values are read only to build request headers; they are never printed, logged or stored.
"""
import argparse
import json
from pathlib import Path
import socket
import sys
import time
import urllib.error
import urllib.request

import homeserver_watchdog as hw
from push_spool import write_spool_record

DEFAULT_STATE = '/var/lib/family-messenger-watchdog/relay-state.json'
HEALTH_PATH = '/v2/health'
GET_HEADERS = {'User-Agent': 'family-messenger-watchdog/1'}
MAX_BODY = 4096
MAX_TEXT = hw.MAX_TEXT

UP, EDGE, RELAY_DOWN = hw.UP, hw.EDGE, hw.HOST_DOWN
STATE_LABEL = {UP: 'up', EDGE: 'edge', RELAY_DOWN: 'relay_down'}
ALERT_CODES = {RELAY_DOWN: 'relay_down', EDGE: 'relay_edge', UP: 'relay_recovered'}
# Answers from Cloudflare Access itself (no origin involved): the edge is alive.
ACCESS_EDGE_STATUSES = (301, 302, 303, 307, 308, 401, 403)
ACCESS_KEYS = ('CF_ACCESS_CLIENT_ID', 'CF_ACCESS_CLIENT_SECRET')


# --- access env ---------------------------------------------------------------------

def read_access_env(path):
    """``{'CF-Access-Client-Id': .., 'CF-Access-Client-Secret': ..}`` from a KEY=VALUE file.

    Raises ValueError when the file is a symlink, readable by group/other, or lacks
    either key; OSError when unreadable. Messages never contain the values.
    """
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('access env file missing or not a regular file')
    if path.stat().st_mode & 0o077:
        raise ValueError('access env file must not be group/other accessible (chmod 600)')
    values = {}
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        key = key.strip()
        if key.startswith('export '):
            key = key[len('export '):].strip()
        if key in ACCESS_KEYS:
            values[key] = value.strip().strip('"').strip("'")
    missing = [k for k in ACCESS_KEYS if not values.get(k)]
    if missing:
        raise ValueError('access env file lacks ' + ', '.join(missing))
    return {'CF-Access-Client-Id': values['CF_ACCESS_CLIENT_ID'],
            'CF-Access-Client-Secret': values['CF_ACCESS_CLIENT_SECRET']}


# --- probes -------------------------------------------------------------------------

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # surface 3xx as HTTPError instead of following it


def _get(url, timeout, headers):
    """(status, body_or_None, error_name_or_None); never raises."""
    req = urllib.request.Request(url, method='GET', headers=dict(GET_HEADERS, **headers))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    try:
        with opener.open(req, timeout=timeout) as response:
            return response.status, response.read(MAX_BODY), None
    except urllib.error.HTTPError as e:
        return e.code, None, None
    except (OSError, ValueError) as e:  # URLError/timeout are OSError; ValueError = bad URL
        return None, None, type(e).__name__


def _health_ok(status, body):
    if status != 200 or body is None:
        return False
    try:
        data = json.loads(body)
    except ValueError:
        return False
    return isinstance(data, dict) and data.get('ok') is True


def probe_direct(base_url, timeout):
    """GET <base>/v2/health on the private network; ok only for 200 {"ok": true}."""
    status, body, err = _get(base_url.rstrip('/') + HEALTH_PATH, timeout, {})
    if status is None:
        return {'ok': False, 'http': None, 'detail': 'direct error: ' + err}
    ok = _health_ok(status, body)
    suffix = '' if ok or status != 200 else ' (not ok)'
    return {'ok': ok, 'http': status, 'detail': 'direct HTTP %d%s' % (status, suffix)}


def probe_edge(base_url, timeout, access_headers=None):
    """GET <base>/v2/health through the public edge; see the module docstring for modes."""
    authed = bool(access_headers)
    status, body, err = _get(base_url.rstrip('/') + HEALTH_PATH, timeout, access_headers or {})
    mode = 'authed' if authed else 'edge-only'
    if status is None:
        return {'ok': False, 'http': None, 'mode': mode, 'detail': 'edge error: ' + err}
    if authed:
        ok = _health_ok(status, body)
    else:
        ok = _health_ok(status, body) or status in ACCESS_EDGE_STATUSES
    return {'ok': ok, 'http': status, 'mode': mode, 'detail': 'edge HTTP %d (%s)' % (status, mode)}


def classify(direct_ok, edge_ok):
    if not direct_ok:
        return RELAY_DOWN
    return UP if edge_ok else EDGE


# --- alert text and record ----------------------------------------------------------

def alert_text(node, alert, now, direct, edge, threshold):
    """One line for the owner; addresses and secrets never appear in it."""
    head = 'relay watchdog [%s]: ' % node
    state = alert['state']
    if state == UP:
        was = STATE_LABEL.get(alert.get('previous_state'), 'down')
        outage = hw._number(alert.get('since'), now) - hw._number(alert.get('previous_since'), now)
        body = 'RECOVERED — %s, %s (was %s for %s)' % (
            direct['detail'], edge['detail'], was, hw.human_duration(outage))
    elif state == RELAY_DOWN:
        body = ('RELAY DOWN — private /v2/health failed (%s), %s: agent bots and apps are cut off'
                % (direct['detail'], edge['detail']))
    else:
        body = ('EDGE DOWN — relay healthy on the private network but %s: check the Cloudflare '
                'tunnel / Access (node bots unaffected, owner apps cut off)' % edge['detail'])
    if alert['kind'] == 'transition':
        body += '; %d/%d consecutive probes, since %s' % (threshold, threshold, hw.iso(alert['since']))
    elif state != UP:
        body += '; still %s for %s (since %s)' % (
            STATE_LABEL[state], hw.human_duration(now - alert['since']), hw.iso(alert['since']))
    return (head + body)[:MAX_TEXT]


def spool_alert(spool, node, alert, text, now):
    code = alert['code']
    marker = 'transition' if alert['kind'] == 'transition' else str(int(now))
    record = {'version': 1, 'event': 'health-alert', 'code': code, 'kind': alert['kind'],
              'node': node, 'recipient': 'owner', 'ts': hw.iso(now), 'status': STATE_LABEL[alert['state']],
              'text': text,
              'dedup': 'relay-watchdog:%s:%d:%s' % (code, int(alert['since']), marker)}
    name = 'health-alert-%s-%d.json' % (code, int(now * 1000))
    return write_spool_record(spool, name, record)


# --- run ----------------------------------------------------------------------------

def run(args, now, direct, edge):
    """One cycle after the probes: debounce, alert, persist. Returns (summary, exit_code)."""
    candidate = classify(direct['ok'], edge['ok'])
    path = Path(args.state)
    prev = hw.read_state(path)
    state, alert = hw.advance(prev, candidate, now, args.threshold, args.realert_hours * 3600,
                              alert_codes=ALERT_CODES)
    state['last'] = {'direct': direct, 'edge': edge}
    summary = {'state': STATE_LABEL.get(state['state']), 'candidate': STATE_LABEL[candidate],
               'streak': state['streak'], 'threshold': args.threshold, 'transition': state['transition'],
               'since': state['since'], 'direct': direct, 'edge': edge, 'updated': now, 'alert': 'none'}
    code = 0
    if alert is not None:
        text = alert_text(args.push_node, alert, now, direct, edge, args.threshold)
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
    hw.write_state(path, state)
    return summary, code


def _http_url(p, value, flag):
    if not (value.startswith('https://') or value.startswith('http://')):
        p.error('%s must be an http(s) URL' % flag)


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--direct-url', required=True, metavar='URL',
                   help='relay base URL on the private network, e.g. http://<tailnet-ip>:<port>')
    p.add_argument('--edge-url', required=True, metavar='URL',
                   help='public relay base URL behind Cloudflare, e.g. https://hande.example.com')
    p.add_argument('--access-env', metavar='FILE',
                   help='0600 env file with CF_ACCESS_CLIENT_ID/CF_ACCESS_CLIENT_SECRET (end-to-end edge probe)')
    p.add_argument('--timeout', type=float, default=10.0, metavar='S', help='per-probe timeout in seconds (default 10)')
    p.add_argument('--threshold', type=int, default=3, metavar='N',
                   help='consecutive identical observations that confirm a state (default 3)')
    p.add_argument('--realert-hours', type=float, default=6.0, metavar='H',
                   help='repeat the alert every H hours while edge/relay_down persists (default 6)')
    p.add_argument('--state', default=DEFAULT_STATE, metavar='FILE', help='JSON state file (default %(default)s)')
    p.add_argument('--push-spool', metavar='DIR',
                   help='ccc push spool directory; alerts are written there as health-alert records')
    p.add_argument('--push-node', default=socket.gethostname().split('.')[0], metavar='NAME',
                   help='node label in the alert (default: short hostname)')
    p.add_argument('--once', action='store_true', help='run one probe cycle and exit (the only mode; default)')
    p.add_argument('--json', action='store_true', help='print the run summary as one JSON line')
    args = p.parse_args(argv)
    _http_url(p, args.direct_url, '--direct-url')
    _http_url(p, args.edge_url, '--edge-url')
    if args.threshold < 1:
        p.error('--threshold must be >= 1')
    if args.realert_hours <= 0:
        p.error('--realert-hours must be positive')
    if args.timeout <= 0:
        p.error('--timeout must be positive')
    return args


def main(argv=None, direct_fn=probe_direct, edge_fn=probe_edge, clock=time.time):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        access = read_access_env(args.access_env) if args.access_env else None
    except (OSError, ValueError) as e:
        print('relay watchdog failed: access env: ' + type(e).__name__ + ': ' + str(e), file=sys.stderr)
        return 1
    now = clock()
    direct = direct_fn(args.direct_url, args.timeout)
    edge = edge_fn(args.edge_url, args.timeout, access)
    try:
        summary, code = run(args, now, direct, edge)
    except (OSError, ValueError) as e:
        print('relay watchdog failed: ' + type(e).__name__ + ': ' + str(e), file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(summary))
    else:
        print('%s (candidate %s %d/%d) %s %s alert=%s' % (
            summary['state'], summary['candidate'], summary['streak'], summary['threshold'],
            direct['detail'], edge['detail'], summary['alert']))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
