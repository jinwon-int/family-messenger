import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/fleet_core.py'
spec = importlib.util.spec_from_file_location('fleet_core', SOURCE)
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)

BOT = '@agent:example.test'
OWNER = '@owner:example.test'
OTHER = '@other:example.test'
ROOM = '!private:example.test'
GROUP = '!group:example.test'
NOW = 2_000_000_000


def policy(**kwargs):
    return m.Policy(**({'account': BOT, 'users': {OWNER, OTHER}, 'bots': {BOT},
                       'rooms': {ROOM: 'direct', GROUP: 'mention'}, 'not_before_ms': NOW-1000} | kwargs))


def event(event_id='$one', sender=OWNER):
    return {'type': 'm.room.message', 'event_id': event_id, 'sender': sender,
            'origin_server_ts': NOW, 'content': {'msgtype': 'm.text', 'body': 'synthetic request'}}


def request(event_id='$one', sender=OWNER, room=ROOM):
    return policy().admit(room, event(event_id, sender), decrypted=True, now_ms=NOW)


class AdmissionTests(unittest.TestCase):
    def test_only_authorized_decrypted_text_is_admitted(self):
        p = policy()
        self.assertIsNotNone(p.admit(ROOM, event(), decrypted=True, now_ms=NOW))
        for room, e, decrypted in [(ROOM, event(), False), ('!unknown:x', event(), True),
                (ROOM, event(sender='@intruder:example.test'), True), (ROOM, event(sender=BOT), True)]:
            self.assertIsNone(p.admit(room, e, decrypted=decrypted, now_ms=NOW))

    def test_group_requires_structured_mention_or_typed_handle(self):
        p = policy()
        local = BOT[1:].split(':')[0]
        # 이름이나 부분 문자열로는 안 된다.
        for body in ['please respond', 'Fambot please', '@' + local + 'x help', 'mail@' + local + '.com', 'x@' + local]:
            e = event(); e['content']['body'] = body
            self.assertIsNone(p.admit(GROUP, e, decrypted=True, now_ms=NOW), body)
        # 스펙 m.mentions는 그대로 통과.
        e = event(); e['content']['m.mentions'] = {'user_ids': [BOT]}
        self.assertIsNotNone(p.admit(GROUP, e, decrypted=True, now_ms=NOW))
        # 본문에 @localpart를 통째로 치면 통과(휴대폰 앱은 pill 선택만 m.mentions를 만든다, 2026-09-17).
        for body in ['@' + local + ' 오늘 일정 알려줘', '오늘 일정 @' + local.upper(), '(@' + local + ')', '@' + local + ', 안녕']:
            e = event(); e['content']['body'] = body
            self.assertIsNotNone(p.admit(GROUP, e, decrypted=True, now_ms=NOW), body)
        # 직접방은 멘션 없이도 그대로.
        self.assertIsNotNone(p.admit(ROOM, event(), decrypted=True, now_ms=NOW))

    def test_reject_edits_plain_files_old_future_and_malformed_events(self):
        p = policy()
        cases = []
        for key, value in [('type', 'm.room.encrypted'), ('event_id', []), ('sender', {}),
                           ('origin_server_ts', NOW-1001), ('origin_server_ts', NOW+60_001),
                           ('origin_server_ts', True), ('content', [])]:
            e = event(); e[key] = value; cases.append(e)
        for key, value in [('msgtype', 'm.file'), ('body', 'x'*16_385), ('body', '\ud800'),
                           ('m.relates_to', {'rel_type': 'm.replace'}), ('m.relates_to', [])]:
            e = event(); e['content'][key] = value; cases.append(e)
        for e in cases:
            self.assertIsNone(p.admit(ROOM, e, decrypted=True, now_ms=NOW))

    def test_scope_separates_account_room_and_sender(self):
        scopes = {request().scope, request(sender=OTHER).scope}
        p = policy(rooms={ROOM: 'direct', GROUP: 'direct'})
        scopes.add(p.admit(GROUP, event(), decrypted=True, now_ms=NOW).scope)
        q = policy(account='@second:x', bots={'@second:x'})
        scopes.add(q.admit(ROOM, event(), decrypted=True, now_ms=NOW).scope)
        self.assertEqual(len(scopes), 4)

    def test_policy_is_frozen_and_requires_explicit_user_and_room_allowlists(self):
        rooms = {ROOM: 'direct'}
        p = policy(rooms=rooms)
        rooms['!new:x'] = 'direct'
        self.assertNotIn('!new:x', p.rooms)
        for kwargs in ({'users': set()}, {'rooms': {}}, {'users': {BOT}}, {'bots': set()}):
            with self.assertRaises(ValueError): policy(**kwargs)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.directory = Path(self.tmp.name) / 'state'

    def tearDown(self):
        self.tmp.cleanup()

    def test_duplicate_sync_and_pending_reply_survive_restart(self):
        with m.Store(self.directory, BOT) as s:
            s.accept_batch([request()], 'token1')
            s.accept_batch([request()], 'token2')
            job = s.claim()
            self.assertEqual(job['event_id'], '$one')
            self.assertIsNone(s.claim())
            s.finish('$one', 'synthetic response', 'session1')
            txn = s.outbox()[0]['txn_id']
        with m.Store(self.directory, BOT) as s:
            self.assertEqual(s.token(), 'token2')
            self.assertEqual(s.outbox()[0]['txn_id'], txn)
            self.assertEqual(s.session(request().scope), 'session1')
            self.assertIsNone(s.session(request(sender=OTHER).scope))
            s.delivered('$one')
            s.accept_batch([request()], 'token3')
            self.assertIsNone(s.claim())
            self.assertEqual(s.outbox(), [])

    def test_crash_during_execution_is_uncertain_and_blocks_only_same_scope(self):
        with m.Store(self.directory, BOT) as s:
            s.accept_batch([request(), request('$two'), request('$other', OTHER)], 'token')
            s.claim()
        with m.Store(self.directory, BOT) as s:
            self.assertEqual(len(s.uncertain()), 1)
            self.assertEqual(s.claim()['event_id'], '$other')
            self.assertIsNone(s.claim())
            s.resolve_uncertain('$one', 'Operation result reconciled; not retried.')
            self.assertIsNone(s.claim())  # Must deliver previous answer first.
            s.delivered('$one')
            self.assertEqual(s.claim()['event_id'], '$two')

    def test_capacity_failure_rolls_back_whole_batch_and_token(self):
        with m.Store(self.directory, BOT, total_cap=2, scope_cap=1) as s:
            s.accept_batch([], 'initial')
            with self.assertRaises(m.QueueFull):
                s.accept_batch([request(), request('$two')], 'lost-token')
            self.assertEqual(s.token(), 'initial')
            self.assertIsNone(s.claim())
            s.accept_batch([request(), request('$other', OTHER)], 'next')
            with self.assertRaises(m.QueueFull):
                s.accept_batch([request('$new')], 'lost-token2')
            self.assertEqual(s.token(), 'next')

    def test_conflicting_duplicate_and_wrong_scope_fail_closed(self):
        with m.Store(self.directory, BOT) as s:
            s.accept_batch([request()], 'first')
            bad = m.Request('$one', ROOM, OWNER, 'changed body', request().scope)
            with self.assertRaises(ValueError): s.accept_batch([bad], 'bad-token')
            bad = m.Request('$two', ROOM, OWNER, 'text', request(sender=OTHER).scope)
            with self.assertRaises(ValueError): s.accept_batch([bad], 'bad-token')
            self.assertEqual(s.token(), 'first')

    def test_identity_pin_and_invalid_state_transitions(self):
        with m.Store(self.directory, BOT) as s:
            s.accept_batch([request()], 'first')
            with self.assertRaises(ValueError): s.finish('$one', 'answer')
            with self.assertRaises(ValueError): s.delivered('$one')
            with self.assertRaises(ValueError): s.resolve_uncertain('$one', 'answer')
        with self.assertRaises(ValueError): m.Store(self.directory, '@different:x')
        with m.Store(self.directory, BOT) as s:
            self.assertEqual(s.token(), 'first')

    def test_second_process_cannot_open_same_store(self):
        with m.Store(self.directory, BOT):
            code = ('import sys;sys.path.insert(0,sys.argv[1]);from fleet_core import Store;'
                    's=Store(sys.argv[2],sys.argv[3])')
            p = subprocess.run([sys.executable, '-c', code, str(SOURCE.parent), str(self.directory), BOT],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            self.assertNotEqual(p.returncode, 0)

    def test_files_private_under_permissive_umask(self):
        old = os.umask(0o022)
        try:
            with m.Store(self.directory, BOT) as s: s.accept_batch([request()], 'token')
        finally:
            os.umask(old)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        for p in self.directory.iterdir(): self.assertEqual(p.stat().st_mode & 0o777, 0o600)

    def test_symlink_ancestor_directory_database_lock_and_journal_rejected(self):
        real = Path(self.tmp.name)/'real'; real.mkdir(mode=0o700)
        alias = Path(self.tmp.name)/'alias'; alias.symlink_to(real, target_is_directory=True)
        for path in [alias, alias/'state']:
            with self.assertRaises(OSError): m.Store(path, BOT)
        self.directory.mkdir(mode=0o700)
        target = real/'sentinel'; target.write_text('do not alter')
        for name in ['inbox.lock', 'inbox.sqlite3', 'inbox.sqlite3-journal']:
            # Use isolated store directories so test-created links need not be removed.
            sub = real/name.replace('.', '_'); sub.mkdir(mode=0o700)
            (sub/name).symlink_to(target)
            with self.assertRaises(OSError): m.Store(sub, BOT)
        self.assertEqual(target.read_text(), 'do not alter')

    def test_hardlinks_and_world_accessible_directory_rejected(self):
        self.directory.mkdir(mode=0o755)
        self.directory.chmod(0o755)
        with self.assertRaises(ValueError): m.Store(self.directory, BOT)
        self.directory.chmod(0o700)
        target = Path(self.tmp.name)/'sentinel'; target.write_text('unchanged')
        os.link(target, self.directory/'inbox.sqlite3')
        with self.assertRaises(ValueError): m.Store(self.directory, BOT)
        self.assertEqual(target.read_text(), 'unchanged')

    def test_failed_open_does_not_leak_fds(self):
        self.directory.mkdir(mode=0o700)
        (self.directory/'inbox.lock').symlink_to('/dev/null')
        before = len(os.listdir('/proc/self/fd'))
        for _ in range(20):
            with self.assertRaises(OSError): m.Store(self.directory, BOT)
        self.assertEqual(len(os.listdir('/proc/self/fd')), before)


if __name__ == '__main__':
    unittest.main()
