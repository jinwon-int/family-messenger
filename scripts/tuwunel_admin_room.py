#!/usr/bin/env python3
"""Admin-room transport: run Tuwunel server commands on the RUNNING instance.

A second ``tuwunel --execute`` process cannot open the live RocksDB (LOCK
error, measured 2026-09-13), and with the server stopped it would start a
full server instead. The supported online path is the admin room: with the
admin token, resolve ``#admins:<server_name>``, post ``!admin server ...`` as
an ordinary ``m.room.message`` and read the server user's reply from
``/messages`` within a bounded time. Every reply is checked for the phrase the
command is expected to produce; anything else fails closed. The HTTP function,
clock and sleep are injectable for tests. Tokens never reach error messages.
"""
import json
import secrets
import time
import urllib.error
import urllib.request
from urllib.parse import quote, urlencode, urlsplit

LOOPBACK = ('127.0.0.1', 'localhost', '::1')


class AdminRoom:
    """Sends ``!admin`` commands to the admin room and returns the server's reply body."""

    def __init__(self, base, server_name, token, http=None, server_user=None,
                 timeout=180.0, interval=1.0, clock=time.monotonic, sleep=time.sleep):
        parts = urlsplit(base)
        if parts.scheme != 'http' or parts.hostname not in LOOPBACK:
            raise ValueError('admin room transport refuses a non-loopback base URL')
        self.base = base
        self.server_name = server_name
        self.token = token
        self.server_user = server_user or '@conduit:' + server_name
        self.timeout = timeout
        self.interval = interval
        self._http = http or self._http_send
        self._clock = clock
        self._sleep = sleep
        self.room_id = None

    def _http_send(self, method, path, body, headers):
        req = urllib.request.Request(self.base + path, data=body, headers=headers, method=method)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(req, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            try:
                errcode = json.load(e).get('errcode')
            except Exception:
                errcode = None
            raise RuntimeError('admin room HTTP ' + str(e.code) + ': ' + (errcode or e.reason)) from None

    def _request(self, method, path, data=None):
        body = json.dumps(data).encode() if data is not None else None
        headers = {'Authorization': 'Bearer ' + self.token}
        if body is not None:
            headers['Content-Type'] = 'application/json'
        reply = self._http(method, path, body, headers)
        if not isinstance(reply, dict):
            raise RuntimeError('admin room returned a non-object reply')
        return reply

    @property
    def alias(self):
        return '#admins:' + self.server_name

    def resolve(self):
        """Resolve the admin room alias once via the room directory."""
        if self.room_id is None:
            reply = self._request('GET', '/_matrix/client/v3/directory/room/' + quote(self.alias, safe=''))
            room = reply.get('room_id')
            if not isinstance(room, str) or not room.startswith('!'):
                raise RuntimeError('admin room alias did not resolve to a room id')
            self.room_id = room
        return self.room_id

    def _room_path(self):
        return '/_matrix/client/v3/rooms/' + quote(self.resolve(), safe='')

    def _reply_after(self, event_id):
        """Server-user messages newer than our command, oldest first; None if none yet."""
        page = self._request('GET', self._room_path() + '/messages?' + urlencode({'dir': 'b', 'limit': '50'}))
        chunk = page.get('chunk')
        if not isinstance(chunk, list):
            raise RuntimeError('admin room history was not a list')
        newer = []
        for event in chunk:  # newest first
            if event.get('event_id') == event_id:
                break
            newer.append(event)
        else:
            raise RuntimeError('sent admin command not found in recent room history')
        bodies = [event['content']['body'] for event in reversed(newer)
                  if event.get('type') == 'm.room.message' and event.get('sender') == self.server_user
                  and isinstance(event.get('content'), dict) and isinstance(event['content'].get('body'), str)]
        return '\n'.join(bodies) if bodies else None

    def command(self, text, expect=()):
        """Post ``!admin <text>`` and wait (bounded) for the server reply containing every phrase in ``expect``."""
        sent = self._request('PUT', self._room_path() + '/send/m.room.message/' + secrets.token_hex(16),
                             {'msgtype': 'm.text', 'body': '!admin ' + text})
        event_id = sent.get('event_id')
        if not isinstance(event_id, str) or not event_id:
            raise RuntimeError('admin command was not acknowledged with an event id')
        deadline = self._clock() + self.timeout
        while True:
            reply = self._reply_after(event_id)
            if reply is not None:
                break
            if self._clock() >= deadline:
                raise RuntimeError('no admin room reply within timeout for: ' + text)
            self._sleep(self.interval)
        lowered = reply.lower()
        missing = [phrase for phrase in expect if phrase.lower() not in lowered]
        if missing:
            raise RuntimeError('admin reply to "' + text + '" lacks expected phrase: ' + ', '.join(missing))
        return reply

    def backup_database(self):
        return self.command('server backup-database', expect=('Done',))

    def list_backups(self):
        return self.command('server list-backups')

    def verify_backup(self):
        return self.command('server verify-backup', expect=('all files present',))
