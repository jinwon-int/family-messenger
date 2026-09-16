"""scripts/gate_progress.py — 게이트 진행 기록의 단위 검사(네트워크 없이 가짜 http 주입)."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import gate_progress as gp

ROOM = '!family:example.com'


def fake_pages(pages):
    """pages: dir=b 요청 순서대로 반환할 chunk 목록. 소진 뒤엔 빈 chunk를 반환한다(서버 동일)."""
    calls = {'n': 0}

    def fetch(base, token, path):
        idx = calls['n']
        calls['n'] += 1
        if idx >= len(pages):
            return {'chunk': [], 'end': pages[-1]['end']}
        return {'chunk': pages[idx]['chunk'], 'end': pages[idx]['end']}

    return fetch, calls


def ev(sender, ts=1_000, kind='m.room.encrypted'):
    return {'type': kind, 'sender': sender, 'origin_server_ts': ts}


class CountRoomTest(unittest.TestCase):
    def test_pages_aggregate_and_stop_at_last_end(self):
        pages = [
            {'chunk': [ev('@a'), ev('@b'), ev('@a', 2_000, 'm.room.message')], 'end': 't1'},
            {'chunk': [ev('@b', 500), {'type': 'm.room.member', 'sender': '@x'}], 'end': 't0'},
        ]
        fetch, calls = fake_pages(pages)
        result = gp.count_room('http://127.0.0.1:8008', 'tok', ROOM, fetch)
        self.assertEqual(result['total'], 4)
        self.assertEqual(result['by_sender'], {'@a': 2, '@b': 2})
        self.assertEqual(result['last_event_ms'], 2_000)
        self.assertEqual(calls['n'], 3)  # 마지막 end 재도달 확인 후 소진(빈 chunk)으로 정지

    def test_empty_room(self):
        fetch, _ = fake_pages([{'chunk': [], 'end': 't0'}])
        result = gp.count_room('http://127.0.0.1:8008', 'tok', ROOM, fetch)
        self.assertEqual(result['total'], 0)
        self.assertEqual(result['by_sender'], {})


class StateAndNotifyTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.state = Path(self.dir.name)
        gp.open_state(self.state)

    def argv(self, extra=()):
        return ['--room', ROOM, '--state', str(self.state), *extra]

    def run_main(self, argv, fetch, notify=None):
        with mock.patch.object(gp, 'load_tuwunel_config',
                               return_value={'base': 'http://127.0.0.1:8008', 'server_name': 'example.com'}), \
                mock.patch.object(gp, 'load_admin_token', return_value='tok'):
            return gp.main(argv, fetch=fetch, notify=notify)

    def test_first_run_records_without_notify(self):
        notified = []
        code = self.run_main(self.argv(['--notify-every', '100']),
                             fetch=fake_pages([{'chunk': [ev('@a')], 'end': 't0'}])[0],
                             notify=notified.append)
        self.assertEqual(code, 0)
        self.assertEqual(notified, [])
        latest = json.loads((self.state / 'latest.json').read_text())
        self.assertEqual(latest['total'], 1)
        self.assertEqual(latest['notify'], 'recorded')
        history = (self.state / 'history.jsonl').read_text().strip().splitlines()
        self.assertEqual(len(history), 1)

    def test_threshold_crossing_notifies_once(self):
        def run(total, notified):
            pages = [{'chunk': [ev('@a', 1_000 + total) for _ in range(total)], 'end': 't0'}]
            return self.run_main(self.argv(['--notify-every', '100']), fetch=fake_pages(pages)[0],
                                 notify=notified.append)

        run(1, [])  # 기록만 — notified 무시
        self.assertEqual(json.loads((self.state / 'latest.json').read_text())['total'], 1)
        notified = []
        self.assertEqual(run(150, notified), 0)
        self.assertEqual(len(notified), 1)
        self.assertIn('150 conversation events', notified[0])
        self.assertEqual(run(180, notified), 0)
        self.assertEqual(len(notified), 1)  # 같은 경계(100) — 무음
        self.assertEqual(run(250, notified), 0)
        self.assertEqual(len(notified), 2)  # 다음 경계(200) 통과

    def test_untrusted_state_dir_rejected(self):
        import os
        loose = Path(self.dir.name) / 'loose'
        loose.mkdir(mode=0o755)
        os.chmod(loose, 0o755)
        code = self.run_main(['--room', ROOM, '--state', str(loose)],
                             fetch=fake_pages([{'chunk': [ev('@a')], 'end': 't0'}])[0])
        self.assertEqual(code, 1)
        self.assertEqual(list(loose.iterdir()), [])


class ArgvTest(unittest.TestCase):
    def test_room_source_and_guards(self):
        with mock.patch.dict('os.environ', {'GATE_ROOM_ID': ROOM}):
            self.assertEqual(gp.parse_args(['--notify-every', '0']).room, ROOM)
        with self.assertRaises(SystemExit):
            gp.parse_args([])  # 방 ID 없음
        with self.assertRaises(SystemExit):
            gp.parse_args(['--room', 'not-a-room-id'])
        with self.assertRaises(SystemExit):
            gp.parse_args(['--room', ROOM, '--notify-every', '-1'])


if __name__ == '__main__':
    unittest.main()
