import asyncio
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from fleet_core import Request
from fleet_matrix import Frontend
from fleet_matrix_state import MatrixStore, SafetyStop, load_config, parts, turn_id, validate_config


def config(root,mode='complete'):
    return dict(homeserver='http://127.0.0.1:18809',preview=True,account='@bot:test.invalid',
        owner='@owner:test.invalid',device_id='BOT',access_token='synthetic',pickle_key='x'*32,
        rooms=['!room:test.invalid'],devices={'OWNER':{'ed25519':'a'*43,'curve25519':'b'*43}},
        state_directory=str(Path(root)/'state'),not_before_ms=0,
        worker_argv=[sys.executable,str(Path(__file__).parent/'fixtures/matrix_worker.py'),mode])


def request(frontend,event='$request',body='synthetic prompt',room=None,sender=None):
    return frontend.policy.admit(room or frontend.c['rooms'][0],dict(type='m.room.message',event_id=event,
        sender=sender or frontend.c['owner'],origin_server_ts=int(time.time()*1000),
        content={'msgtype':'m.text','body':body}),decrypted=True,now_ms=int(time.time()*1000))


class StateTests(unittest.TestCase):
    def test_config_permissions_and_symlinks(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'config.json';path.write_text(json.dumps(config(root)));path.chmod(0o600)
            self.assertTrue(load_config(path)['preview'])
            path.chmod(0o644)
            with self.assertRaises(SafetyStop):load_config(path)
            link=Path(root)/'link';link.symlink_to(path)
            with self.assertRaises(OSError):load_config(link)

    def test_config_disallows_remote_http_and_human_device(self):
        with tempfile.TemporaryDirectory() as root:
            c=config(root)
            for update in ({'homeserver':'http://example.invalid'}, {'account':c['owner']},
                           {'devices':{}},{'worker_argv':['relative']}, {'state_directory':'relative'}):
                with self.subTest(update=update),self.assertRaises((SafetyStop,ValueError)):
                    validate_config({**c,**update})

    def test_raw_pending_survives_reopen_and_atomic_commit(self):
        with tempfile.TemporaryDirectory() as root:
            with MatrixStore(Path(root)/'state','@bot:test.invalid') as store:
                store.accept_batch([],'old')
                store.stage_sync({'next_batch':'new','to_device':{'events':[{'ciphertext':'synthetic'}]}})
            with MatrixStore(Path(root)/'state','@bot:test.invalid') as store:
                self.assertEqual(store.token(),'old')
                self.assertEqual(store.get_meta('pending_sync')['next_batch'],'new')
                with self.assertRaises(SafetyStop):store.commit_sync('wrong')
                store.commit_sync('new')
                self.assertIsNone(store.get_meta('pending_sync'))
                self.assertEqual(store.token(),'new')

    def test_policy_changes_cannot_reroute_saved_jobs(self):
        with tempfile.TemporaryDirectory() as root:
            c=config(root);f=Frontend(c);f.store.close()
            with self.assertRaises(SafetyStop):Frontend({**c,'owner':'@changed:test.invalid'})
            f=Frontend(c);f.store.close()  # Failure released the process lock.

    def test_unicode_chunks_are_lossless_and_bounded(self):
        text='한글🙂'*10000
        chunks=parts(text)
        self.assertEqual(''.join(chunks),text)
        self.assertTrue(all(len(p.encode())<=12000 for p in chunks))

    def test_storage_guard(self):
        with tempfile.TemporaryDirectory() as root,MatrixStore(Path(root)/'state','@bot:test.invalid') as s:
            from types import SimpleNamespace
            with patch('fleet_matrix_state.os.fstatvfs',return_value=SimpleNamespace(f_bavail=1,f_frsize=4096)):
                with self.assertRaises(SafetyStop):s.storage_gate()


class FrontendTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.f=Frontend(config(self.temp.name))
        self.tasks=[]

    async def asyncTearDown(self):
        for task in self.tasks:task.cancel()
        await asyncio.gather(*self.tasks,return_exceptions=True)
        await self.f.close();self.temp.cleanup()

    async def until(self,predicate):
        async with asyncio.timeout(5):
            while not predicate():await asyncio.sleep(.01)

    def work(self,mode='complete'):
        self.f.c['worker_argv'][-1]=mode
        task=asyncio.create_task(self.f.work());self.tasks.append(task);return task

    async def test_rejected_queue_event_stays_rejected_after_replay(self):
        self.f.store.total_cap=self.f.store.scope_cap=1
        first=request(self.f);second=request(self.f,'$second')
        await self.f.input(first);await self.f.input(second)
        job=self.f.store.claim();self.f.store.finish(job['event_id'],'first');self.f.store.delivered(job['event_id'])
        for notice in self.f.store.outbox():self.f.store.delivered(notice['event_id'])
        await self.f.input(second)
        self.assertIsNone(self.f.store.claim())
        with self.assertRaises(SafetyStop):await self.f.input(request(self.f,'$second','changed'))

    async def test_controls_not_blocked_by_ordinary_queue(self):
        self.f.store.total_cap=self.f.store.scope_cap=1
        await self.f.input(request(self.f));self.work('approve')
        await self.until(lambda:bool(self.f.approvals))
        tid=turn_id('$request')
        # Wrong room/sender cannot enter through the admission boundary.
        self.assertIsNone(request(self.f,'$evil','/approve '+tid+' '+'n'*32,room='!other:test.invalid'))
        self.assertIsNone(request(self.f,'$evil','/approve '+tid+' '+'n'*32,sender='@stranger:test.invalid'))
        invalid=request(self.f,'$invalid','/approve '+tid+' '+'x'*32)
        await self.f.input(invalid);self.assertTrue(self.f.approvals)
        approved=request(self.f,'$approved','/approve '+tid+' '+'n'*32)
        await self.f.input(approved);await self.f.input(approved)
        await self.until(lambda:self.f.store.session(request(self.f).scope) is not None)
        self.assertFalse(self.f.approvals)
        self.assertEqual(self.f.store.session(request(self.f).scope),'synthetic-session')

    async def test_cancel_uncertainty_requires_explicit_same_scope_ack(self):
        await self.f.input(request(self.f));self.work('cancel')
        await self.until(lambda:bool(self.f.approvals))
        tid=turn_id('$request')
        await self.f.input(request(self.f,'$cancel','/cancel '+tid))
        await self.until(lambda:bool(self.f.store.uncertain()))
        self.assertIsNone(self.f.store.get_meta('worker_cleanup_unconfirmed'))
        self.assertIsNone(self.f.store.session(request(self.f).scope))
        await self.f.input(request(self.f,'$ack','/ack '+tid))
        self.assertFalse(self.f.store.uncertain())
        self.assertIsNone(self.f.store.claim())

    async def test_failed_worker_exit_does_not_publish_success(self):
        await self.f.input(request(self.f));task=self.work('bad-close')
        await self.until(task.done)
        self.assertIsInstance(task.exception(),SafetyStop)
        self.assertTrue(self.f.store.get_meta('worker_cleanup_unconfirmed'))
        self.assertTrue(self.f.store.uncertain())
        self.assertFalse(any(j['reply']=='synthetic answer' for j in self.f.store.outbox()))

    async def test_complete_worker_result_and_replay_only_execute_once(self):
        req=request(self.f);await self.f.input(req);self.work()
        await self.until(lambda:self.f.store.session(req.scope) is not None)
        for out in self.f.store.outbox():self.f.store.delivered(out['event_id'])
        await self.f.input(req)
        self.assertIsNone(self.f.store.claim())

    async def test_repeated_cancellation_during_cleanup_joins_worker(self):
        await self.f.input(request(self.f));task=self.work('slow-close')
        await self.until(lambda:self.f.store.get_meta('worker_cleanup_in_progress'))
        proc=self.f.proc
        for _ in range(3):task.cancel();await asyncio.sleep(.02)
        await asyncio.gather(task,return_exceptions=True)
        self.assertIsNotNone(proc.returncode)
        self.assertTrue(self.f.store.uncertain())
        self.assertFalse(self.f.store.get_meta('worker_cleanup_in_progress'))
        self.assertFalse(any(j['reply']=='synthetic answer' for j in self.f.store.outbox()))

    async def test_incomplete_key_sharing_never_sends_ciphertext(self):
        from types import SimpleNamespace as N
        from unittest.mock import AsyncMock,Mock
        room=self.f.c['rooms'][0]
        self.f.client=N(olm=N(should_share_group_session=Mock(return_value=True),
            outbound_group_sessions={room:N(users_shared_with=set())}),
            share_group_session=AsyncMock(),invalidate_outbound_session=Mock(),encrypt=Mock(),close=AsyncMock())
        self.f.raw=AsyncMock()
        with self.assertRaisesRegex(ConnectionError,'group-key-share-incomplete'):
            await self.f.encrypted_send(room,'synthetic','txn')
        self.f.client.encrypt.assert_not_called();self.f.raw.assert_not_called()
        self.f.client.invalidate_outbound_session.assert_called_once_with(room)

    async def test_crash_during_cleanup_blocks_restart(self):
        self.f.store.set_meta('worker_cleanup_in_progress',True)
        with self.assertRaises(SafetyStop):await self.f.run()


if __name__=='__main__':unittest.main()
