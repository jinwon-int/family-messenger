import asyncio
import json
from pathlib import Path
import sys
from types import SimpleNamespace as N
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from fleet_worker import Worker, serve


class FakeSession:
    session_id = 'fixture-session'

    def __init__(self, mode='normal'):
        self.mode = mode
        self.interrupted = False
        self.decision = None

    async def send_turn(self, message, approval_handler):
        if self.mode == 'approval':
            self.decision = await approval_handler(N(action='write', description='Synthetic request',
                                                    arguments={'path': '/fixture/synthetic'}))
        elif self.mode == 'large-approval':
            self.decision = await approval_handler(N(action='write', description='x'*60_001, arguments={}))
        elif self.mode in {'hang', 'broken-interrupt'}:
            await asyncio.Event().wait()
        elif self.mode == 'error':
            yield N(kind='error', message='sensitive fixture must not reach output')
            return
        yield N(kind='text_delta', text='x'*65_537 if self.mode == 'oversize' else 'synthetic answer')
        if self.mode != 'missing-terminal':
            yield N(kind='completion', stop_reason='end_turn' if self.mode != 'bad-terminal' else 'cancelled')

    async def interrupt(self):
        self.interrupted = True
        if self.mode == 'broken-interrupt':
            raise RuntimeError('not stopped')


class FakeRuntime:
    def __init__(self, mode='normal'):
        self.session = FakeSession(mode)
        self.requests = []
        self.closed = False

    async def start_or_resume(self, request):
        self.requests.append(request)
        return self.session

    async def close(self):
        self.closed = True


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    async def setup_worker(self, mode='normal', **kwargs):
        output=[]
        async def emit(item): output.append(item)
        runtime=FakeRuntime(mode)
        worker=Worker(runtime,emit,lambda sid: {'session_id':sid},'allow','deny',**kwargs)
        self.addAsyncCleanup(worker.close)
        return worker,runtime,output

    async def wait_for(self, output, kind):
        async with asyncio.timeout(2):
            while not any(x['type']==kind for x in output):
                await asyncio.sleep(.001)
        return next(x for x in output if x['type']==kind)

    async def test_completed_turn_and_resume_with_same_worker(self):
        w,r,out=await self.setup_worker()
        await w.handle({'type':'turn','turn_id':'one','prompt':'synthetic'})
        await self.wait_for(out,'result')
        self.assertEqual(out[-1]['status'],'complete')
        self.assertEqual(out[-1]['text'],'synthetic answer')
        await w.handle({'type':'turn','turn_id':'two','prompt':'synthetic','session_id':'saved'})
        await asyncio.sleep(.01)
        self.assertEqual(r.requests,[{'session_id':None},{'session_id':'saved'}])

    async def test_busy_and_wrong_turn_cannot_cancel_current(self):
        w,r,out=await self.setup_worker('hang')
        await w.handle({'type':'turn','turn_id':'one','prompt':'synthetic'})
        await self.wait_for(out,'session')
        await w.handle({'type':'turn','turn_id':'two','prompt':'synthetic'})
        self.assertEqual(out[-1]['reason'],'busy')
        await w.handle({'type':'cancel','turn_id':'two'})
        self.assertFalse(out[-1]['accepted'])
        self.assertFalse(r.session.interrupted)
        await w.handle({'type':'cancel','turn_id':'one'})
        result=await self.wait_for(out,'result')
        self.assertEqual(result['status'],'uncertain')
        self.assertEqual(result['reason'],'cancelled')
        self.assertTrue(r.session.interrupted)

    async def test_approval_nonce_and_turn_bind_control_and_reject_replay(self):
        w,r,out=await self.setup_worker('approval')
        await w.handle({'type':'turn','turn_id':'one','prompt':'synthetic'})
        a=await self.wait_for(out,'approval')
        for turn,nonce in [('two',a['approval_id']),('one','fake')]:
            await w.handle({'type':'approve','turn_id':turn,'approval_id':nonce})
            self.assertFalse(out[-1]['accepted'])
            self.assertIsNone(r.session.decision)
        command={'type':'approve','turn_id':'one','approval_id':a['approval_id']}
        await w.handle(command)
        self.assertTrue(out[-1]['accepted'])
        await w.handle(command)
        self.assertFalse(out[-1]['accepted'])
        await self.wait_for(out,'result')
        self.assertEqual(r.session.decision,'allow')

    async def test_explicit_deny_timeout_and_large_request_fail_closed(self):
        for mode,explicit in [('approval',True),('approval',False),('large-approval',False)]:
            w,r,out=await self.setup_worker(mode,approval_timeout=.02)
            await w.handle({'type':'turn','turn_id':'one','prompt':'synthetic'})
            if explicit:
                a=await self.wait_for(out,'approval')
                await w.handle({'type':'deny','turn_id':'one','approval_id':a['approval_id']})
            await self.wait_for(out,'result')
            self.assertEqual(r.session.decision,'deny')

    async def test_cancel_during_approval_does_not_wait_for_approval_timeout(self):
        w,r,out=await self.setup_worker('approval',approval_timeout=120)
        await w.handle({'type':'turn','turn_id':'one','prompt':'synthetic'})
        a=await self.wait_for(out,'approval')
        await w.handle({'type':'cancel','turn_id':'one'})
        result=await self.wait_for(out,'result')
        self.assertEqual(result['reason'],'cancelled')
        await w.handle({'type':'approve','turn_id':'one','approval_id':a['approval_id']})
        self.assertFalse(out[-1]['accepted'])

    async def test_runtime_errors_never_claim_success_or_leak_message(self):
        for mode in ['error','oversize','missing-terminal','bad-terminal']:
            w,r,out=await self.setup_worker(mode)
            await w.handle({'type':'turn','turn_id':'one','prompt':'synthetic'})
            result=await self.wait_for(out,'result')
            self.assertEqual(result['status'],'uncertain')
            self.assertNotIn('sensitive',json.dumps(out))
            self.assertNotIn('text',result)

    async def test_timeout_interrupts_and_closes_on_unconfirmed_stop(self):
        w,r,out=await self.setup_worker('broken-interrupt',turn_timeout=.02)
        await w.handle({'type':'turn','turn_id':'one','prompt':'synthetic'})
        result=await self.wait_for(out,'result')
        self.assertEqual(result['reason'],'timeout')
        self.assertTrue(w.closed)
        with self.assertRaises(RuntimeError):
            await w.handle({'type':'turn','turn_id':'two','prompt':'synthetic'})

    async def test_invalid_frames_never_start_runtime(self):
        w,r,out=await self.setup_worker()
        for command in [None,[],{'type':'turn','turn_id':'../bad','prompt':'text'},
                {'type':'turn','turn_id':'one','prompt':'x'*16_385},
                {'type':'turn','turn_id':'one','prompt':'\ud800'},
                {'type':'turn','turn_id':'one','prompt':'text','session_id':[]},
                {'type':'other','turn_id':'one'}]:
            await w.handle(command)
            self.assertEqual(out[-1]['type'],'rejected')
        self.assertEqual(r.requests,[])

    async def test_eof_interrupts_running_work_and_closes_runtime(self):
        w,r,out=await self.setup_worker('hang')
        reader=asyncio.StreamReader()
        reader.feed_data(b'{"type":"turn","turn_id":"one","prompt":"synthetic"}\n')
        server=asyncio.create_task(serve(w,reader))
        await self.wait_for(out,'session')
        reader.feed_eof()
        await server
        self.assertTrue(r.closed)
        self.assertTrue(r.session.interrupted)

    async def test_malformed_or_oversized_stream_closes_runtime(self):
        for data in [b'bad json\n', b'x'*65_537+b'\n']:
            w,r,out=await self.setup_worker()
            reader=asyncio.StreamReader(limit=70_000)
            reader.feed_data(data)
            reader.feed_eof()
            with self.assertRaises(ValueError): await serve(w,reader)
            self.assertTrue(r.closed)

    async def test_invalid_timeouts_rejected(self):
        for timeout in [0,-1,float('nan'),float('inf')]:
            with self.assertRaises(ValueError): await self.setup_worker(turn_timeout=timeout)


if __name__=='__main__':
    unittest.main()
