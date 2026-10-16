"""Node-local JSON-lines runtime port. No Matrix/Telegram credentials cross this port.

The caller is trusted and must enforce actor/room authorization before forwarding
input. One process has one active turn. The Codex binding is the same ccc-node
runtime the Telegram bridge uses; the harness flags (workdir, memory materializer,
approval/sandbox policy) decide how much of that node harness a room gets. Control
logic accepts the existing provider-neutral AgentRuntime seam.
"""
import argparse
import asyncio
from collections.abc import Mapping
import json
import logging
import math
import os
from pathlib import Path
import re
import secrets
import socket
import stat
import sys

from fleet_core import MAX_REPLY_BYTES, MAX_TEXT_BYTES, bounded_text

# Codex app-server sandbox contracts, mirrored from the ccc-node Telegram bridge mapping.
SANDBOX_POLICIES = {
    'readOnly': {'type': 'readOnly'},
    'workspaceWrite': {'type': 'workspaceWrite', 'networkAccess': False},
    'dangerFullAccess': {'type': 'dangerFullAccess'},
}
APPROVAL_POLICIES = ('never', 'on-request', 'on-failure', 'untrusted')
PROVIDERS = ('codex', 'claude')
# Claude SDK permission modes the ccc-node ClaudeRuntime accepts (claude_runtime_options._PERMISSION_MODES).
# `default` asks the per-turn approval handler (this port's approve/deny round trip) before each tool use.
CLAUDE_PERMISSION_MODES = ('default', 'acceptEdits', 'plan', 'dontAsk', 'auto')
ROOM_KINDS = ('direct', 'family')
NAME_RE = re.compile(r'[A-Za-z0-9._-]{1,64}')
SENDER_RE = re.compile(r'@[a-zA-Z0-9._=-]{1,200}:[a-zA-Z0-9.:-]{1,64}')
# Steward room tools (#372 P4). The model calls `mcp__steward__<name>`; this port
# forwards one `tool` frame to the parent (the native-mls bot), which checks that
# the active turn's sender is the owner actor and runs the room command itself.
# Every call still passes the SDK permission mode (`default` → approve/deny round
# trip in the room), so the owner confirms each command before it runs.
TOOL_ARG_RE = re.compile(r'[A-Za-z0-9_-]{1,64}')
TOOL_ID_RE = re.compile(r'[A-Za-z0-9_-]{1,128}')
STEWARD_SERVER = 'steward'
STEWARD_TOOLS = {
    # name: (required arguments, optional arguments, model-facing description)
    'room_create': (('room',), ('mode',),
                    '새 E2EE 대화방을 만든다(봇이 방장). mode 는 agent|silent(기본 silent: 봇이 답하지 않음). '
                    '릴레이에는 첫 초대 때 생긴다. 오너(owner actor)가 보낸 메시지의 turn 에서만 실행된다.'),
    'room_join': (('room',), (),
                  '다른 기기가 만든 방에 참여 요청(key package 게시). 그 방의 멤버가 봇을 초대해야 들어간다. '
                  '오너 turn 전용.'),
    'room_invite': (('room', 'device'), (),
                    '기기를 방에 초대한다. 상대 기기가 먼저 그 방에 「참여 요청」(key package)을 해 두어야 한다. '
                    'device 는 기기 ID(예: jungin-iphone-1b89e3). 오너 turn 전용.'),
    'room_remove': (('room', 'device'), (),
                    '기기를 방에서 제거한다(되돌릴 수 없음 — 다시 초대해야 한다). 오너 turn 전용.'),
    'room_members': (('room',), (),
                     '방의 멤버 기기와 epoch·cursor 를 본다. 오너 turn 전용.'),
    'room_mode': (('room', 'mode'), (),
                  '방 모드를 바꾼다: agent(봇이 답함, 한 방만) | silent(듣기만). 오너 turn 전용.'),
    'room_status': ((), (),
                    '봇이 아는 모든 방의 상태(joined·epoch·cursor·mode·pending)를 본다. 오너 turn 전용.'),
}
TOOL_ARG_SCHEMA = {'room': str, 'device': str, 'mode': str}


def plain(value):
    if isinstance(value, Mapping):
        return {k: plain(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [plain(v) for v in value]
    return value


def harness_options(args, environment):
    """Map the fixed CLI flags onto ccc-node runtime/session keyword arguments.

    Defaults reproduce the stage-1 pilot binding exactly (read-only sandbox,
    approval=never, working-state archive off, no memory materializer), so a
    parent that passes only ``--workdir``/``--codex-cli`` sees no behaviour change.

    ``--provider claude`` (#354 A4) binds the same port to ccc-node's
    ``ClaudeRuntime`` instead: no CLI path, no sandbox policy (the Claude
    adapter refuses one), permissions come from ``--claude-permission-mode``
    and every SDK permission request reaches this port's approve/deny round trip.
    Codex-only flags are refused rather than silently ignored.
    """
    provider = getattr(args, 'provider', 'codex') or 'codex'
    if provider not in PROVIDERS:
        raise ValueError('unknown provider')
    if provider != 'claude' and getattr(args, 'steward_tools', False):
        raise ValueError('--steward-tools needs --provider claude (SDK MCP tools)')
    if provider == 'claude':
        if getattr(args, 'memory_materializer', None) is not None:
            raise ValueError('memory materializer is a Codex binding; Claude reads the harness from the workdir')
        if getattr(args, 'sandbox', 'readOnly') != 'readOnly' or getattr(args, 'approval_policy', 'never') != 'never':
            raise ValueError('--sandbox/--approval-policy are Codex flags; use --claude-permission-mode')
        mode = getattr(args, 'claude_permission_mode', 'default') or 'default'
        if mode not in CLAUDE_PERMISSION_MODES:
            raise ValueError('unknown Claude permission mode')
        request = {'working_directory': str(Path(args.workdir).resolve()), 'approval_policy': mode}
        for key in ('model', 'effort'):
            value = getattr(args, key, None)
            if value is not None:
                if not NAME_RE.fullmatch(value):
                    raise ValueError('invalid ' + key)
                request[key] = value
        return {}, request
    if not getattr(args, 'codex_cli', None):
        raise ValueError('--codex-cli is required for the codex provider')
    runtime = {'cli_path': args.codex_cli}
    if getattr(args, 'working_state', 'off') == 'inherit':
        # The service unit's CCC_* environment (not the message) configures working state.
        runtime['working_state_environment'] = dict(environment)
    else:
        runtime['working_state_environment'] = {'CCC_WORKING_STATE_ARCHIVE': '0'}
    materializer = getattr(args, 'memory_materializer', None)
    if materializer is not None:
        path = Path(materializer)
        if not path.is_absolute() or not path.is_file():
            raise ValueError('memory materializer unavailable')
        runtime['memory_materializer_path'] = str(path)
    approval_policy = getattr(args, 'approval_policy', 'never')
    sandbox = getattr(args, 'sandbox', 'readOnly')
    if approval_policy not in APPROVAL_POLICIES or sandbox not in SANDBOX_POLICIES:
        raise ValueError('unknown execution policy')
    request = {'working_directory': str(Path(args.workdir).resolve()),
               'approval_policy': approval_policy,
               'sandbox_policy': dict(SANDBOX_POLICIES[sandbox])}
    for key in ('model', 'effort'):
        value = getattr(args, key, None)
        if value is not None:
            if not NAME_RE.fullmatch(value):
                raise ValueError('invalid ' + key)
            request[key] = value
    return runtime, request


def compose_prompt(body, sender=None, room_kind=None):
    """Prefix admitted routing context so a shared room's model knows who is speaking.

    The parent already gated sender and room; this header is bounded by the
    validators in ``Worker.handle`` and never derived from message text.
    """
    if sender is None and room_kind is None:
        return body
    header = '[가족방 메시지' if room_kind == 'family' else '[개인방 메시지'
    if sender is not None:
        header += ' · 보낸 사람: ' + sender
    return header + ']\n' + body


class Worker:
    def __init__(self, runtime, emit, request_factory, allow, deny, *,
                 turn_timeout=900, approval_timeout=120, tool_timeout=90):
        for value in (turn_timeout, approval_timeout, tool_timeout):
            if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise ValueError('timeouts must be finite and positive')
        self.runtime, self.emit, self.request_factory = runtime, emit, request_factory
        self.allow, self.deny = allow, deny
        self.turn_timeout, self.approval_timeout = turn_timeout, approval_timeout
        self.tool_timeout = tool_timeout
        self.task = self.session = self.turn_id = None
        self.pending = {}
        # tool_id -> future resolved by the parent's `tool-result` frame (#372 P4).
        self.tool_pending = {}
        self.closed = False
        self.stopping = False
        self.failed = asyncio.Event()

    async def handle(self, command):
        if self.closed:
            raise RuntimeError('worker closed')
        if not isinstance(command, dict):
            await self.emit({'type': 'rejected', 'reason': 'invalid-command'})
            return
        kind = command.get('type')
        turn_id = command.get('turn_id')
        if (not isinstance(turn_id, str) or not 1 <= len(turn_id) <= 128
                or not all(c.isascii() and (c.isalnum() or c in '-_') for c in turn_id)):
            await self.emit({'type': 'rejected', 'reason': 'invalid-turn-id'})
            return
        if kind == 'turn':
            if self.task is not None and self.task.done():
                self._task_done(self.task)
            if self.task is not None:
                await self.emit({'type': 'rejected', 'turn_id': turn_id, 'reason': 'busy'})
                return
            try:
                prompt = bounded_text(command.get('prompt'), MAX_TEXT_BYTES)
                session_id = command.get('session_id')
                if session_id is not None:
                    bounded_text(session_id, 255)
                sender = command.get('sender')
                room_kind = command.get('room_kind')
                if sender is not None and not (isinstance(sender, str) and SENDER_RE.fullmatch(sender)):
                    raise ValueError('invalid sender')
                if room_kind is not None and room_kind not in ROOM_KINDS:
                    raise ValueError('invalid room kind')
                prompt = compose_prompt(prompt, sender, room_kind)
            except ValueError:
                await self.emit({'type': 'rejected', 'turn_id': turn_id, 'reason': 'invalid-turn'})
                return
            self.turn_id = turn_id
            self.stopping = False
            self.task = asyncio.create_task(self._run(turn_id, prompt, session_id))
            self.task.add_done_callback(self._task_done)
        elif kind in {'approve', 'deny'}:
            approval_id = command.get('approval_id')
            future = self.pending.get(approval_id) if isinstance(approval_id, str) else None
            matched = turn_id == self.turn_id and future is not None and not future.done()
            if matched:
                future.set_result(self.allow if kind == 'approve' else self.deny)
            await self.emit({'type': 'control', 'turn_id': turn_id, 'accepted': matched})
        elif kind == 'tool-result':
            tool_id = command.get('tool_id')
            future = self.tool_pending.get(tool_id) if isinstance(tool_id, str) else None
            matched = turn_id == self.turn_id and future is not None and not future.done()
            if matched:
                ok = command.get('ok') is True
                outcome = {'ok': ok}
                if ok:
                    outcome['result'] = plain(command.get('result'))
                else:
                    error = command.get('error')
                    outcome['error'] = error if isinstance(error, str) and error else 'steward_error'
                future.set_result(outcome)
            await self.emit({'type': 'control', 'turn_id': turn_id, 'accepted': matched})
        elif kind == 'cancel':
            matched = (turn_id == self.turn_id and self.task is not None
                       and not self.task.done() and not self.stopping)
            if matched:
                self.stopping = True
                for future in self.pending.values():
                    if not future.done():
                        future.set_result(self.deny)
                for future in self.tool_pending.values():
                    if not future.done():
                        future.set_result({'ok': False, 'error': 'cancelled'})
                self.task.cancel()
            await self.emit({'type': 'control', 'turn_id': turn_id, 'accepted': matched})
        else:
            await self.emit({'type': 'rejected', 'turn_id': turn_id, 'reason': 'unknown-command'})

    def _task_done(self, task):
        # Retrieve exceptions even when the caller disconnects during output.
        if not task.cancelled() and task.exception() is not None:
            self.closed = True
            self.failed.set()
        if self.task is task:
            self.task = None
            self.turn_id = self.session = None

    async def _approval(self, request):
        approval_id = secrets.token_urlsafe(24)
        future = asyncio.get_running_loop().create_future()
        self.pending[approval_id] = future
        try:
            message = {'type': 'approval', 'turn_id': self.turn_id, 'approval_id': approval_id,
                       'action': request.action, 'description': request.description,
                       'arguments': plain(request.arguments)}
            # Never silently truncate a command the operator is asked to approve.
            if len(json.dumps(message, ensure_ascii=True).encode()) > 60_000:
                await self.emit({'type': 'approval-denied', 'turn_id': self.turn_id,
                                 'reason': 'approval-too-large'})
                return self.deny
            await self.emit(message)
            try:
                decision = await asyncio.wait_for(future, self.approval_timeout)
            except TimeoutError:
                decision = self.deny
            await self.emit({'type': 'approval-resolved', 'turn_id': self.turn_id,
                             'approval_id': approval_id, 'allowed': decision == self.allow})
            return decision
        finally:
            self.pending.pop(approval_id, None)

    async def _tool(self, name, arguments):
        """Run one steward room tool through the parent (#372 P4).

        Returns an MCP tool result (``content`` text = outcome JSON; ``is_error``
        when the parent refused or did not answer). Validation is strict and
        happens here so the parent only ever sees well-formed frames; the
        parent still re-checks everything and enforces owner-only.
        """
        spec = STEWARD_TOOLS.get(name)
        if spec is None:
            return _tool_result({'ok': False, 'error': 'unknown_tool'})
        required, optional, _ = spec
        if not isinstance(arguments, Mapping):
            return _tool_result({'ok': False, 'error': 'bad_arguments'})
        clean = {}
        for key, value in arguments.items():
            if key not in required and key not in optional:
                return _tool_result({'ok': False, 'error': 'bad_arguments'})
            if not isinstance(value, str) or not TOOL_ARG_RE.fullmatch(value):
                return _tool_result({'ok': False, 'error': 'bad_arguments'})
            clean[key] = value
        if any(key not in clean for key in required):
            return _tool_result({'ok': False, 'error': 'bad_arguments'})
        if self.turn_id is None or self.stopping:
            return _tool_result({'ok': False, 'error': 'no_active_turn'})
        if self.tool_pending:
            return _tool_result({'ok': False, 'error': 'busy'})
        tool_id = secrets.token_urlsafe(24)
        future = asyncio.get_running_loop().create_future()
        self.tool_pending[tool_id] = future
        try:
            await self.emit({'type': 'tool', 'turn_id': self.turn_id, 'tool_id': tool_id,
                             'name': name, 'arguments': clean})
            try:
                outcome = await asyncio.wait_for(future, self.tool_timeout)
            except TimeoutError:
                outcome = {'ok': False, 'error': 'steward_timeout'}
        finally:
            self.tool_pending.pop(tool_id, None)
        return _tool_result(outcome)

    async def _interrupt(self):
        if self.session is not None:
            try:
                await asyncio.wait_for(self.session.interrupt(), 5)
            except Exception:
                # Cannot prove the old operation stopped. Refuse new work in
                # this process instead of creating overlapping executions.
                self.closed = True
                self.failed.set()
                try:
                    await asyncio.wait_for(self.runtime.close(), 10)
                except Exception:
                    pass

    async def _execute(self, turn_id, prompt, session_id):
        self.session = await self.runtime.start_or_resume(self.request_factory(session_id))
        await self.emit({'type': 'session', 'turn_id': turn_id, 'session_id': self.session.session_id})
        answer = []
        size = 0
        terminal = False
        async for event in self.session.send_turn(prompt, approval_handler=self._approval):
            if event.kind == 'text_delta':
                size += len(event.text.encode('utf-8'))
                if size > MAX_REPLY_BYTES:
                    raise ValueError('answer limit exceeded')
                answer.append(event.text)
            elif event.kind == 'completion':
                if event.stop_reason != 'end_turn':
                    raise RuntimeError('runtime did not finish normally')
                terminal = True
            elif event.kind == 'error':
                raise RuntimeError('runtime reported error')
        text = ''.join(answer)
        bounded_text(text, MAX_REPLY_BYTES)
        if not terminal:
            raise RuntimeError('missing runtime completion')
        return {'type': 'result', 'turn_id': turn_id, 'status': 'complete',
                'session_id': self.session.session_id, 'text': text}

    async def _run(self, turn_id, prompt, session_id):
        execution = asyncio.create_task(self._execute(turn_id, prompt, session_id))
        reason = None
        try:
            async with asyncio.timeout(self.turn_timeout):
                # Keep provider registry/iterator alive until interrupt is sent.
                result = await asyncio.shield(execution)
                await self.emit(result)
        except asyncio.CancelledError:
            reason = 'cancelled'
        except TimeoutError:
            reason = 'timeout'
        except Exception:
            reason = 'runtime-error'
        if reason is not None:
            self.stopping = True
            # interrupt() is not an acknowledgement of remote termination:
            # Codex has no turn id while awaiting turn/start. Retire this
            # runtime for EVERY uncertain outcome, even if interrupt returns.
            self.closed = True
            try:
                await self._interrupt()
                execution.cancel()
                await asyncio.gather(execution, return_exceptions=True)
                cleanup_ok = True
                try:
                    await asyncio.wait_for(self.runtime.close(), 10)
                except Exception:
                    cleanup_ok = False
                await self.emit({'type': 'result', 'turn_id': turn_id,
                                 'status': 'uncertain', 'reason': reason,
                                 'runtime_closed': cleanup_ok})
            finally:
                # Wake the input loop after the terminal notice, also when
                # the peer's output pipe disappeared. Never accept new work.
                self.failed.set()

    async def close(self):
        self.closed = True
        task = self.task
        if task is not None and not task.done():
            if not self.stopping:
                self.stopping = True
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        await asyncio.wait_for(self.runtime.close(), 10)


def _tool_result(outcome):
    """MCP tool result for one steward outcome; the model reads the JSON text."""
    text = json.dumps(outcome, ensure_ascii=False, sort_keys=True)
    if len(text.encode('utf-8')) > MAX_TEXT_BYTES:
        outcome = {'ok': False, 'error': 'result_too_large'}
        text = json.dumps(outcome, ensure_ascii=False, sort_keys=True)
    result = {'content': [{'type': 'text', 'text': text}]}
    if not outcome.get('ok'):
        result['is_error'] = True
    return result


def steward_tool_schema(name):
    """JSON-schema-ish dict for the SDK ``tool`` decorator: declared arguments only."""
    required, optional, _ = STEWARD_TOOLS[name]
    return {key: TOOL_ARG_SCHEMA[key] for key in required + optional}


def build_steward_server(worker):
    """In-process SDK MCP server exposing the steward room tools (#372 P4).

    Imported lazily: the Claude Agent SDK is only present where ``--provider
    claude`` runs. Each tool forwards to ``worker._tool``; nothing here touches
    MLS state or the relay — the parent bot does, after its owner check.
    """
    from claude_agent_sdk import create_sdk_mcp_server, tool
    tools = []
    for name, (required, optional, description) in STEWARD_TOOLS.items():
        def make(tool_name):
            async def handler(arguments):
                return await worker._tool(tool_name, arguments)
            return handler
        tools.append(tool(name, description, steward_tool_schema(name))(make(name)))
    return create_sdk_mcp_server(name=STEWARD_SERVER, version='1.0.0', tools=tools)


def session_request_supports(cls, field):
    """Whether this ccc-node checkout's SessionRequest carries ``field`` (fail-closed probe)."""
    import dataclasses
    try:
        return any(f.name == field for f in dataclasses.fields(cls))
    except TypeError:
        return False


async def serve(worker, reader):
    failure = asyncio.create_task(worker.failed.wait())
    reading = None
    try:
        while True:
            reading = asyncio.create_task(reader.readline())
            ready, _ = await asyncio.wait({reading, failure}, return_when=asyncio.FIRST_COMPLETED)
            if failure in ready:
                raise RuntimeError('worker cannot continue')
            line = reading.result()
            if not line:
                break
            if len(line) > 65_536:
                raise ValueError('input frame too large')
            try:
                command = json.loads(line)
            except (ValueError, UnicodeError):
                raise ValueError('invalid input frame') from None
            await worker.handle(command)
    finally:
        pending = [t for t in (reading, failure) if t is not None]
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        await worker.close()


async def main(args):
    # Import the deployed ccc runtime in its own interpreter; no settings/token
    # transfer from the node to the messenger host is needed.
    # The formal interface seam (telegram_bot.contracts, ccc-node #1756) is
    # preferred; checkouts predating it keep working through the back-compatible
    # shim module, so mixed-fleet rollouts never break the node-local port.
    provider = getattr(args, 'provider', 'codex') or 'codex'
    try:
        from telegram_bot.contracts.agent_runtime import ApprovalDecision, SessionRequest
        from telegram_bot.contracts.codex_runtime import CodexRuntime
    except ImportError:
        from telegram_bot.core.agent_runtime import ApprovalDecision, SessionRequest
        from telegram_bot.core.codex_runtime import CodexRuntime
    if provider == 'claude':
        # The Claude adapter lives in the core package (no contracts twin yet, #354 A4).
        from telegram_bot.core.claude_runtime import ClaudeRuntime as RuntimeClass
    else:
        RuntimeClass = CodexRuntime
    if not Path(args.workdir).is_dir():
        raise ValueError('worker paths unavailable')
    if provider == 'codex' and (not args.codex_cli or not Path(args.codex_cli).is_file()):
        raise ValueError('worker paths unavailable')
    runtime_options, request_options = harness_options(args, os.environ)
    reader = asyncio.StreamReader(limit=65_537)
    protocol = asyncio.StreamReaderProtocol(reader)
    await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
    loop = asyncio.get_running_loop()
    write, abort, close_output = await build_output(loop, sys.stdout.buffer.fileno())
    output_lock = asyncio.Lock()
    async def emit(message):
        payload = (json.dumps(message, ensure_ascii=True) + '\n').encode()
        if len(payload) > 524_288:
            raise ValueError('output frame too large')
        # Cancellable backpressure; no blocking thread survives shutdown.
        try:
            async with asyncio.timeout(5):
                async with output_lock:
                    await write(payload)
        except BaseException:
            abort()
            raise
    runtime = RuntimeClass(**runtime_options)
    def request(session_id):
        return SessionRequest(session_id=session_id, **request_options)
    worker = Worker(runtime, emit, request, ApprovalDecision.ALLOW, ApprovalDecision.DENY,
                    turn_timeout=args.turn_timeout, approval_timeout=getattr(args, 'approval_timeout', 120),
                    tool_timeout=getattr(args, 'tool_timeout', 90))
    if getattr(args, 'steward_tools', False):
        # Fail closed on a ccc-node that predates SessionRequest.mcp_servers
        # (ccc-node #2340): a silently dropped server would leave the model
        # without the tools while the operator believes they are on.
        if not session_request_supports(SessionRequest, 'mcp_servers'):
            raise ValueError('ccc-node SessionRequest has no mcp_servers; update ccc-node before --steward-tools')
        request_options['mcp_servers'] = {STEWARD_SERVER: build_steward_server(worker)}
    try:
        await serve(worker, reader)
    finally:
        close_output()


async def build_output(loop, fd):
    """Output sink for ``fd``: ``(write(payload), abort(), close())``.

    A pipe keeps the asyncio write-pipe transport. A **socket** (systemd socket
    activation, ``StandardOutput=socket`` — stdin and stdout are the same
    connection) must not: ``_UnixWritePipeTransport`` watches its fd for
    readability as the "peer closed" signal, which on a socket is tripped by
    every inbound frame, so the sink closed itself on the first late turn and
    the next emit raised ``Connection lost`` (#354 A4, requests #107/#109).
    Sockets are written with ``loop.sock_sendall`` on a dup'ed non-blocking fd.
    """
    if stat.S_ISSOCK(os.fstat(fd).st_mode):
        sock = socket.socket(fileno=os.dup(fd))
        sock.setblocking(False)
        async def write(payload):
            await loop.sock_sendall(sock, payload)
        return write, sock.close, sock.close
    transport, protocol = await loop.connect_write_pipe(
        lambda: asyncio.streams.FlowControlMixin(loop=loop), os.fdopen(os.dup(fd), 'wb', buffering=0))
    writer = asyncio.StreamWriter(transport, protocol, None, loop)
    async def write(payload):
        writer.write(payload)
        await writer.drain()
    return write, transport.abort, transport.close


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workdir', required=True,
                        help='Codex working directory; the node harness root (AGENTS.md, memory) when bound')
    parser.add_argument('--provider', choices=PROVIDERS, default='codex',
                        help='ccc-node runtime binding: codex (CodexRuntime, needs --codex-cli) '
                             'or claude (ClaudeRuntime, #354 A4)')
    parser.add_argument('--codex-cli', default=None, help='required for --provider codex')
    parser.add_argument('--claude-permission-mode', choices=CLAUDE_PERMISSION_MODES, default='default',
                        help="claude only: SDK permission mode; 'default' routes every tool permission "
                             'to approve/deny')
    parser.add_argument('--turn-timeout', type=float, default=900)
    parser.add_argument('--approval-timeout', type=float, default=120,
                        help='seconds a room may take to answer /approve before the request is denied')
    parser.add_argument('--steward-tools', action='store_true',
                        help='claude only (#372 P4): expose the steward room tools (room_create/join/invite/'
                             'remove/members/mode/status) as an in-process SDK MCP server; each call is '
                             'forwarded to the parent as a `tool` frame and gated by its owner check')
    parser.add_argument('--tool-timeout', type=float, default=90,
                        help='seconds to wait for the parent\'s tool-result before a tool call fails')
    parser.add_argument('--memory-materializer', default=None,
                        help='ccc-node Codex memory materializer script (same as CCC_CODEX_MEMORY_MATERIALIZER_PATH)')
    parser.add_argument('--approval-policy', choices=APPROVAL_POLICIES, default='never')
    parser.add_argument('--sandbox', choices=sorted(SANDBOX_POLICIES), default='readOnly')
    parser.add_argument('--working-state', choices=('off', 'inherit'), default='off',
                        help="'inherit' passes the service environment's CCC_WORKING_STATE_* keys through")
    parser.add_argument('--model', default=None)
    parser.add_argument('--effort', default=None)
    args = parser.parse_args()
    logging.basicConfig(level=logging.CRITICAL, stream=sys.stderr)
    try:
        asyncio.run(main(args))
    except Exception:
        print('fleet worker stopped; inspect body-free parent status', file=sys.stderr)
        sys.exit(1)
