#!/usr/bin/env python3
"""Single-writer fence for the native-mls relay (#440 stage 1).

Exactly one host may run ``native-relay`` at a time: the relay is a single
SQLite writer and every room's epoch/seq must stay monotonic, so two live
relays would fork the MLS state. The fence is a public DNS TXT record
(``_native-relay-active.<domain>``) whose content is the name of the host that
is allowed to serve. Both hosts carry this script as ``ExecStartPre`` of the
relay unit and as the snapshot timer's ``--fence`` gate.

The record is read over DNS-over-HTTPS from a public resolver (Cloudflare by
default) so a stale local cache cannot answer. Any failure to read the record
is a refusal (exit 2, fail-closed): a host that cannot prove it is the active
one does not start the relay. Exit 0 = this host is active, 1 = another host
is active (the record names it), 2 = the record could not be read.
"""
import argparse
import json
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
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise RuntimeError('fence lookup failed: ' + str(exc)) from None
    if payload.get('Status') != 0:
        raise RuntimeError('fence lookup status ' + str(payload.get('Status')))
    values = []
    for answer in payload.get('Answer') or []:
        if answer.get('type') == TXT:
            values.append(str(answer.get('data', '')).strip().strip('"'))
    if not values:
        raise RuntimeError('fence record has no TXT answer: ' + record)
    return values


def active_host(record, **kwargs):
    """The single host named by the record; more than one value is a refusal (ambiguous fence)."""
    values = read_txt(record, **kwargs)
    if len(values) != 1:
        raise RuntimeError('fence record is ambiguous: ' + ', '.join(values))
    return values[0]


def check(expect, record, **kwargs):
    """Return (exit_code, message)."""
    try:
        active = active_host(record, **kwargs)
    except RuntimeError as exc:
        return 2, str(exc)
    if active == expect:
        return 0, 'fence: ' + expect + ' is active'
    return 1, 'fence: active host is ' + active + ', not ' + expect


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--expect', required=True, help='this host name as written in the TXT record')
    parser.add_argument('--record', required=True, help='fence record FQDN, e.g. _native-relay-active.example.test')
    parser.add_argument('--resolver', default=DEFAULT_RESOLVER, help='DoH endpoint (application/dns-json)')
    parser.add_argument('--timeout', type=float, default=5.0)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse(argv)
    code, message = check(args.expect, args.record, resolver=args.resolver, timeout=args.timeout)
    print(message, file=sys.stderr if code else sys.stdout)
    return code


if __name__ == '__main__':
    sys.exit(main())
