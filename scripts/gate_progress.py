#!/usr/bin/env python3
"""Daily gate progress record: conversation-event counts for the family room.

The stage-1 gate (#92) counts real family conversations; this tool records
the raw progress signal — m.room.message / m.room.encrypted events per sender
in one room, fetched with the admin-token client API. Decryption is
deliberately out of scope: the count is by sender, never content. One JSONL
history line is appended and latest.json rewritten under --state (0700,
owner-checked, like the backup state dir). With --notify-every N a threshold
crossing (floor(total/N) increase since the previous run) posts a one-line
notice to the admin room; the first run only records. A failed notice exits 1
without writing state, so the threshold is retried next run. Tokens, content
and room members never reach the output. The HTTP layer is injectable.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import urllib.parse
import urllib.request

from tuwunel_admin_room import AdminRoom
from tuwunel_config import load_admin_token, load_tuwunel_config

CONVERSATION_TYPES = ('m.room.message', 'm.room.encrypted')


def fetch_json(base, token, path):
    req = urllib.request.Request(base + path, headers={'Authorization': 'Bearer ' + token})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=30) as response:
        return json.load(response)


def count_room(base, token, room, fetch=fetch_json, page_limit=200):
    """Two single-page fetches (forward + backward); unique conversation counts.

    ``complete`` is true when the two windows overlap or the room-create event
    is in the union — the whole room then provably fits in one page. On this
    server the page cap is 40 events (limit is ignored above that), so a big
    room yields a newest-window lower bound with ``complete`` false.
    """
    quoted = urllib.parse.quote(room, safe='')
    path = '/_matrix/client/v3/rooms/' + quoted + '/messages?'
    forward = fetch(base, token, path + urllib.parse.urlencode({'dir': 'f', 'limit': page_limit}))
    backward = fetch(base, token, path + urllib.parse.urlencode({'dir': 'b', 'limit': page_limit}))
    events = {}
    for page in (forward, backward):
        for event in page.get('chunk', []):
            events[event.get('event_id')] = event
    total, by_sender, newest = 0, {}, 0
    for event in events.values():
        if event.get('type') in CONVERSATION_TYPES:
            total += 1
            sender = event.get('sender', '?')
            by_sender[sender] = by_sender.get(sender, 0) + 1
            newest = max(newest, int(event.get('origin_server_ts') or 0))
    complete = bool({e.get('event_id') for e in forward.get('chunk', [])}
                    & {e.get('event_id') for e in backward.get('chunk', [])}) \
        or any(e.get('type') == 'm.room.create' for e in events.values())
    return {'total': total, 'by_sender': by_sender, 'last_event_ms': newest, 'complete': complete}


def open_state(state):
    """Validate the state directory (0700, owned by us, no links)."""
    state.mkdir(mode=0o700, exist_ok=True)
    if state.is_symlink() or state.stat().st_uid != os.getuid() or state.stat().st_mode & 0o077:
        raise ValueError('untrusted gate state directory')
    return state


def previous_total(state):
    path = state / 'latest.json'
    if path.is_symlink() or not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding='utf-8')).get('total')
    except (OSError, ValueError):
        return None


def write_state(state, record):
    fd = os.open(state / 'latest.json', os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as out:
        os.fchmod(out.fileno(), 0o600)
        json.dump(record, out)
    fd = os.open(state / 'history.jsonl', os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as out:
        os.fchmod(out.fileno(), 0o600)
        out.write(json.dumps(record) + '\n')


def admin_notice(loaded, token):
    """One-way admin-room notice sender (closure keeps signatures small)."""
    room = AdminRoom(loaded['base'], loaded['server_name'], token)
    return room.notice


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', metavar='FILE', help='homeserver toml (default from tuwunel_config)')
    p.add_argument('--admin-token-file', metavar='FILE', help='admin token file (default from tuwunel_config)')
    p.add_argument('--room', metavar='ROOM_ID', help='family room id; defaults to $GATE_ROOM_ID')
    p.add_argument('--state', type=Path, default=Path('/var/lib/family-messenger-gate'), metavar='DIR')
    p.add_argument('--notify-every', type=int, default=0, metavar='N',
                   help='admin-room notice every N events (0 = off)')
    args = p.parse_args(argv)
    args.room = args.room or os.environ.get('GATE_ROOM_ID')
    if not args.room or not args.room.startswith('!'):
        p.error('a family room id is required (--room or $GATE_ROOM_ID)')
    if args.notify_every < 0:
        p.error('--notify-every must be >= 0')
    return args


def main(argv=None, fetch=count_room, notify=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        loaded = load_tuwunel_config(args.config)
        token = load_admin_token(args.admin_token_file)
        state = open_state(args.state)
        record = {'room': args.room, **count_room(loaded['base'], token, args.room, fetch), 'status': 'ok'}
        alert = 'off'
        if args.notify_every:
            previous = previous_total(state)
            if previous is None:
                alert = 'recorded'
            elif record['total'] // args.notify_every > previous // args.notify_every:
                send = notify or admin_notice(loaded, token)
                send('family gate progress: %d conversation events (previous %d)' % (record['total'], previous))
                alert = 'sent'
            else:
                alert = 'unchanged'
        record['notify'] = alert
        write_state(state, record)
        print(json.dumps(record))
        return 0
    except (OSError, ValueError, KeyError, RuntimeError) as e:
        print('gate progress failed: ' + type(e).__name__ + ': ' + str(e), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
