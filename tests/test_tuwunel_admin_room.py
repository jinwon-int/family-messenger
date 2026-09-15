import json
from pathlib import Path
import sys
import unittest
from urllib.parse import parse_qs, quote, urlsplit

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
from tuwunel_admin_room import AdminRoom

SERVER = 'family.example'
ROOM = '!admins-room:' + SERVER
ME = '@operator:' + SERVER
CONDUIT = '@conduit:' + SERVER


class FakeHomeserver:
    """Loopback admin room: records HTTP calls; replies appear after `latency` polls."""

    def __init__(self, reply='Done. Currently have 1 backups.', latency=0, reply_sender=CONDUIT):
        self.calls = []
        self.timeline = [self.message('$old', CONDUIT, 'earlier reply, must be ignored')]
        self.reply = reply
        self.latency = latency
        self.reply_sender = reply_sender
        self.polls = 0
        self.now = 0.0
        self.slept = []

    @staticmethod
    def message(event_id, sender, body, kind='m.room.message'):
        return {'event_id': event_id, 'sender': sender, 'type': kind, 'content': {'msgtype': 'm.text', 'body': body}}

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds

    def http(self, method, path, body, headers):
        self.calls.append({'method': method, 'path': path, 'body': body, 'headers': headers})
        url = urlsplit(path)
        if method == 'GET' and url.path == '/_matrix/client/v3/directory/room/' + quote('#admins:' + SERVER, safe=''):
            return {'room_id': ROOM, 'servers': [SERVER]}
        room_path = '/_matrix/client/v3/rooms/' + quote(ROOM, safe='')
        if method == 'PUT' and url.path.startswith(room_path + '/send/m.room.message/'):
            event_id = '$cmd' + str(len(self.timeline))
            self.timeline.append(self.message(event_id, ME, json.loads(body)['body']))
            return {'event_id': event_id}
        if method == 'GET' and url.path == room_path + '/messages':
            self.polls += 1
            assert parse_qs(url.query)['dir'] == ['b']
            if self.polls > self.latency and self.reply is not None and not any(
                    e['sender'] == self.reply_sender and e['event_id'] == '$reply' for e in self.timeline):
                self.timeline.append(self.message('$reply', self.reply_sender, self.reply))
            return {'chunk': list(reversed(self.timeline)), 'start': 't1', 'end': 't0'}
        raise AssertionError('unexpected request: ' + method + ' ' + path)


def room(hs, **kwargs):
    return AdminRoom('http://127.0.0.1:18809', SERVER, 'tok', http=hs.http, clock=hs.clock, sleep=hs.sleep,
                     timeout=kwargs.pop('timeout', 10.0), interval=kwargs.pop('interval', 1.0), **kwargs)


class AdminRoomTests(unittest.TestCase):
    def test_refuses_non_loopback_base(self):
        with self.assertRaises(ValueError):
            AdminRoom('http://matrix.example.com:8008', SERVER, 'tok', http=lambda *a: {})
        with self.assertRaises(ValueError):
            AdminRoom('https://127.0.0.1:8008', SERVER, 'tok', http=lambda *a: {})

    def test_resolves_alias_once_with_bearer_token(self):
        hs = FakeHomeserver()
        admin = room(hs)
        self.assertEqual(admin.resolve(), ROOM)
        self.assertEqual(admin.resolve(), ROOM)
        directory = [c for c in hs.calls if '/directory/room/' in c['path']]
        self.assertEqual(len(directory), 1)
        self.assertEqual(directory[0]['path'], '/_matrix/client/v3/directory/room/%23admins%3Afamily.example')
        self.assertEqual(directory[0]['headers'], {'Authorization': 'Bearer tok'})

    def test_backup_database_sends_admin_message_and_returns_server_reply(self):
        hs = FakeHomeserver()
        reply = room(hs).backup_database()
        self.assertEqual(reply, 'Done. Currently have 1 backups.')
        sent = [c for c in hs.calls if c['method'] == 'PUT']
        self.assertEqual(len(sent), 1)
        self.assertEqual(json.loads(sent[0]['body']), {'msgtype': 'm.text', 'body': '!admin server backup-database'})
        self.assertEqual(sent[0]['headers']['Content-Type'], 'application/json')
        self.assertEqual(sent[0]['headers']['Authorization'], 'Bearer tok')

    def test_list_and_verify_commands(self):
        hs = FakeHomeserver(reply='#1 backup 1005087 bytes, 60 files')
        self.assertIn('#1', room(hs).list_backups())
        self.assertEqual(json.loads([c for c in hs.calls if c['method'] == 'PUT'][0]['body'])['body'],
                         '!admin server list-backups')
        hs = FakeHomeserver(reply='Verified. all files present')
        self.assertIn('all files present', room(hs).verify_backup())
        self.assertEqual(json.loads([c for c in hs.calls if c['method'] == 'PUT'][0]['body'])['body'],
                         '!admin server verify-backup')

    def test_polls_until_reply_arrives_within_timeout(self):
        hs = FakeHomeserver(latency=3)
        self.assertEqual(room(hs, timeout=10.0, interval=2.0).backup_database(), 'Done. Currently have 1 backups.')
        self.assertEqual(hs.polls, 4)
        self.assertEqual(hs.slept, [2.0, 2.0, 2.0])

    def test_no_reply_within_timeout_fails_closed(self):
        hs = FakeHomeserver(reply=None)
        with self.assertRaisesRegex(RuntimeError, 'no admin room reply'):
            room(hs, timeout=5.0, interval=2.0).backup_database()
        self.assertGreaterEqual(hs.now, 5.0)

    def test_reply_lacking_expected_phrase_fails_closed(self):
        hs = FakeHomeserver(reply='Error: backup failed')
        with self.assertRaisesRegex(RuntimeError, 'lacks expected phrase'):
            room(hs).backup_database()
        hs = FakeHomeserver(reply='Verified. 2 files missing')
        with self.assertRaisesRegex(RuntimeError, 'all files present'):
            room(hs).verify_backup()

    def test_ignores_messages_from_other_senders(self):
        hs = FakeHomeserver(reply='Done.', reply_sender='@someone:' + SERVER)
        with self.assertRaisesRegex(RuntimeError, 'no admin room reply'):
            room(hs, timeout=2.0).backup_database()

    def test_missing_event_id_or_bad_alias_fail_closed(self):
        def http(method, path, body, headers):
            return {'room_id': 'not-a-room'} if '/directory/' in path else {}
        with self.assertRaisesRegex(RuntimeError, 'did not resolve'):
            AdminRoom('http://127.0.0.1:18809', SERVER, 'tok', http=http).command('server list-backups')

        def http_no_ack(method, path, body, headers):
            return {'room_id': ROOM} if '/directory/' in path else {}
        with self.assertRaisesRegex(RuntimeError, 'not acknowledged'):
            AdminRoom('http://127.0.0.1:18809', SERVER, 'tok', http=http_no_ack).command('server list-backups')

    def test_notice_posts_plain_message_without_waiting_for_reply(self):
        hs = FakeHomeserver()
        admin = room(hs)
        event_id = admin.notice('family messenger health: UNHEALTHY — url u')
        self.assertTrue(event_id.startswith('$cmd'))
        sent = [c for c in hs.calls if c['method'] == 'PUT' and '/send/m.room.message/' in c['path']]
        self.assertEqual(len(sent), 1)
        body = json.loads(sent[0]['body'])
        self.assertEqual(body['body'], 'family messenger health: UNHEALTHY — url u')
        self.assertEqual(body['msgtype'], 'm.text')
        # notice는 /messages 폴링을 하지 않는다 — 명령 읽기 호출이 없어야 한다.
        self.assertNotIn('/messages', ' '.join(c['path'] for c in hs.calls))

    def test_notice_without_ack_fails_closed(self):
        def http_no_ack(method, path, body, headers):
            return {'room_id': ROOM} if '/directory/' in path else {}
        with self.assertRaisesRegex(RuntimeError, 'not acknowledged'):
            AdminRoom('http://127.0.0.1:18809', SERVER, 'tok', http=http_no_ack).notice('x')


if __name__ == '__main__':
    unittest.main()
