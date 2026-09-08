import asyncio
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from fleet_remote import Lease
from fleet_matrix import Frontend
from test_fleet_matrix import config,request


class RemoteTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):self.processes=[];self.temp=tempfile.TemporaryDirectory()
    async def asyncTearDown(self):
        for proc in self.processes:
            if proc.returncode is None:proc.kill();await proc.wait()
        self.temp.cleanup()

    async def spawn(self,mode='complete',lease=.3,grace=.3):
        proc=await asyncio.create_subprocess_exec(sys.executable,str(ROOT/'scripts/fleet_remote.py'),
            '--lease-seconds',str(lease),'--grace-seconds',str(grace),'--',
            sys.executable,str(ROOT/'tests/fixtures/matrix_worker.py'),mode,
            stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL)
        self.processes.append(proc)
        proc.stdin.write(b'{"type":"turn","turn_id":"one","prompt":"synthetic"}\n');await proc.stdin.drain()
        return proc

    async def frames(self,proc):
        frames=[]
        async with asyncio.timeout(8):
            while line:=await proc.stdout.readline():frames.append(json.loads(line))
            await proc.wait()
        return frames

    async def test_normal_eof_confirms_remote_group_cleanup(self):
        p=await self.spawn(lease=3)
        p.stdin.close();frames=await self.frames(p)
        self.assertEqual(p.returncode,0)
        self.assertEqual(frames[-1],dict(type='remote_closed',turn_id='one',worker_exit=0,
                                       group_empty=True,clean=True,reason='input-eof'))

    async def test_lease_expiry_never_confirms_clean_close(self):
        p=await self.spawn();frames=await self.frames(p)
        self.assertEqual(p.returncode,75)
        self.assertFalse(frames[-1]['clean']);self.assertEqual(frames[-1]['reason'],'lease-expired')
        self.assertTrue(frames[-1]['group_empty'])

    async def test_heartbeat_does_not_reach_worker_and_keeps_lease(self):
        p=await self.spawn()
        for _ in range(8):
            p.stdin.write(b'{"type":"heartbeat"}\n');await p.stdin.drain();await asyncio.sleep(.08)
        self.assertIsNone(p.returncode)
        p.stdin.close();frames=await self.frames(p)
        self.assertEqual(p.returncode,0);self.assertTrue(frames[-1]['clean'])

    async def test_sighup_performs_cleanup(self):
        p=await self.spawn(lease=3)
        await p.stdout.readline()
        p.send_signal(signal.SIGHUP)
        frames=await self.frames(p)
        self.assertFalse(frames[-1]['clean']);self.assertTrue(frames[-1]['group_empty'])
        self.assertEqual(frames[-1]['reason'],'service-stopped')

    async def test_hung_worker_is_killed_and_never_confirmed(self):
        p=await self.spawn('hung-close')
        frames=await self.frames(p)
        self.assertEqual(p.returncode,75)
        self.assertFalse(frames[-1]['clean'])
        self.assertTrue(frames[-1]['group_empty'])
        self.assertEqual(frames[-1]['worker_exit'],-signal.SIGKILL)

    async def test_uncertain_worker_can_retire_cleanly(self):
        p=await self.spawn('cancel',lease=3)
        await p.stdout.readline();await p.stdout.readline()
        p.stdin.write(b'{"type":"cancel","turn_id":"one"}\n');await p.stdin.drain()
        frames=await self.frames(p)
        self.assertEqual(p.returncode,0);self.assertEqual(frames[-1]['worker_exit'],1)
        self.assertTrue(frames[-1]['clean'])

    async def test_duplicate_turn_is_not_forwarded(self):
        p=await self.spawn(lease=3)
        p.stdin.write(b'{"type":"turn","turn_id":"two","prompt":"synthetic"}\n');await p.stdin.drain()
        frames=await self.frames(p)
        self.assertFalse(frames[-1]['clean']);self.assertEqual(frames[-1]['reason'],'input-failed')

    async def test_frontend_requires_remote_marker(self):
        c=config(self.temp.name);c['remote_worker']=True
        f=Frontend(c);task=None
        try:
            await f.input(request(f));task=asyncio.create_task(f.work())
            async with asyncio.timeout(5):
                while not task.done():await asyncio.sleep(.01)
            self.assertTrue(f.store.get_meta('worker_cleanup_unconfirmed'))
            self.assertTrue(f.store.uncertain())
            self.assertFalse(any(j['reply']=='synthetic answer' for j in f.store.outbox()))
        finally:
            if task:task.cancel();await asyncio.gather(task,return_exceptions=True)
            await f.close()

    async def test_frontend_remote_binding_finishes_after_marker(self):
        c=config(self.temp.name);c['remote_worker']=True
        c['worker_argv']=[sys.executable,str(ROOT/'scripts/fleet_remote.py'),'--',*c['worker_argv']]
        f=Frontend(c);task=None
        try:
            req=request(f);await f.input(req);task=asyncio.create_task(f.work())
            async with asyncio.timeout(5):
                while f.store.session(req.scope) is None:
                    if task.done():task.result()
                    await asyncio.sleep(.01)
            self.assertFalse(f.store.uncertain())
            self.assertTrue(any(j['reply']=='synthetic answer' for j in f.store.outbox()))
        finally:
            if task:task.cancel();await asyncio.gather(task,return_exceptions=True)
            await f.close()


if __name__=='__main__':unittest.main()
