"""One SSH worker lease; credentials and runtime remain on the target node.

Use a fixed operator-owned command. Input/output are private JSON lines, not logs.
The parent renews the lease with {"type":"heartbeat"} every five seconds.
"""
import argparse
import asyncio
import json
import math
import os
import re
import signal
import sys


class Lease:
    def __init__(self,argv,reader,writer, *, timeout=20,grace=20):
        if any(not math.isfinite(n) or n<=0 for n in (timeout,grace)):
            raise ValueError('invalid lease bounds')
        self.argv,self.reader,self.writer=argv,reader,writer
        self.timeout,self.grace=timeout,grace
        self.proc=None;self.turn=None;self.last=0
        self.stop=asyncio.Event();self.reason=None
        self.output_lock=asyncio.Lock()

    def halt(self,reason):
        if self.reason is None:self.reason=reason
        self.stop.set()

    async def emit(self,data):
        async with self.output_lock:
            self.writer.write(data)
            await asyncio.wait_for(self.writer.drain(),5)

    async def inputs(self):
        try:
            while line:=await self.reader.readline():
                if len(line)>65_536:raise ValueError('input-too-large')
                obj=json.loads(line)
                if obj=={'type':'heartbeat'}:
                    self.last=asyncio.get_running_loop().time();continue
                if not isinstance(obj,dict):raise ValueError('invalid-input')
                if obj.get('type')=='turn':
                    if self.turn is not None or not isinstance(obj.get('turn_id'),str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',obj['turn_id']):
                        raise ValueError('one-turn-required')
                    self.turn=obj['turn_id']
                elif self.turn is None:raise ValueError('turn-required')
                self.proc.stdin.write(line)
                await asyncio.wait_for(self.proc.stdin.drain(),5)
            self.halt('input-eof')
        except Exception:self.halt('input-failed')

    async def outputs(self):
        try:
            while line:=await self.proc.stdout.readline():
                if len(line)>524_288:raise ValueError('output-too-large')
                obj=json.loads(line)
                if not isinstance(obj,dict) or obj.get('type')=='remote_closed':raise ValueError('reserved-output')
                await self.emit(line)
        except Exception:self.halt('output-failed')

    async def expiry(self):
        while True:
            await asyncio.sleep(min(1,self.timeout/4))
            if asyncio.get_running_loop().time()-self.last>=self.timeout:
                self.halt('lease-expired');return

    async def exited(self):
        await self.proc.wait();self.halt('worker-exit')

    def group_exists(self):
        try:os.killpg(self.proc.pid,0);return True
        except ProcessLookupError:return False

    async def cleanup(self,tasks):
        forced=False
        try:
            self.proc.stdin.close()
            try:await asyncio.wait_for(self.proc.wait(),self.grace)
            except TimeoutError:forced=True
            if self.group_exists():
                forced=True
                try:os.killpg(self.proc.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                try:await asyncio.wait_for(self.proc.wait(),2)
                except TimeoutError:pass  # An escaped descendant may hold a pipe.
                for _ in range(50):
                    if not self.group_exists():break
                    await asyncio.sleep(.02)
            # Drain worker output before the guardian's final marker.
            try:await asyncio.wait_for(asyncio.shield(tasks[1]),5)
            except TimeoutError:forced=True
            clean=(not forced and not self.group_exists() and self.reason in ('input-eof','worker-exit'))
            marker={'type':'remote_closed','turn_id':self.turn,'worker_exit':self.proc.returncode,
                    'group_empty':not self.group_exists(),'clean':clean,'reason':self.reason}
            await self.emit((json.dumps(marker)+'\n').encode())
            return 0 if clean else 75
        finally:
            for task in tasks:task.cancel()
            await asyncio.gather(*tasks,return_exceptions=True)

    async def run(self):
        self.last=asyncio.get_running_loop().time()
        self.proc=await asyncio.create_subprocess_exec(*self.argv,stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL,limit=524_289,start_new_session=True)
        tasks=[asyncio.create_task(f()) for f in (self.inputs,self.outputs,self.expiry,self.exited)]
        try:await self.stop.wait()
        except asyncio.CancelledError:self.halt('service-stopped')
        finally:
            tasks[0].cancel();tasks[2].cancel()
            cleanup=asyncio.create_task(self.cleanup(tasks))
            while not cleanup.done():
                try:await asyncio.shield(cleanup)
                except asyncio.CancelledError:self.halt('service-stopped')
            return cleanup.result()


async def main(args):
    os.umask(0o077)
    loop=asyncio.get_running_loop()
    reader=asyncio.StreamReader(limit=65_537)
    incoming,_=await loop.connect_read_pipe(lambda:asyncio.StreamReaderProtocol(reader),sys.stdin.buffer)
    outgoing,protocol=await loop.connect_write_pipe(lambda:asyncio.streams.FlowControlMixin(loop=loop),sys.stdout.buffer)
    writer=asyncio.StreamWriter(outgoing,protocol,None,loop)
    argv=args.command[1:] if args.command[:1]==['--'] else args.command
    if not argv or not os.path.isabs(argv[0]):raise ValueError('absolute worker command required')
    lease=Lease(argv,reader,writer,timeout=args.lease_seconds,grace=args.grace_seconds)
    for sig in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT):loop.add_signal_handler(sig,lease.halt,'service-stopped')
    try:return await lease.run()
    finally:incoming.close();outgoing.close()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lease-seconds',type=float,default=20)
    parser.add_argument('--grace-seconds',type=float,default=20)
    parser.add_argument('command',nargs=argparse.REMAINDER)
    try:sys.exit(asyncio.run(main(parser.parse_args())))
    except Exception:sys.exit(75)
