"""End to end: the Rust native-responder + scripts/ccc_adapter.py + a fake ccc-node (#396).

Runs the real binary on the real adapter, with a throwaway ``telegram_bot`` /
``claude_agent_sdk`` package on PYTHONPATH standing in for ccc-node, and
speaks the parent port (docs/FLEET-WORKER.md) the way the native-mls bot
does — over a pipe and over a socketpair (systemd ``Accept=yes``).

Needs the binary: ``NATIVE_RESPONDER_BIN`` or
``archive/native-mls/bot/target/{debug,release}/native-responder``; skipped
otherwise (verify.yml has no Rust; the native-mls-bot job sets the env).
"""
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT/'scripts'/'ccc_adapter.py'


def find_binary():
    env = os.environ.get('NATIVE_RESPONDER_BIN')
    if env:
        return Path(env)
    for profile in ('debug', 'release'):
        candidate = ROOT/'archive'/'native-mls'/'bot'/'target'/profile/'native-responder'
        if candidate.is_file():
            return candidate
    return None


BINARY = find_binary()

FAKE_CONTRACTS = '''
import dataclasses, enum, os

class ApprovalDecision(enum.Enum):
    ALLOW = 'allow'
    DENY = 'deny'

if os.environ.get('FAKE_OLD_CCC_NODE'):
    @dataclasses.dataclass
    class SessionRequest:
        session_id: object = None
        working_directory: str = ''
        approval_policy: str = ''
else:
    @dataclasses.dataclass
    class SessionRequest:
        session_id: object = None
        working_directory: str = ''
        approval_policy: str = ''
        model: object = None
        effort: object = None
        mcp_servers: object = None
        mcp_allowed_tools: object = None
'''

FAKE_RUNTIME = '''
import asyncio, json, os
from types import SimpleNamespace as N


class Session:
    def __init__(self, request):
        self.request = request
        self.session_id = request.session_id or 'fake-session'

    async def send_turn(self, prompt, approval_handler):
        if 'hang' in prompt:
            await asyncio.Event().wait()
        if 'approval' in prompt:
            decision = await approval_handler(N(action='Bash', description='ls /tmp', arguments={'command': 'ls'}))
            text = 'decision=' + decision.value
        elif prompt.endswith('tool'):
            handler = self.request.mcp_servers['steward']['tools']['room_status']
            text = 'tool=' + json.dumps(await handler({}), sort_keys=True)
        elif 'options' in prompt:
            text = json.dumps({'model': self.request.model, 'effort': self.request.effort,
                               'policy': self.request.approval_policy,
                               'allowed': self.request.mcp_allowed_tools,
                               'schemas': self.request.mcp_servers['steward']['schemas']}, sort_keys=True)
        else:
            text = 'echo:' + prompt
        yield N(kind='text_delta', text=text)
        yield N(kind='completion', stop_reason='end_turn')

    async def interrupt(self):
        pass


class ClaudeRuntime:
    def __init__(self, **options):
        assert options == {}, options

    async def start_or_resume(self, request):
        return Session(request)

    async def close(self):
        if os.environ.get('FAKE_CLOSE_FAILS'):
            raise RuntimeError('cleanup failure')
'''

FAKE_CODEX = '''
class CodexRuntime:
    def __init__(self, **options):
        raise AssertionError('codex runtime is not used in these tests')
'''

FAKE_SDK = '''
def tool(name, description, schema):
    def decorate(handler):
        return {'name': name, 'schema': schema, 'handler': handler}
    return decorate


def create_sdk_mcp_server(name, version, tools):
    return {'type': 'sdk', 'name': name, 'tools': {t['name']: t['handler'] for t in tools},
            'schemas': {t['name']: sorted(t['schema']) for t in tools}}
'''


@unittest.skipIf(BINARY is None, 'native-responder binary not built')
class NativeResponderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        files = {
            'telegram_bot/__init__.py': '',
            'telegram_bot/contracts/__init__.py': '',
            'telegram_bot/contracts/agent_runtime.py': FAKE_CONTRACTS,
            'telegram_bot/contracts/codex_runtime.py': FAKE_CODEX,
            'telegram_bot/core/__init__.py': '',
            'telegram_bot/core/claude_runtime.py': FAKE_RUNTIME,
            'claude_agent_sdk/__init__.py': FAKE_SDK,
        }
        for name, text in files.items():
            path = root/'py'/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(text))
        (root/'work').mkdir()
        cls.pythonpath = str(root/'py')
        cls.workdir = str(root/'work')

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def argv(self, *extra):
        return [str(BINARY), '--adapter-argv-json', json.dumps([sys.executable, str(ADAPTER)]),
                '--provider', 'claude', '--workdir', self.workdir, '--model', 'claude-opus-5-5',
                '--effort', 'high', '--claude-permission-mode', 'default', '--approval-timeout', '600',
                '--turn-timeout', '1100', '--steward-tools', '--tool-timeout', '90', *extra]

    def env(self, **extra):
        return {**os.environ, 'PYTHONPATH': self.pythonpath, **extra}

    def spawn(self, *extra, env=None):
        proc = subprocess.Popen(self.argv(*extra), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env or self.env())
        self.addCleanup(self._reap, proc)
        return Port(proc.stdin, proc.stdout), proc

    @staticmethod
    def _reap(proc):
        if proc.poll() is None:
            proc.kill()
        proc.wait(5)
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            if stream:
                stream.close()

    def test_turn_round_trip_and_session_resume(self):
        port, proc = self.spawn()
        port.send({'type': 'turn', 'turn_id': 'one', 'prompt': 'hello', 'sender': '@owner:test.invalid',
                   'room_kind': 'family'})
        self.assertEqual(port.read(), {'type': 'session', 'turn_id': 'one', 'session_id': 'fake-session'})
        result = port.read()
        self.assertEqual(result, {'type': 'result', 'turn_id': 'one', 'status': 'complete',
                                  'session_id': 'fake-session',
                                  'text': 'echo:[가족방 메시지 · 보낸 사람: @owner:test.invalid]\nhello'})
        port.send({'type': 'turn', 'turn_id': 'two', 'prompt': 'again', 'session_id': 'saved'})
        self.assertEqual(port.read()['session_id'], 'saved')
        self.assertEqual(port.read()['text'], 'echo:again')
        proc.stdin.close()
        self.assertEqual(proc.wait(10), 0, 'EOF is a clean stop')

    def test_harness_options_and_read_only_allow_list_reach_ccc_node(self):
        port, proc = self.spawn()
        port.send({'type': 'turn', 'turn_id': 'opt', 'prompt': 'options'})
        port.read()
        seen = json.loads(port.read()['text'])
        self.assertEqual(seen['model'], 'claude-opus-5-5')
        self.assertEqual(seen['effort'], 'high')
        self.assertEqual(seen['policy'], 'default')
        self.assertEqual(seen['allowed'], ['mcp__steward__room_status', 'mcp__steward__room_members'])
        self.assertEqual(seen['schemas']['room_invite'], ['device', 'room'])
        self.assertEqual(seen['schemas']['room_status'], [])
        self.assertEqual(len(seen['schemas']), 8)

    def test_approval_round_trip(self):
        for verb, decision in [('approve', 'allow'), ('deny', 'deny')]:
            port, proc = self.spawn()
            port.send({'type': 'turn', 'turn_id': 'ap', 'prompt': 'needs approval'})
            port.read()
            approval = port.read()
            self.assertEqual((approval['type'], approval['action'], approval['arguments']),
                             ('approval', 'Bash', {'command': 'ls'}))
            port.send({'type': verb, 'turn_id': 'ap', 'approval_id': 'forged'})
            self.assertEqual(port.read()['accepted'], False)
            port.send({'type': verb, 'turn_id': 'ap', 'approval_id': approval['approval_id']})
            self.assertEqual(port.read(), {'type': 'control', 'turn_id': 'ap', 'accepted': True})
            self.assertEqual(port.read()['type'], 'approval-resolved')
            self.assertEqual(port.read()['text'], 'decision=' + decision)

    def test_steward_tool_round_trip(self):
        port, proc = self.spawn()
        port.send({'type': 'turn', 'turn_id': 'tl', 'prompt': 'run a tool'})
        port.read()
        frame = port.read()
        self.assertEqual((frame['type'], frame['name'], frame['arguments']), ('tool', 'room_status', {}))
        port.send({'type': 'tool-result', 'turn_id': 'tl', 'tool_id': frame['tool_id'], 'ok': True,
                   'result': {'rooms': [{'room': 'family', 'mode': 'silent'}]}})
        self.assertEqual(port.read()['accepted'], True)
        text = port.read()['text']
        mcp = json.loads(text[len('tool='):])
        self.assertEqual(mcp['content'][0]['text'],
                         '{"ok": true, "result": {"rooms": [{"mode": "silent", "room": "family"}]}}')
        self.assertNotIn('is_error', mcp)

    def test_cancel_retires_the_worker(self):
        port, proc = self.spawn()
        port.send({'type': 'turn', 'turn_id': 'hg', 'prompt': 'hang'})
        port.read()
        port.send({'type': 'cancel', 'turn_id': 'hg'})
        self.assertEqual(port.read(), {'type': 'control', 'turn_id': 'hg', 'accepted': True})
        self.assertEqual(port.read(), {'type': 'result', 'turn_id': 'hg', 'status': 'uncertain',
                                       'reason': 'cancelled', 'runtime_closed': True})
        self.assertEqual(proc.wait(10), 1)

    def test_turn_timeout_and_failed_close_are_reported(self):
        argv = self.argv()
        argv[argv.index('--turn-timeout') + 1] = '0.2'
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=self.env(FAKE_CLOSE_FAILS='1'))
        self.addCleanup(self._reap, proc)
        port = Port(proc.stdin, proc.stdout)
        port.send({'type': 'turn', 'turn_id': 'to', 'prompt': 'hang'})
        port.read()
        self.assertEqual(port.read(), {'type': 'result', 'turn_id': 'to', 'status': 'uncertain',
                                       'reason': 'timeout', 'runtime_closed': False})
        self.assertEqual(proc.wait(10), 1)

    def test_old_ccc_node_fails_closed_before_any_frame(self):
        proc = subprocess.run(self.argv(), input=b'', capture_output=True, timeout=30,
                              env=self.env(FAKE_OLD_CCC_NODE='1'))
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, b'')
        self.assertIn(b'mcp_servers', proc.stderr)

    def test_bad_flags_and_bad_frames(self):
        proc = subprocess.run(self.argv('--sandbox', 'workspaceWrite'), input=b'', capture_output=True,
                              timeout=30, env=self.env())
        self.assertEqual(proc.returncode, 1, 'Codex flag on the Claude provider is refused')
        proc = subprocess.run(self.argv(), input=b'{"type":"turn","turn_id":"x","prompt":"\\ud800"}\nnot json\n',
                              capture_output=True, timeout=30, env=self.env())
        lines = [json.loads(x) for x in proc.stdout.splitlines()]
        self.assertEqual(lines, [{'type': 'rejected', 'turn_id': 'x', 'reason': 'invalid-turn'}])
        self.assertEqual(proc.returncode, 1)

    def test_failed_runtime_close_at_eof_exits_1(self):
        # fleet_matrix confirms a `complete` result only on exit 0 (fleet_matrix.py returncode check).
        port, proc = self.spawn(env=self.env(FAKE_CLOSE_FAILS='1'))
        port.send({'type': 'turn', 'turn_id': 'c1', 'prompt': 'hello'})
        port.read()
        self.assertEqual(port.read()['status'], 'complete')
        proc.stdin.close()
        self.assertEqual(proc.wait(20), 1)

    def test_nonblocking_socket_stdio(self):
        self.test_socket_stdio_like_systemd_accept(nonblocking=True)

    def test_socket_stdio_like_systemd_accept(self, nonblocking=False):
        parent, child = socket.socketpair()
        if nonblocking:
            child.setblocking(False)  # O_NONBLOCK on the shared description: reads/writes may EAGAIN
        self.addCleanup(parent.close)
        proc = subprocess.Popen(self.argv(), stdin=child.fileno(), stdout=child.fileno(),
                                stderr=subprocess.PIPE, env=self.env())
        child.close()
        self.addCleanup(self._reap, proc)
        stream = parent.makefile('rwb', buffering=0)
        port = Port(stream, stream, sock=parent)
        port.send({'type': 'turn', 'turn_id': 's1', 'prompt': 'needs approval'})
        port.read()
        approval = port.read()
        time.sleep(0.2)  # a late inbound frame (the asyncio-socket bug class in #354 A4)
        port.send({'type': 'approve', 'turn_id': 's1', 'approval_id': approval['approval_id']})
        port.read()
        port.read()
        self.assertEqual(port.read()['text'], 'decision=allow')
        port.send({'type': 'turn', 'turn_id': 's2', 'prompt': 'second'})
        port.read()
        self.assertEqual(port.read()['text'], 'echo:second')
        parent.shutdown(socket.SHUT_WR)
        self.assertEqual(proc.wait(10), 0)


class Port:
    def __init__(self, writer, reader, sock=None):
        self.writer, self.reader, self.sock = writer, reader, sock
        self.buffer = b''

    def send(self, frame):
        self.writer.write((json.dumps(frame) + '\n').encode())
        self.writer.flush()

    def read(self, timeout=15):
        deadline = time.monotonic() + timeout
        fd = self.sock.fileno() if self.sock else self.reader.fileno()
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError('no frame within %ss' % timeout)
            ready, _, _ = select.select([fd], [], [], remaining)
            if ready:
                chunk = os.read(fd, 65536)
                if not chunk:
                    raise AssertionError('port closed')
                self.buffer += chunk
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)


if __name__ == '__main__':
    unittest.main()
