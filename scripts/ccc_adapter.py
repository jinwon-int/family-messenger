"""ccc-node harness boundary for the Rust ``native-responder`` (#396).

The Rust responder owns the parent port (``docs/FLEET-WORKER.md``): frame
validation, turn serialization, timeouts, approval nonces, steward tool
validation and the uncertain/retire rule. This process only does what needs
the ccc-node Python runtime: import it, run ``start_or_resume``/``send_turn``,
and hand every approval callback and steward MCP tool call back to Rust.
It holds no policy: everything it builds comes from the ``configure`` frame.

Protocol: JSON lines on stdin/stdout, one process per responder process.

    in   configure {protocol, provider, runtime_options, request_options, steward}
         turn {prompt, session_id}
         approval-decision {request_id, allow}
         tool-result {request_id, result}      # an MCP tool result dict
         interrupt                             # session.interrupt(), 5 s
         close                                 # cancel the turn, runtime.close(), 10 s, exit
    out  ready {protocol} | fatal {reason}
         session {session_id} · text {text} · completion {stop_reason} · error
         turn-end {session_id} · turn-failed
         approval-request {request_id, action, description, arguments}
         tool-call {request_id, name, arguments}
         interrupted {ok} · closed {ok}

Runtime error texts never leave this process (``error``/``turn-failed`` carry
no message); stderr goes to the service journal.
"""
import asyncio
from collections.abc import Mapping
import dataclasses
import json
import logging
import sys

PROTOCOL = 1


def plain(value):
    if isinstance(value, Mapping):
        return {k: plain(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [plain(v) for v in value]
    return value


def session_request_supports(cls, field):
    """Whether this ccc-node checkout's SessionRequest carries ``field`` (fail-closed probe)."""
    try:
        return any(f.name == field for f in dataclasses.fields(cls))
    except TypeError:
        return False


def load_runtime(provider):
    """``(RuntimeClass, SessionRequest, ALLOW, DENY)`` from the formal seam, else the core shim."""
    try:
        from telegram_bot.contracts.agent_runtime import ApprovalDecision, SessionRequest
        from telegram_bot.contracts.codex_runtime import CodexRuntime
    except ImportError:
        from telegram_bot.core.agent_runtime import ApprovalDecision, SessionRequest
        from telegram_bot.core.codex_runtime import CodexRuntime
    if provider == 'claude':
        from telegram_bot.core.claude_runtime import ClaudeRuntime as RuntimeClass
    elif provider == 'codex':
        RuntimeClass = CodexRuntime
    else:
        raise ValueError('unknown provider')
    return RuntimeClass, SessionRequest, ApprovalDecision.ALLOW, ApprovalDecision.DENY


class Adapter:
    def __init__(self, runtime, request_factory, allow, deny, emit):
        self.runtime, self.request_factory = runtime, request_factory
        self.allow, self.deny, self.emit = allow, deny, emit
        self.session = None
        self.turn = None
        self.next_id = 0
        self.approvals = {}
        self.tools = {}
        self.background = set()

    def _request_id(self):
        self.next_id += 1
        return self.next_id

    async def approval(self, request):
        request_id = self._request_id()
        future = asyncio.get_running_loop().create_future()
        self.approvals[request_id] = future
        try:
            await self.emit({'type': 'approval-request', 'request_id': request_id,
                             'action': request.action, 'description': request.description,
                             'arguments': plain(request.arguments)})
            return self.allow if await future else self.deny
        finally:
            self.approvals.pop(request_id, None)

    async def tool(self, name, arguments):
        request_id = self._request_id()
        future = asyncio.get_running_loop().create_future()
        self.tools[request_id] = future
        try:
            await self.emit({'type': 'tool-call', 'request_id': request_id, 'name': name,
                             'arguments': plain(arguments)})
            return await future
        finally:
            self.tools.pop(request_id, None)

    async def _turn(self, prompt, session_id):
        # A previous turn's session must never receive this turn's interrupt.
        self.session = None
        try:
            self.session = await self.runtime.start_or_resume(self.request_factory(session_id))
            await self.emit({'type': 'session', 'session_id': self.session.session_id})
            async for event in self.session.send_turn(prompt, approval_handler=self.approval):
                if event.kind == 'text_delta':
                    await self.emit({'type': 'text', 'text': event.text})
                elif event.kind == 'completion':
                    await self.emit({'type': 'completion', 'stop_reason': event.stop_reason})
                elif event.kind == 'error':
                    await self.emit({'type': 'error'})
            await self.emit({'type': 'turn-end', 'session_id': self.session.session_id})
        except asyncio.CancelledError:
            raise
        except Exception:
            await self.emit({'type': 'turn-failed'})

    def _spawn(self, coroutine):
        task = asyncio.create_task(coroutine)
        self.background.add(task)
        task.add_done_callback(self.background.discard)
        return task

    async def _interrupt(self):
        ok = True
        if self.session is not None:
            try:
                await asyncio.wait_for(self.session.interrupt(), 5)
            except Exception:
                ok = False
        await self.emit({'type': 'interrupted', 'ok': ok})

    async def close(self):
        """Cancel the turn (after any interrupt already sent), then close the runtime."""
        if self.turn is not None and not self.turn.done():
            self.turn.cancel()
            await asyncio.gather(self.turn, return_exceptions=True)
        for task in list(self.background):
            task.cancel()
        try:
            await asyncio.wait_for(self.runtime.close(), 10)
            return True
        except Exception:
            return False

    async def handle(self, frame):
        """Dispatch one frame; ``False`` once the adapter should exit."""
        kind = frame.get('type') if isinstance(frame, dict) else None
        if kind == 'turn':
            if self.turn is not None and not self.turn.done():
                raise RuntimeError('turn while busy')  # Rust serializes turns; a second is a bug
            self.turn = asyncio.create_task(self._turn(frame['prompt'], frame.get('session_id')))
        elif kind == 'approval-decision':
            future = self.approvals.get(frame.get('request_id'))
            if future is not None and not future.done():
                future.set_result(frame.get('allow') is True)
        elif kind == 'tool-result':
            future = self.tools.get(frame.get('request_id'))
            if future is not None and not future.done():
                future.set_result(frame.get('result'))
        elif kind == 'interrupt':
            self._spawn(self._interrupt())
        elif kind == 'close':
            ok = await self.close()
            await self.emit({'type': 'closed', 'ok': ok})
            return False
        else:
            raise ValueError('unknown adapter frame')
        return True


def build_steward_server(adapter, steward):
    """In-process SDK MCP server from the tool table Rust sent (#372 P4).

    Each handler only forwards the raw arguments to Rust (``tool-call``) and
    returns the MCP result Rust answers with; validation and owner checks
    happen in Rust and the bot.
    """
    from claude_agent_sdk import create_sdk_mcp_server, tool
    tools = []
    for spec in steward['tools']:
        def make(tool_name):
            async def handler(arguments):
                return await adapter.tool(tool_name, arguments)
            return handler
        schema = {name: str for name in spec['arguments']}
        tools.append(tool(spec['name'], spec['description'], schema)(make(spec['name'])))
    return create_sdk_mcp_server(name=steward['server'], version='1.0.0', tools=tools)


def build(config, emit, loader=load_runtime, server_builder=build_steward_server):
    """Adapter for one ``configure`` frame; raises ValueError on an unusable harness."""
    if not isinstance(config, dict) or config.get('type') != 'configure' or config.get('protocol') != PROTOCOL:
        raise ValueError('unsupported configure frame')
    RuntimeClass, SessionRequest, allow, deny = loader(config.get('provider'))
    runtime_options = dict(config.get('runtime_options') or {})
    request_options = dict(config.get('request_options') or {})
    runtime = RuntimeClass(**runtime_options)
    adapter = Adapter(runtime, lambda session_id: SessionRequest(session_id=session_id, **request_options),
                      allow, deny, emit)
    steward = config.get('steward')
    if steward:
        # Fail closed on a ccc-node that predates SessionRequest.mcp_servers
        # (ccc-node #2340) / mcp_allowed_tools (#2345): a silently dropped field
        # would change what the operator believes the room may do.
        if not session_request_supports(SessionRequest, 'mcp_servers'):
            raise ValueError('ccc-node SessionRequest has no mcp_servers; update ccc-node before --steward-tools')
        request_options['mcp_servers'] = {steward['server']: server_builder(adapter, steward)}
        allowed = list(steward.get('allowed_tools') or [])
        if allowed:
            if not session_request_supports(SessionRequest, 'mcp_allowed_tools'):
                raise ValueError('ccc-node SessionRequest has no mcp_allowed_tools; update ccc-node or pass '
                                 '--steward-tools-approve-all')
            request_options['mcp_allowed_tools'] = allowed
    return adapter


async def serve(reader, emit, **build_kwargs):
    line = await reader.readline()
    try:
        adapter = build(json.loads(line), emit, **build_kwargs)
    except Exception as exc:
        reason = str(exc) if isinstance(exc, ValueError) else type(exc).__name__
        print('ccc_adapter: ' + reason, file=sys.stderr)
        await emit({'type': 'fatal', 'reason': reason})
        return 1
    await emit({'type': 'ready', 'protocol': PROTOCOL})
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            if not await adapter.handle(json.loads(line)):
                return 0
    except Exception:
        await adapter.close()
        raise
    # EOF without `close`: the responder is gone; close the runtime quietly.
    await adapter.close()
    return 0


async def main():
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=1 << 20)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    transport, protocol = await loop.connect_write_pipe(asyncio.streams.FlowControlMixin, sys.stdout.buffer)
    writer = asyncio.StreamWriter(transport, protocol, None, loop)
    lock = asyncio.Lock()

    async def emit(message):
        async with lock:
            writer.write((json.dumps(message, ensure_ascii=False) + '\n').encode())
            await writer.drain()
    return await serve(reader, emit)


if __name__ == '__main__':
    logging.basicConfig(level=logging.CRITICAL, stream=sys.stderr)
    try:
        sys.exit(asyncio.run(main()))
    except Exception:
        print('ccc_adapter stopped', file=sys.stderr)
        sys.exit(1)
