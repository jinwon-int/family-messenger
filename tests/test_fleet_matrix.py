import asyncio
import json
from pathlib import Path
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import AsyncMock,Mock,patch
from urllib.parse import quote

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from fleet_matrix import FAMILY_NOTICE, Frontend
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
        block=self.f.store.get_meta('worker_cleanup_unconfirmed')
        self.assertEqual((block['scope'],block['event_id']),(request(self.f).scope,'$request'))
        self.assertEqual(self.f.store.block()['blocked_scopes'],[block['scope']])
        with self.assertRaises(SafetyStop):await self.f.run()
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

FAMILY='!family:test.invalid'
DAD='@dad:test.invalid'
MOM='@mom:test.invalid'
STRANGER='@stranger:test.invalid'


def keyset(char):
    return {'ed25519':char*43,'curve25519':char*43}


def pinned_device(ed,curve=None):
    return types.SimpleNamespace(ed25519=ed*43,curve25519=(curve or ed)*43)


def family_config(root):
    c=config(root)
    return {**c,'rooms':[c['rooms'][0],FAMILY],'family_rooms':[FAMILY],'family_users':[DAD,MOM],
            'family_devices':{DAD:{'DAD1':keyset('c')}}}


def fake_nio():
    """Minimal stand-in for the nio module; the frontend imports it lazily."""
    module=types.ModuleType('synthetic-nio')
    class MegolmEvent:pass
    class RoomMessageText:
        def __init__(self,sender='',body='',source=None,verified=True,decrypted=True,sender_key='',ts=0):
            self.sender=sender;self.body=body;self.source=source or {}
            self.verified=verified;self.decrypted=decrypted
            self.sender_key=sender_key;self.server_timestamp=ts
    class KeysQueryResponse:
        @classmethod
        def from_dict(cls,raw):return cls()
    class JoinedMembersResponse:
        @classmethod
        def from_dict(cls,raw,room):return cls()
    for name,cls in [('MegolmEvent',MegolmEvent),('RoomMessageText',RoomMessageText),
                     ('KeysQueryResponse',KeysQueryResponse),('JoinedMembersResponse',JoinedMembersResponse)]:
        setattr(module,name,cls)
    return module


class FamilyConfigTests(unittest.TestCase):
    def test_family_config_validation(self):
        with tempfile.TemporaryDirectory() as root:
            base=family_config(root)
            for update in ({'family_rooms':['!elsewhere:test.invalid']},
                           {'family_users':[base['account']]},
                           {'family_users':['표시이름']},
                           {'family_users':[DAD,DAD]},
                           {'family_rooms':[FAMILY],'family_users':[]},
                           {'family_devices':{MOM:{}}},
                           {'family_devices':{STRANGER:{'S1':keyset('s')}}},
                           {'family_devices':{DAD:{'DAD1':{'ed25519':'c'*42,'curve25519':'d'*43}}}},
                           {'family_notice_text':123}):
                with self.subTest(update=update):
                    with self.assertRaises(SafetyStop):Frontend({**base,**update})
            f=Frontend(base)
            self.assertEqual(f.policy.rooms[FAMILY],'mention')
            self.assertEqual(f.policy.rooms[base['rooms'][0]],'direct')
            f.store.close()

    def test_saved_policy_upgrade_and_family_change_fails_closed(self):
        with tempfile.TemporaryDirectory() as root:
            c=config(root)
            f=Frontend(c)
            old={k:c[k] for k in ('owner','rooms','devices','worker_argv','not_before_ms')}
            old['remote_worker']=False
            f.store.set_meta('policy',old)  # Stage-0 saved policy without family keys.
            f.store.close()
            f=Frontend(c)  # Upgrades silently to empty family settings.
            self.assertEqual(f.store.get_meta('policy')['family_users'],[])
            f.store.close()
            with self.assertRaises(SafetyStop):Frontend({**c,'family_rooms':[c['rooms'][0]],
                'family_users':[DAD],'family_devices':{DAD:{'D1':keyset('d')}}})
            f=Frontend(c);f.store.close()  # Failure released the process lock.


class FamilyRoomTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.f=Frontend(family_config(self.temp.name))
        self.nio=fake_nio()
        self.owner=self.f.c['owner']
        self.account=self.f.c['account']
        self.now=int(time.time()*1000)

    async def asyncTearDown(self):
        await self.f.close();self.temp.cleanup()

    def client_mock(self,rooms=None,devices=None,identity=None):
        self.f.client=types.SimpleNamespace(
            rooms={room:types.SimpleNamespace(encrypted=True,users=set(users))
                   for room,users in (rooms or {}).items()},
            receive_response=AsyncMock(),
            device_store={user:dict(ds) for user,ds in (devices or {}).items()},
            verify_device=Mock(),blacklist_device=Mock(),
            share_group_session=AsyncMock(),invalidate_outbound_session=Mock(),
            encrypt=Mock(return_value=('m.room.encrypted',{})),
            keys_upload=AsyncMock(),should_upload_keys=False,next_batch=None,
            olm=types.SimpleNamespace(should_share_group_session=Mock(return_value=False),
                                      outbound_group_sessions={},
                                      account=types.SimpleNamespace(identity_keys=identity or {})),
            close=AsyncMock())

    def route_raw(self,*routes):
        table={routes[i]:routes[i+1] for i in range(0,len(routes),2)}
        async def fake(method,path,data=None,params=None):
            for (room,suffix),payload in table.items():
                if room=='keys':
                    if method=='POST' and path=='/_matrix/client/v3/keys/query':return payload
                    continue
                if method=='GET' and quote(room,safe='') in path and path.endswith(suffix):return payload
            raise AssertionError('unexpected raw call: '+method+' '+path)
        self.f.raw=fake

    def healthy_members(self):
        return {self.owner,DAD,MOM,self.account}

    def gate_routes(self,joined,algorithm='m.megolm.v1.aes-sha2'):
        return ((FAMILY,'/joined_members'),{'joined':{user:{} for user in joined}},
                (FAMILY,'/state/m.room.encryption'),{'algorithm':algorithm})

    async def test_family_gate_allows_family_blocks_stranger_and_recovers(self):
        self.client_mock(rooms={FAMILY:self.healthy_members()})
        self.route_raw(*self.gate_routes(self.healthy_members()))
        with patch.dict(sys.modules,{'nio':self.nio}):
            self.assertTrue(await self.f.room_gate(FAMILY))
        # 가족방은 mention 없이는 입장되지 않는다(정책은 어댑터에서도 유지된다).
        probe=dict(type='m.room.message',event_id='$probe',sender=DAD,origin_server_ts=self.now,
                   content={'msgtype':'m.text','body':'멘션 없음'})
        self.assertIsNone(self.f.policy.admit(FAMILY,probe,decrypted=True,now_ms=self.now))
        notices=[job for job in self.f.store.outbox() if job['reply']==FAMILY_NOTICE]
        self.assertEqual(len(notices),1)
        self.assertEqual(notices[0]['room_id'],FAMILY)
        self.assertEqual(self.f.store.get_meta('family_room_notice'),{FAMILY:True})
        self.f.store.delivered(notices[0]['event_id'])
        joined=self.healthy_members()|{STRANGER}
        self.route_raw(*self.gate_routes(joined))
        with patch.dict(sys.modules,{'nio':self.nio}):
            self.assertFalse(await self.f.room_gate(FAMILY))
        self.assertIn(FAMILY,self.f.blocked)
        blocked=self.f.store.get_meta('room_gate_blocked')[FAMILY]
        self.assertEqual(blocked['members'],sorted(joined))
        self.assertEqual(self.f.store.outbox(),[])  # 중단된 방에는 안내도 답변도 없다.
        self.route_raw(*self.gate_routes(self.healthy_members()))
        with patch.dict(sys.modules,{'nio':self.nio}):
            self.assertTrue(await self.f.room_gate(FAMILY))
        self.assertNotIn(FAMILY,self.f.blocked)
        self.assertFalse(self.f.store.get_meta('room_gate_blocked'))
        self.assertEqual(self.f.store.outbox(),[])  # 초대 안내는 한 번만 머문다.

    async def test_direct_gate_regression_and_family_encryption_required(self):
        direct=self.f.c['rooms'][0]
        self.client_mock(rooms={FAMILY:self.healthy_members(),direct:{self.owner,self.account}})
        self.route_raw((direct,'/joined_members'),
                       {'joined':{self.owner:{},STRANGER:{},self.account:{}}},
                       (direct,'/state/m.room.encryption'),{'algorithm':'m.megolm.v1.aes-sha2'})
        with patch.dict(sys.modules,{'nio':self.nio}):
            with self.assertRaisesRegex(SafetyStop,'private-room-membership-changed'):
                await self.f.room_gate(direct)
        self.route_raw(*self.gate_routes(self.healthy_members(),algorithm='m.plain'))
        with patch.dict(sys.modules,{'nio':self.nio}):
            with self.assertRaisesRegex(SafetyStop,'encrypted-room-required'):
                await self.f.room_gate(FAMILY)
        self.assertNotIn(FAMILY,self.f.blocked)

    async def test_pin_devices_pins_each_family_user_and_detects_changes(self):
        identity={'ed25519':'agent-ed','curve25519':'agent-cu'}
        devices={self.owner:{'OWNER':pinned_device('a','b')},
                 DAD:{'DAD1':pinned_device('c'),'DAD2':pinned_device('e')},
                 MOM:{'MOM1':pinned_device('f')}}
        bot_keys={'keys':{'ed25519:BOT':'agent-ed','curve25519:BOT':'agent-cu'}}
        self.client_mock(devices=devices,identity=identity)
        self.route_raw(('keys',''),{'device_keys':{self.account:{'BOT':bot_keys},
            self.owner:{'OWNER':{}},DAD:{'DAD1':{},'DAD2':{}},MOM:{'MOM1':{}}}})
        with patch.dict(sys.modules,{'nio':self.nio}):
            await self.f.pin_devices()
        verified=[call.args[0] for call in self.f.client.verify_device.call_args_list]
        self.assertEqual(len(verified),2)  # OWNER+DAD1; unpinned DAD2/MOM1 stay unverified.
        self.assertIn(devices[DAD]['DAD1'],verified)
        self.assertIn(devices[self.owner]['OWNER'],verified)
        self.client_mock(devices={**devices,DAD:{'DAD1':pinned_device('z'),'DAD2':pinned_device('e')}},
                         identity=identity)
        self.route_raw(('keys',''),{'device_keys':{self.account:{'BOT':bot_keys},
            self.owner:{'OWNER':{}},DAD:{'DAD1':{},'DAD2':{}},MOM:{'MOM1':{}}}})
        with patch.dict(sys.modules,{'nio':self.nio}):
            with self.assertRaisesRegex(SafetyStop,'pinned-device-key-changed'):
                await self.f.pin_devices()
        self.client_mock(devices={self.owner:{'OWNER':pinned_device('a','b')},
                                  DAD:{'DAD2':pinned_device('e')},MOM:{'MOM1':pinned_device('f')}},
                         identity=identity)  # Query rebuilt the store without pinned DAD1.
        self.route_raw(('keys',''),{'device_keys':{self.account:{'BOT':bot_keys},
            self.owner:{'OWNER':{}},DAD:{'DAD2':{}},MOM:{'MOM1':{}}}})
        with patch.dict(sys.modules,{'nio':self.nio}):
            with self.assertRaisesRegex(SafetyStop,'pinned-device-missing'):
                await self.f.pin_devices()
        self.client_mock(devices=devices,identity=identity)
        self.route_raw(('keys',''),{'device_keys':{self.account:{'BOT':bot_keys},
            self.owner:{'OWNER':{},'OWN2':{}},DAD:{'DAD1':{},'DAD2':{}},MOM:{'MOM1':{}}}})
        with patch.dict(sys.modules,{'nio':self.nio}):
            with self.assertRaisesRegex(SafetyStop,'owner-device-set-changed'):
                await self.f.pin_devices()

    async def test_family_send_excludes_unpinned_and_requires_pinned_delivery(self):
        self.f.room_members[FAMILY]=set(self.healthy_members())
        devices={self.owner:{'OWNER':pinned_device('a','b')},
                 DAD:{'DAD1':pinned_device('c'),'DAD2':pinned_device('e')},
                 MOM:{'MOM1':pinned_device('f')}}
        self.client_mock(devices=devices)
        self.f.client.olm.should_share_group_session=Mock(return_value=True)
        session=types.SimpleNamespace(users_shared_with={(self.owner,'OWNER'),(DAD,'DAD1')})
        self.f.client.olm.outbound_group_sessions={FAMILY:session}
        sent=[]
        async def fake(method,path,data=None,params=None):
            if method=='PUT' and path.endswith('/send/m.room.encrypted/txn1'):
                sent.append(path);return {'event_id':'$sent'}
            raise AssertionError('unexpected raw call: '+method+' '+path)
        self.f.raw=fake
        await self.f.encrypted_send(FAMILY,'가족 답변','txn1')
        blacklisted=[call.args[0] for call in self.f.client.blacklist_device.call_args_list]
        self.assertIn(devices[DAD]['DAD2'],blacklisted)
        self.assertIn(devices[MOM]['MOM1'],blacklisted)
        self.assertNotIn(devices[DAD]['DAD1'],blacklisted)
        self.assertEqual(len(sent),1)
        self.assertEqual(self.f.store.get_meta('family_room_devices')[FAMILY],
                         {DAD:['DAD2'],MOM:['MOM1']})
        # 모든 고정 기기에 세션이 배포되기 전에는 송신하지 않는다.
        session.users_shared_with={(DAD,'DAD1')}
        with self.assertRaisesRegex(ConnectionError,'group-key-share-incomplete'):
            await self.f.encrypted_send(FAMILY,'가족 답변','txn1')
        self.f.client.invalidate_outbound_session.assert_called_with(FAMILY)
        self.f.client.encrypt.assert_called_once()  # Missing pinned delivery refused to encrypt.
        # 미고정 기기가 세션을 받았다면 송신을 거부한다.
        session.users_shared_with={(self.owner,'OWNER'),(DAD,'DAD1'),(DAD,'DAD2'),(MOM,'MOM1')}
        with self.assertRaisesRegex(ConnectionError,'group-key-share-incomplete'):
            await self.f.encrypted_send(FAMILY,'가족 답변','txn1')
        self.f.client.encrypt.assert_called_once()

    async def test_family_admission_pinned_verified_mentioned_humans_only(self):
        mention={'msgtype':'m.text','body':'호출','m.mentions':{'user_ids':[self.account]}}
        self.f.c['not_before_ms']=self.now-1000
        with patch.dict(sys.modules,{'nio':self.nio}):
            def event(sender=DAD,verified=True,key='c'*43,content=None):
                source={'type':'m.room.message','event_id':'$family','sender':sender,
                        'origin_server_ts':self.now,'content':content or dict(mention)}
                return self.nio.RoomMessageText(sender=sender,source=source,
                                                verified=verified,sender_key=key,ts=self.now)
            self.assertIsNotNone(self.f.admit_event(FAMILY,event()))
            self.assertIsNone(self.f.admit_event(FAMILY,
                event(content={'msgtype':'m.text','body':'멘션 없음'})))
            self.assertIsNone(self.f.admit_event(FAMILY,
                event(content={'msgtype':'m.text','body':self.account+' 이름 호출'})))
            self.assertIsNone(self.f.admit_event(FAMILY,event(sender=self.account)))  # 봇 발신 무시.
            self.assertIsNone(self.f.admit_event(FAMILY,event(sender=STRANGER)))
            with self.assertRaisesRegex(SafetyStop,'unverified-family-event'):
                self.f.admit_event(FAMILY,event(verified=False))
            with self.assertRaisesRegex(SafetyStop,'unverified-family-event'):
                self.f.admit_event(FAMILY,event(key='z'*43))
            self.f.blocked.add(FAMILY)
            self.assertIsNone(self.f.admit_event(FAMILY,event()))  # 중단된 방은 무시한다.
            self.f.blocked.discard(FAMILY)
            direct=self.f.c['rooms'][0]
            owner_event=self.nio.RoomMessageText(sender=self.owner,
                source={'type':'m.room.message','event_id':'$direct','sender':self.owner,
                        'origin_server_ts':self.now,
                        'content':{'msgtype':'m.text','body':'개인방'}},
                verified=True,sender_key='b'*43,ts=self.now)
            self.assertIsNotNone(self.f.admit_event(direct,owner_event))


if __name__=='__main__':unittest.main()
