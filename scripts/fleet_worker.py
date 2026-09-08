"""Node-local JSON-lines runtime port. No Matrix/Telegram credentials cross this port.

The caller is trusted and must enforce actor/room authorization before forwarding
input. One process has one active turn. Only Codex read-only pilot binding is
provided; control logic accepts the existing provider-neutral AgentRuntime seam.
"""
import argparse
import asyncio
from collections.abc import Mapping
import json
import logging
import math
from pathlib import Path
import secrets
import sys

from fleet_core import MAX_REPLY_BYTES, MAX_TEXT_BYTES, bounded_text


def plain(value):
    if isinstance(value, Mapping):
        return {k: plain(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [plain(v) for v in value]
    return value


class Worker:
    def __init__(self, runtime, emit, request_factory, allow, deny, *,
                 turn_timeout=900, approval_timeout=120):
        for value in (turn_timeout, approval_timeout):
            if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise ValueError('timeouts must be finite and positive')
        self.runtime, self.emit, self.request_factory = runtime, emit, request_factory
        self.allow, self.deny = allow, deny
        self.turn_timeout, self.approval_timeout = turn_timeout, approval_timeout
        self.task = self.session = self.turn_id = None
        self.pending = {}
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
        elif kind == 'cancel':
            matched = (turn_id == self.turn_id and self.task is not None
                       and not self.task.done() and not self.stopping)
            if matched:
                self.stopping = True
                for future in self.pending.values():
                    if not future.done():
                        future.set_result(self.deny)
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
    from telegram_bot.core.agent_runtime import ApprovalDecision, SessionRequest
    from telegram_bot.core.codex_runtime import CodexRuntime
    if not Path(args.workdir).is_dir() or not Path(args.codex_cli).is_file():
        raise ValueError('worker paths unavailable')
    reader = asyncio.StreamReader(limit=65_537)
    protocol = asyncio.StreamReaderProtocol(reader)
    await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
    loop = asyncio.get_running_loop()
    output_transport, output_protocol = await loop.connect_write_pipe(
        lambda: asyncio.streams.FlowControlMixin(loop=loop), sys.stdout.buffer)
    writer = asyncio.StreamWriter(output_transport, output_protocol, None, loop)
    output_lock = asyncio.Lock()
    async def emit(message):
        payload = (json.dumps(message, ensure_ascii=True) + '\n').encode()
        if len(payload) > 524_288:
            raise ValueError('output frame too large')
        # Cancellable pipe backpressure; no blocking thread survives shutdown.
        try:
            async with asyncio.timeout(5):
                async with output_lock:
                    writer.write(payload)
                    await writer.drain()
        except BaseException:
            output_transport.abort()
            raise
    runtime = CodexRuntime(cli_path=args.codex_cli,
                           working_state_environment={'CCC_WORKING_STATE_ARCHIVE': '0'})
    def request(session_id):
        return SessionRequest(working_directory=str(Path(args.workdir).resolve()), session_id=session_id,
                              approval_policy='never', sandbox_policy={'type': 'readOnly'})
    worker = Worker(runtime, emit, request, ApprovalDecision.ALLOW, ApprovalDecision.DENY,
                    turn_timeout=args.turn_timeout)
    try:
        await serve(worker, reader)
    finally:
        output_transport.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workdir', required=True)
    parser.add_argument('--codex-cli', required=True)
    parser.add_argument('--turn-timeout', type=float, default=900)
    args = parser.parse_args()
    logging.basicConfig(level=logging.CRITICAL, stream=sys.stderr)
    try:
        asyncio.run(main(args))
    except Exception:
        print('fleet worker stopped; inspect body-free parent status', file=sys.stderr)
        sys.exit(1)
