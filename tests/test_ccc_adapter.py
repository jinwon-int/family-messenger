"""scripts/ccc_adapter.py — the Python half of the Rust native-responder (#396).

The adapter holds no policy; these tests pin that it relays the ccc-node
runtime faithfully, never leaks runtime error text, fails closed on an old
ccc-node, and closes the runtime on every exit path.
"""
import asyncio
from dataclasses import dataclass
import json
from pathlib import Path
import sys
from types import SimpleNamespace as N
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from ccc_adapter import build, serve, session_request_supports


class FakeSession:
    def __init__(self, request, mode):
        self.request, self.mode = request, mode
        self.session_id = request['session_id'] or 'fixture-session'
        self.interrupted = False
        self.decision = None

    async def send_turn(self, prompt, approval_handler):
        if self.mode == 'approval':
            self.decision = await approval_handler(N(action='write', description='Synthetic request',
                                                    arguments={'path': ('a', 'b')}))
        elif self.mode == 'hang':
            await asyncio.Event().wait()
        elif self.mode == 'error':
            yield N(kind='error', message='sensitive fixture must not reach output')
            return
        elif self.mode == 'raise':
            raise RuntimeError('sensitive exception text')
        yield N(kind='text_delta', text='echo:' + prompt)
        yield N(kind='tool_use', name='ignored')
        yield N(kind='completion', stop_reason='end_turn')

    async def interrupt(self):
        self.interrupted = True
        if self.mode == 'broken-interrupt':
            raise RuntimeError('not stopped')


class FakeRuntime:
    def __init__(self, mode='normal', **options):
        self.mode, self.options = mode, options
        self.requests, self.sessions = [], []
        self.closed = 0

    async def start_or_resume(self, request):
        self.requests.append(request)
        self.sessions.append(FakeSession(request, self.mode))
        return self.sessions[-1]

    async def close(self):
        self.closed += 1
        if self.mode == 'close-fails':
            raise RuntimeError('cleanup failure')


@dataclass
class NewRequest:
    session_id: object = None
    working_directory: str = ''
    approval_policy: str = ''
    mcp_servers: object = None
    mcp_allowed_tools: object = None


@dataclass
class MidRequest:  # ccc-node with #2340 but before #2345
    session_id: object = None
    working_directory: str = ''
    approval_policy: str = ''
    mcp_servers: object = None


@dataclass
class OldRequest:
    session_id: object = None
    working_directory: str = ''
    approval_policy: str = ''


def configure(steward=None, **extra):
    return {'type': 'configure', 'protocol': 1, 'provider': 'claude', 'runtime_options': {},
            'request_options': {'working_directory': '/tmp', 'approval_policy': 'default'},
            'steward': steward, **extra}


STEWARD = {'server': 'steward',
           'tools': [{'name': 'room_status', 'description': 'd', 'arguments': []},
                     {'name': 'room_invite', 'description': 'd', 'arguments': ['room', 'device']}],
           'allowed_tools': ['mcp__steward__room_status']}


class Rig:
    def __init__(self, mode='normal', request_cls=NewRequest):
        self.out = []
        self.runtime = None
        self.mode, self.request_cls = mode, request_cls
        self.servers = []

    def loader(self, provider):
        if provider not in ('claude', 'codex'):
            raise ValueError('unknown provider')
        rig = self

        class Runtime(FakeRuntime):
            def __init__(self, **options):
                super().__init__(rig.mode, **options)
                rig.runtime = self

        def request(**kwargs):
            obj = rig.request_cls(**kwargs)
            return {'session_id': obj.session_id, **{k: v for k, v in kwargs.items() if k != 'session_id'}}
        request.__dataclass_fields__ = rig.request_cls.__dataclass_fields__  # probe sees the real fields
        return Runtime, request, 'allow', 'deny'

    def server_builder(self, adapter, steward):
        self.servers.append((adapter, steward))
        return {'type': 'sdk', 'name': steward['server'], 'tools': [t['name'] for t in steward['tools']]}

    async def emit(self, frame):
        self.out.append(frame)

    def build(self, config):
        return build(config, self.emit, loader=self.loader, server_builder=self.server_builder)

    async def wait_for(self, kind, count=1):
        async with asyncio.timeout(2):
            while sum(1 for x in self.out if x['type'] == kind) < count:
                await asyncio.sleep(.001)
        return [x for x in self.out if x['type'] == kind][count - 1]


class BuildTests(unittest.TestCase):
    def test_request_factory_merges_rust_options_and_session_id(self):
        rig = Rig()
        adapter = rig.build(configure(runtime_options={'cli_path': '/x'}))
        self.assertEqual(rig.runtime.options, {'cli_path': '/x'})
        self.assertEqual(adapter.request_factory('saved'),
                         {'session_id': 'saved', 'working_directory': '/tmp', 'approval_policy': 'default'})

    def test_steward_server_and_allow_list_reach_the_session_request(self):
        rig = Rig()
        adapter = rig.build(configure(STEWARD))
        request = adapter.request_factory(None)
        self.assertEqual(request['mcp_servers']['steward']['tools'], ['room_status', 'room_invite'])
        self.assertEqual(request['mcp_allowed_tools'], ['mcp__steward__room_status'])
        self.assertIs(rig.servers[0][0], adapter)

    def test_old_ccc_node_fails_closed(self):
        with self.assertRaisesRegex(ValueError, 'mcp_servers'):
            Rig(request_cls=OldRequest).build(configure(STEWARD))
        with self.assertRaisesRegex(ValueError, 'mcp_allowed_tools'):
            Rig(request_cls=MidRequest).build(configure(STEWARD))
        # approve-all (empty allow list) runs on #2340-only ccc-node
        Rig(request_cls=MidRequest).build(configure({**STEWARD, 'allowed_tools': []}))
        # no steward tools: an old ccc-node is fine
        Rig(request_cls=OldRequest).build(configure())

    def test_bad_configure_frames_are_refused(self):
        for config in [None, {'type': 'turn'}, configure(protocol=2), configure(provider='gemini')]:
            with self.subTest(config=config), self.assertRaises(ValueError):
                Rig().build(config)

    def test_session_request_probe(self):
        self.assertTrue(session_request_supports(NewRequest, 'mcp_servers'))
        self.assertFalse(session_request_supports(OldRequest, 'mcp_servers'))
        self.assertFalse(session_request_supports(object, 'mcp_servers'))


class AdapterTests(unittest.IsolatedAsyncioTestCase):
    async def start(self, mode='normal', prompt='hello', session_id=None):
        rig = Rig(mode)
        adapter = rig.build(configure(STEWARD))
        self.addAsyncCleanup(adapter.close)
        await adapter.handle({'type': 'turn', 'prompt': prompt, 'session_id': session_id})
        return rig, adapter

    async def test_turn_events_are_relayed_in_order(self):
        rig, adapter = await self.start(session_id='saved')
        await rig.wait_for('turn-end')
        self.assertEqual(rig.out, [{'type': 'session', 'session_id': 'saved'},
                                   {'type': 'text', 'text': 'echo:hello'},
                                   {'type': 'completion', 'stop_reason': 'end_turn'},
                                   {'type': 'turn-end', 'session_id': 'saved'}])

    async def test_approval_round_trip_maps_to_runtime_decisions(self):
        for allow, expected in [(True, 'allow'), (False, 'deny'), ('yes', 'deny')]:
            rig, adapter = await self.start('approval')
            request = await rig.wait_for('approval-request')
            self.assertEqual(request['arguments'], {'path': ['a', 'b']})
            await adapter.handle({'type': 'approval-decision', 'request_id': request['request_id'] + 99, 'allow': True})
            await adapter.handle({'type': 'approval-decision', 'request_id': request['request_id'], 'allow': allow})
            await rig.wait_for('turn-end')
            self.assertEqual(rig.runtime.sessions[0].decision, expected)
            self.assertEqual(adapter.approvals, {})

    async def test_tool_call_returns_rusts_mcp_result_verbatim(self):
        rig = Rig()
        adapter = rig.build(configure(STEWARD))
        self.addAsyncCleanup(adapter.close)
        call = asyncio.create_task(adapter.tool('room_invite', {'room': 'family', 'device': 'x'}))
        frame = await rig.wait_for('tool-call')
        self.assertEqual((frame['name'], frame['arguments']), ('room_invite', {'room': 'family', 'device': 'x'}))
        result = {'content': [{'type': 'text', 'text': '{"ok": true}'}]}
        await adapter.handle({'type': 'tool-result', 'request_id': frame['request_id'], 'result': result})
        self.assertEqual(await call, result)
        self.assertEqual(adapter.tools, {})

    async def test_runtime_errors_never_leak_text(self):
        for mode in ['error', 'raise']:
            rig, adapter = await self.start(mode)
            await rig.wait_for('turn-end' if mode == 'error' else 'turn-failed')
            self.assertNotIn('sensitive', repr(rig.out))

    async def test_interrupt_then_close_cancels_the_turn_and_closes_the_runtime(self):
        rig, adapter = await self.start('hang')
        await rig.wait_for('session')
        await adapter.handle({'type': 'interrupt'})
        self.assertEqual(await rig.wait_for('interrupted'), {'type': 'interrupted', 'ok': True})
        self.assertTrue(rig.runtime.sessions[0].interrupted)
        self.assertFalse(await adapter.handle({'type': 'close'}))
        self.assertEqual(rig.out[-1], {'type': 'closed', 'ok': True})
        self.assertTrue(adapter.turn.done())
        self.assertEqual(rig.runtime.closed, 1)

    async def test_failed_interrupt_and_close_are_reported(self):
        rig, adapter = await self.start('broken-interrupt')
        await rig.wait_for('turn-end')
        await adapter.handle({'type': 'interrupt'})
        self.assertEqual(await rig.wait_for('interrupted'), {'type': 'interrupted', 'ok': False})
        rig2, adapter2 = await self.start('close-fails')
        await adapter2.handle({'type': 'close'})
        self.assertEqual(rig2.out[-1], {'type': 'closed', 'ok': False})

    async def test_unknown_frames_and_a_second_turn_are_bugs(self):
        rig, adapter = await self.start('hang')
        with self.assertRaises(RuntimeError):
            await adapter.handle({'type': 'turn', 'prompt': 'again', 'session_id': None})
        with self.assertRaises(ValueError):
            await adapter.handle({'type': 'bogus'})


class ServeTests(unittest.IsolatedAsyncioTestCase):
    async def run_serve(self, lines, rig=None):
        rig = rig or Rig()
        reader = asyncio.StreamReader()
        for line in lines:
            reader.feed_data(line)
        reader.feed_eof()
        code = await serve(reader, rig.emit, loader=rig.loader, server_builder=rig.server_builder)
        return code, rig

    async def test_ready_then_eof_closes_the_runtime(self):
        code, rig = await self.run_serve([(json.dumps(configure()) + '\n').encode()])
        self.assertEqual(code, 0)
        self.assertEqual(rig.out, [{'type': 'ready', 'protocol': 1}])
        self.assertEqual(rig.runtime.closed, 1)

    async def test_unusable_harness_is_fatal_before_ready(self):
        frame = (json.dumps(configure(STEWARD)) + '\n').encode()
        code, rig = await self.run_serve([frame], Rig(request_cls=OldRequest))
        self.assertEqual(code, 1)
        self.assertEqual(rig.out[0]['type'], 'fatal')
        self.assertIn('mcp_servers', rig.out[0]['reason'])

    async def test_bad_frame_closes_the_runtime_and_raises(self):
        rig = Rig()
        with self.assertRaises(ValueError):
            await self.run_serve([(json.dumps(configure()) + '\n').encode(), b'not json\n'], rig)
        self.assertEqual(rig.runtime.closed, 1)


if __name__ == '__main__':
    unittest.main()
