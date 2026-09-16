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


def fake_pages(forward, backward):
    """방향별 한 페이지씩: 서버는 limit 위와 무관하게 40개 창만 준다(2026-09-16 실측)."""
    calls = []

    def fetch(base, token, path):
        calls.append(path)
        if 'dir=f' in path:
            return forward
        return backward

    return fetch, calls


def page(chunk, end='t'):
    return {'chunk': chunk, 'end': end}


def ev(sender, ts=1_000, kind='m.room.encrypted', event_id=None):
    return {'type': kind, 'sender': sender, 'origin_server_ts': ts,
            'event_id': event_id or ('$' + str(ts) + sender + kind)}


class CountRoomTest(unittest.TestCase):
    def test_small_room_counts_and_complete(self):
        chunk = [ev('@a'), ev('@b'), ev('@a', 2_000, 'm.room.message'),
                 {'type': 'm.room.create', 'sender': '@a', 'event_id': '$create'}]
        fetch, calls = fake_pages(page(chunk), page(list(reversed(chunk))))
        result = gp.count_room('http://127.0.0.1:8008', 'tok', ROOM, fetch)
        self.assertEqual(result['total'], 3)
        self.assertEqual(result['by_sender'], {'@a': 2, '@b': 1})
        self.assertEqual(result['last_event_ms'], 2_000)
        self.assertTrue(result['complete'])  # 양방향 창이 겹친다 — 방 전체가 한 페이지 안
        self.assertEqual(len(calls), 2)  # f/b 각 1회 — to 체이닝 없음(Tuwunel은 to가 창을 못 옮긴다)

    def test_disjoint_windows_report_incomplete(self):
        old = [ev('@a', 100, event_id='$old1'), {'type': 'm.room.create', 'sender': '@a', 'event_id': '$c'}]
        new = [ev('@b', 9_000, event_id='$new1'), ev('@a', 9_100, event_id='$new2')]
        fetch, _ = fake_pages(page(old), page(new))
        result = gp.count_room('http://127.0.0.1:8008', 'tok', ROOM, fetch)
        # 창이 어긋나도 create가 관측되면 방 전체가 관측 범위 안이다.
        self.assertTrue(result['complete'])
        self.assertEqual(result['total'], 3)  # old1+new1+new2 — create는 대화 이벤트가 아니다

    def test_overlap_beats_missing_create(self):
        chunk = [ev('@a', 5_000, event_id='$x1'), ev('@b', 6_000, event_id='$x2')]
        fetch, _ = fake_pages(page(chunk), page(list(reversed(chunk))))
        result = gp.count_room('http://127.0.0.1:8008', 'tok', ROOM, fetch)
        self.assertTrue(result['complete'])
        self.assertEqual(result['total'], 2)

    def test_big_room_lower_bound_flagged(self):
        # 창이 어긋나고 create도 없으면(방이 페이지보다 크면) 하한임을 표시한다.
        old = [ev('@a', 100 + i, event_id=f'$o{i}') for i in range(5)]
        new = [ev('@b', 9_000 + i, event_id=f'$n{i}') for i in range(5)]
        fetch, _ = fake_pages(page(old), page(new))
        result = gp.count_room('http://127.0.0.1:8008', 'tok', ROOM, fetch)
        self.assertFalse(result['complete'])
        self.assertEqual(result['total'], 10)


class StateAndNotifyTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.state = Path(self.dir.name)
        gp.open_state(self.state)
        self.chunk = [ev('@a'), ev('@b', 2_000)]

    def fake_counter(self):
        fetch, _ = fake_pages(page(self.chunk), page(list(reversed(self.chunk))))
        return lambda base, token, room: gp.count_room(base, token, room, fetch)

    def run_main(self, argv, notify=None):
        with mock.patch.object(gp, 'load_tuwunel_config',
                               return_value={'base': 'http://127.0.0.1:8008', 'server_name': 'example.com'}), \
                mock.patch.object(gp, 'load_admin_token', return_value='tok'):
            return gp.main(self.argv(argv), counter=self.fake_counter(), notify=notify)

    def argv(self, extra=()):
        return ['--room', ROOM, '--state', str(self.state), *extra]

    def test_first_run_records_without_notify(self):
        notified = []
        code = self.run_main(['--notify-every', '100'], notify=notified.append)
        self.assertEqual(code, 0)
        self.assertEqual(notified, [])
        latest = json.loads((self.state / 'latest.json').read_text())
        self.assertEqual(latest['total'], 2)
        self.assertEqual(latest['complete'], True)
        self.assertEqual(latest['notify'], 'recorded')
        history = (self.state / 'history.jsonl').read_text().strip().splitlines()
        self.assertEqual(len(history), 1)

    def test_threshold_crossing_notifies_once(self):
        notified = []
        self.run_main(['--notify-every', '100'], notify=notified.append)  # total=2 기록
        self.assertEqual(notified, [])
        self.chunk = [ev('@a', 1_000 + i * 10) for i in range(150)] + \
                     [{'type': 'm.room.create', 'sender': '@a', 'event_id': '$c'}]
        code = self.run_main(['--notify-every', '100'], notify=notified.append)
        self.assertEqual(code, 0)
        self.assertEqual(len(notified), 1)
        self.assertIn('150 conversation events', notified[0])
        latest = json.loads((self.state / 'latest.json').read_text())
        self.assertEqual(latest['notify'], 'sent')

    def test_same_threshold_is_silent(self):
        notified = []
        self.run_main(['--notify-every', '100'], notify=notified.append)
        self.run_main(['--notify-every', '100'], notify=notified.append)  # total 동일
        self.assertEqual(notified, [])
        latest = json.loads((self.state / 'latest.json').read_text())
        self.assertEqual(latest['notify'], 'unchanged')

    def test_main_default_counter_does_not_recurse(self):
        # 회귀(#118): main의 주입 파라미터 이름이 count_room의 http 함수 파라미터와
        # 충돌해 count_room 자신이 fetch로 재귀 호출됐다(경로 이중 인코딩 → 400).
        with mock.patch.object(gp, 'fetch_json', side_effect=
                lambda base, token, path: page(self.chunk) if 'dir=f' in path else page(list(reversed(self.chunk)))), \
                mock.patch.object(gp, 'load_tuwunel_config',
                                  return_value={'base': 'http://127.0.0.1:8008', 'server_name': 'example.com'}), \
                mock.patch.object(gp, 'load_admin_token', return_value='tok'):
            code = gp.main(self.argv([]))  # counter 미지정 — 실제 count_room 기본 경로
        self.assertEqual(code, 0)
        self.assertEqual(json.loads((self.state / 'latest.json').read_text())['total'], 2)

    def test_untrusted_state_dir_rejected(self):
        import os
        loose = Path(self.dir.name) / 'loose'
        loose.mkdir(mode=0o755)
        os.chmod(loose, 0o755)
        code = self.run_main_with_state(loose)
        self.assertEqual(code, 1)
        self.assertEqual(list(loose.iterdir()), [])

    def run_main_with_state(self, state_dir):
        with mock.patch.object(gp, 'load_tuwunel_config',
                               return_value={'base': 'http://127.0.0.1:8008', 'server_name': 'example.com'}), \
                mock.patch.object(gp, 'load_admin_token', return_value='tok'):
            return gp.main(['--room', ROOM, '--state', str(state_dir)], counter=self.fake_counter())


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
