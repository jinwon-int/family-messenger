"""Persistent encrypted Matrix pilot: owner direct rooms plus mention-gated
family rooms (roadmap stage 1). See docs/FLEET-MATRIX.md and docs/FLEET-BRIDGE.md."""
import argparse
import asyncio
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time
from urllib.parse import quote

from fleet_core import Policy, Request, QueueFull, private_directory, bounded_text
from fleet_matrix_state import MatrixStore, SafetyStop, load_config, parts, turn_id


FAMILY_NOTICE='이 AI는 이 방을 읽을 수 있으며 답변에 필요한 내용이 제공업체에 전달될 수 있습니다.'


def family_config(config):
    """Validate optional family-room settings; absent settings stay direct-only."""
    for key in ('family_rooms','family_users'):
        value=config.get(key,[])
        if (not isinstance(value,list) or len(value)>12
                or any(not isinstance(entry,str) or not entry for entry in value)
                or len(set(value))!=len(value)):
            raise SafetyStop('invalid-'+key)
    rooms=config.get('family_rooms',[])
    if any(room not in config['rooms'] for room in rooms):raise SafetyStop('invalid-family-rooms')
    users=config.get('family_users',[])
    if (config['account'] in users or rooms and not users
            or any(not re.fullmatch(r'@[a-zA-Z0-9._=-]+:[a-zA-Z0-9.:-]+',user) for user in users)):
        raise SafetyStop('invalid-family-users')
    pins=config.get('family_devices',{})
    if (not isinstance(pins,dict) or config['owner'] in pins
            or any(user not in users for user in pins)):
        raise SafetyStop('invalid-family-devices')
    total=0;cleaned={}
    for user,devices in pins.items():
        if not isinstance(devices,dict) or not 1<=len(devices)<=10:
            raise SafetyStop('invalid-family-devices')
        entries={}
        for device,keys in devices.items():
            if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}',device) or not isinstance(keys,dict):
                raise SafetyStop('invalid-family-device-pin')
            for kind in ('ed25519','curve25519'):
                if not isinstance(keys.get(kind),str) or not re.fullmatch(r'[A-Za-z0-9+/]{43}',keys[kind]):
                    raise SafetyStop('invalid-family-device-pin')
            entries[device]={'ed25519':keys['ed25519'],'curve25519':keys['curve25519']}
        total+=len(entries)
        cleaned[user]=entries
    if total>32:raise SafetyStop('invalid-family-devices')
    text=config.get('family_notice_text')
    if text is not None:
        try:bounded_text(text,512)
        except ValueError:raise SafetyStop('invalid-family-notice-text') from None
    return frozenset(rooms),frozenset(users),cleaned


class Frontend:
    def __init__(self, config):
        self.c=config
        # Family settings are a trust boundary; reject them before opening state.
        self.family_rooms,self.family_users,self.family_devices=family_config(config)
        self.pins={config['owner']:config['devices'],**self.family_devices}
        self.senders=frozenset([config['owner']])|self.family_users
        self.family_allowed=self.senders|frozenset([config['account']])
        self.store=MatrixStore(config['state_directory'],config['account'])
        # A saved inbox must never be silently rerouted by editing configuration.
        policy={k:config[k] for k in ('owner','rooms','devices','worker_argv','not_before_ms')}
        policy['remote_worker']=config.get('remote_worker',False)
        policy['family_rooms']=sorted(self.family_rooms)
        policy['family_users']=sorted(self.family_users)
        policy['family_devices']=self.family_devices
        old=self.store.get_meta('policy')
        if old is not None:
            old.setdefault('remote_worker',False)
            # Stage-1 predecessors had no family settings; empty is the safe upgrade.
            old.setdefault('family_rooms',[])
            old.setdefault('family_users',[])
            old.setdefault('family_devices',{})
        if old is not None and old!=policy:
            self.store.close()
            raise SafetyStop('saved-policy-changed')
        self.store.set_meta('policy',policy)
        # Family rooms reuse fleet_core mention admission; direct rooms are unchanged.
        self.policy=Policy(config['account'],self.senders,frozenset([config['account']]),
                           {r:'mention' if r in self.family_rooms else 'direct' for r in config['rooms']},
                           config['not_before_ms'])
        self.blocked=set(self.store.get_meta('room_gate_blocked') or ())
        self.room_members={}
        self.client=self.http=self.proc=self.active=None
        self.approvals=set()
        self.matrix_lock=asyncio.Lock()
        self.worker_input_lock=asyncio.Lock()
        self.stopping=False

    async def raw(self,method,path,data=None,params=None):
        import aiohttp
        async with self.http.request(method,self.c['homeserver'].rstrip('/')+path,json=data,
                                     params=params,allow_redirects=False) as response:
            if response.status in (429,500,502,503,504):raise ConnectionError('matrix-temporary-error')
            if response.status!=200:raise SafetyStop('matrix-http-'+str(response.status))
            body=bytearray()
            async for chunk in response.content.iter_chunked(65_536):
                body.extend(chunk)
                if len(body)>4_194_304:raise SafetyStop('matrix-response-too-large')
            return json.loads(body)

    async def open(self,initialize=False):
        import aiohttp
        from nio import AsyncClient,AsyncClientConfig,SyncResponse
        root=Path(self.c['state_directory'])
        self.store.storage_gate()
        crypto=root/'crypto'
        fd=private_directory(crypto)
        try:
            for name in os.listdir(fd):
                st=os.stat(name,dir_fd=fd,follow_symlinks=False)
                if (not stat.S_ISREG(st.st_mode) or st.st_nlink!=1 or st.st_uid!=os.getuid()
                        or stat.S_IMODE(st.st_mode)!=0o600):raise SafetyStop('unsafe-crypto-store')
            old=self.store.get_meta('device_identity')
            if old is None and (not initialize or os.listdir(fd)):
                raise SafetyStop('explicit-new-device-initialization-required')
        finally:os.close(fd)
        self.http=aiohttp.ClientSession(headers={'Authorization':'Bearer '+self.c['access_token']},
                                        timeout=aiohttp.ClientTimeout(total=40))
        who=await self.raw('GET','/_matrix/client/v3/account/whoami')
        if who.get('user_id')!=self.c['account'] or who.get('device_id')!=self.c['device_id']:
            raise SafetyStop('credential-device-mismatch')
        self.client=AsyncClient(self.c['homeserver'],self.c['account'],device_id=self.c['device_id'],
            store_path=str(crypto),config=AsyncClientConfig(pickle_key=self.c['pickle_key'],
            store_sync_tokens=False,max_timeouts=0,max_limit_exceeded=0,request_timeout=35))
        self.client.restore_login(self.c['account'],self.c['device_id'],self.c['access_token'])
        identity={'account':self.c['account'],'device':self.c['device_id'],
                  'keys':self.client.olm.account.identity_keys,
                  'credential_hash':hashlib.sha256(self.c['access_token'].encode()).hexdigest(),
                  'homeserver':self.c['homeserver']}
        if old is not None and old!=identity:raise SafetyStop('crypto-identity-or-token-drift')
        self.store.set_meta('device_identity',identity)
        if self.client.should_upload_keys:
            if type(await self.client.keys_upload()).__name__!='KeysUploadResponse':raise SafetyStop('key-upload-failed')
        # Rebuild volatile room state before replaying an incremental saved batch.
        join={}
        for room in self.c['rooms']:
            events=await self.raw('GET','/_matrix/client/v3/rooms/'+quote(room,safe='')+'/state')
            join[room]={'state':{'events':events},'timeline':{'events':[],'limited':False},
                        'ephemeral':{'events':[]},'account_data':{'events':[]},'unread_notifications':{}}
        await self.client.receive_response(SyncResponse.from_dict({'next_batch':'prime-'+str(time.time_ns()),
            'rooms':{'join':join},'to_device':{'events':[]},'device_one_time_keys_count':{}}))
        await self.pin_devices()
        for room in self.c['rooms']:await self.room_gate(room)
        self.store.set_meta('health',{'state':'ready','updated':time.time()})

    async def pin_devices(self):
        from nio import KeysQueryResponse
        query={self.c['account']:[],self.c['owner']:[],**{u:[] for u in self.family_users}}
        raw=await self.raw('POST','/_matrix/client/v3/keys/query',{'device_keys':query})
        response=KeysQueryResponse.from_dict(raw)
        if type(response).__name__!='KeysQueryResponse':raise SafetyStop('device-query-failed')
        await self.client.receive_response(response)
        devices=raw.get('device_keys',{}).get(self.c['owner'],{})
        if set(devices)!=set(self.c['devices']):raise SafetyStop('owner-device-set-changed')
        own=raw.get('device_keys',{}).get(self.c['account'],{})
        if set(own)!={self.c['device_id']}:raise SafetyStop('unexpected-agent-device')
        for kind,key in self.client.olm.account.identity_keys.items():
            if own[self.c['device_id']].get('keys',{}).get(kind+':'+self.c['device_id'])!=key:
                raise SafetyStop('published-agent-key-changed')
        for device,pin in self.c['devices'].items():
            stored=self.client.device_store[self.c['owner']][device]
            if stored.ed25519!=pin['ed25519'] or stored.curve25519!=pin['curve25519']:
                raise SafetyStop('owner-device-key-changed')
            self.client.verify_device(stored)
        # Family devices are pinned per user. Each user keeps the strict pin
        # check, while extra unpinned family devices stay merely untrusted and
        # are handled by exclude_unpinned_devices at session-share time.
        for user,pins in sorted(self.family_devices.items()):
            for device,pin in pins.items():
                stored=self.client.device_store[user].get(device)
                if stored is None:raise SafetyStop('pinned-device-missing')
                if stored.ed25519!=pin['ed25519'] or stored.curve25519!=pin['curve25519']:
                    raise SafetyStop('pinned-device-key-changed')
                self.client.verify_device(stored)

    async def room_gate(self,room):
        from nio import JoinedMembersResponse
        path='/_matrix/client/v3/rooms/'+quote(room,safe='')
        members=await self.raw('GET',path+'/joined_members')
        joined=set(members.get('joined',{}))
        if room not in self.family_rooms and joined!={self.c['owner'],self.c['account']}:
            raise SafetyStop('private-room-membership-changed')
        await self.client.receive_response(JoinedMembersResponse.from_dict(members,room))
        encryption=await self.raw('GET',path+'/state/m.room.encryption')
        if encryption.get('algorithm')!='m.megolm.v1.aes-sha2':raise SafetyStop('encrypted-room-required')
        if room not in self.client.rooms or not self.client.rooms[room].encrypted:
            raise SafetyStop('sdk-encryption-state-missing')
        users=set(self.client.rooms[room].users)
        if room in self.family_rooms:
            # A family room fails closed per room: exactly one bot plus the
            # allowlisted family members. An unauthorized member mutes only
            # that room and is recorded in state; no plaintext fallback exists.
            if (self.c['account'] not in joined or not joined<=self.family_allowed
                    or self.c['account'] not in users or not users<=self.family_allowed):
                self.block_room(room,joined)
                return False
            self.unblock_room(room)
            self.room_members[room]=joined
            await self.family_notice(room)
            return True
        if users!={self.c['owner'],self.c['account']}:
            raise SafetyStop('sdk-room-membership-changed')
        self.room_members[room]=joined
        return True

    def block_room(self,room,members):
        state=self.store.get_meta('room_gate_blocked') or {}
        record={'reason':'unauthorized-room-member','members':sorted(members)}
        if state.get(room)!=record:
            state[room]=record
            self.store.set_meta('room_gate_blocked',state)
        self.blocked.add(room)

    def unblock_room(self,room):
        if room not in self.blocked:return
        state=self.store.get_meta('room_gate_blocked') or {}
        state.pop(room,None)
        self.store.set_meta('room_gate_blocked',state)
        self.blocked.discard(room)

    async def family_notice(self,room):
        # First healthy join posts the disclosure notice once per room. The
        # saved marker plus the notice dedup keep it from ever repeating.
        sent=self.store.get_meta('family_room_notice') or {}
        if room in sent:return
        req=Request('$family-join-'+hashlib.sha256(room.encode()).hexdigest()[:32],room,
                    self.c['account'],'family-join',
                    hashlib.sha256(json.dumps([self.c['account'],room,'family-notice']).encode()).hexdigest())
        self.store.notice(req,'family-join',self.c.get('family_notice_text') or FAMILY_NOTICE)
        sent[room]=True
        self.store.set_meta('family_room_notice',sent)

    def as_request(self,job):
        return Request(job['event_id'],job['room_id'],job['sender'],job['body'],job['scope'])

    async def input(self,req):
        if self.store.seen_control(req,record=False):return
        if req.body.startswith(('/approve','/deny','/cancel','/ack')):
            await self.control(req)
            return
        try:self.store.accept_batch([req],None)
        except QueueFull:
            # Reject visibly and durably, so a full ordinary queue cannot stop
            # later syncs from carrying cancellation/approval controls.
            if not self.store.seen_control(req):
                self.store.notice(req,'queue-full','대기 중인 요청이 많습니다. 잠시 후 다시 요청해 주세요.')

    async def control(self,req):
        if self.store.seen_control(req):return
        fields=req.body.split()
        if len(fields)==2 and fields[0]=='/ack':
            job=next((j for j in self.store.uncertain() if turn_id(j['event_id'])==fields[1] and j['scope']==req.scope),None)
            if job:
                self.store.resolve_uncertain(job['event_id'],'이전 작업의 결과 확인을 완료한 것으로 기록했습니다. 자동 재실행은 하지 않습니다.')
                return
        allowed=False
        if self.active and self.proc and self.proc.returncode is None and self.active['scope']==req.scope:
            tid=turn_id(self.active['event_id'])
            if len(fields)==2 and fields==['/cancel',tid]:
                command={'type':'cancel','turn_id':tid};allowed=True
            elif (len(fields)==3 and fields[0] in ('/approve','/deny') and fields[1]==tid and fields[2] in self.approvals):
                command={'type':fields[0][1:],'turn_id':tid,'approval_id':fields[2]};allowed=True
                self.approvals.remove(fields[2])
            if allowed:
                await self.write_worker(command)
                self.store.notice(req,'control','요청을 전달했습니다. 실제 처리 결과는 이어지는 안내를 확인해 주세요.')
                return
        self.store.notice(req,'invalid-control','현재 이 대화방에서 처리할 수 있는 제어 요청이 아닙니다. 작업 번호와 승인 번호를 확인해 주세요.')

    async def receive(self):
        while True:
            self.store.storage_gate()
            raw=self.store.get_meta('pending_sync')
            if raw is None:
                params={'timeout':'25000','filter':json.dumps({'room':{'rooms':self.c['rooms'],
                    'timeline':{'limit':100},'ephemeral':{'types':[]}},'presence':{'types':[]}})}
                if self.store.token():params['since']=self.store.token()
                raw=await self.raw('GET','/_matrix/client/v3/sync',params=params)
                self.store.stage_sync(raw)
            await self.process_pending()

    async def process_pending(self):
        from nio import SyncResponse
        raw=self.store.get_meta('pending_sync')
        if raw is None:return
        async with self.matrix_lock:
            for room,info in raw.get('rooms',{}).get('join',{}).items():
                if room in self.c['rooms'] and info.get('timeline',{}).get('limited'):
                    raise SafetyStop('timeline-gap-requires-backfill')
            await self.pin_devices()
            response=SyncResponse.from_dict(raw)
            if type(response).__name__!='SyncResponse':raise SafetyStop('invalid-sync-response')
            self.client.next_batch=None  # Replay pending raw after a failed receive.
            await self.client.receive_response(response)
            for room in self.c['rooms']:await self.room_gate(room)
            for room,info in response.rooms.join.items():
                if room not in self.c['rooms']:continue
                for event in info.timeline.events:
                    req=self.admit_event(room,event)
                    if req:await self.input(req)
            self.store.commit_sync(raw['next_batch'])
            if self.client.should_upload_keys:
                if type(await self.client.keys_upload()).__name__!='KeysUploadResponse':raise SafetyStop('key-upload-failed')
            self.store.set_meta('health',{'state':'ready','updated':time.time()})

    def admit_event(self,room,event):
        """Admit only decrypted text from allowed senders' verified pinned devices."""
        from nio import MegolmEvent,RoomMessageText
        if event.sender not in self.senders or room in self.blocked:return None
        if event.server_timestamp < self.c['not_before_ms']:return None
        if isinstance(event,MegolmEvent):raise SafetyStop('undecrypted-event')
        if not isinstance(event,RoomMessageText):return None
        if not event.decrypted:return None  # No plaintext task execution.
        pins=self.pins.get(event.sender)
        if not event.verified or not pins or event.sender_key not in {v['curve25519'] for v in pins.values()}:
            raise SafetyStop('unverified-owner-event' if event.sender==self.c['owner']
                             else 'unverified-family-event')
        return self.policy.admit(room,event.source,decrypted=event.decrypted,now_ms=int(time.time()*1000))

    async def send(self):
        while True:
            for job in self.store.outbox():
                if job['room_id'] in self.blocked:continue  # Muted room keeps its pending replies.
                async with self.matrix_lock:
                    await self.pin_devices()
                    if not await self.room_gate(job['room_id']):continue
                    chunks=parts(job['reply'])
                    for i in range(self.store.delivered_parts(job['event_id']),len(chunks)):
                        tx=hashlib.sha256((job['txn_id']+':'+str(i)).encode()).hexdigest()
                        await self.encrypted_send(job['room_id'],chunks[i],tx)
                        self.store.mark_part(job['event_id'],i+1)
                    self.store.delivered(job['event_id'])
            await asyncio.sleep(.25)

    async def encrypted_send(self,room,text,txn):
        # nio 0.25.2 room_send ignores incomplete key sharing. Confirm every
        # pinned recipient before encrypting, and avoid its implicit queries.
        if self.client.olm.should_share_group_session(room):
            if room in self.family_rooms:self.exclude_unpinned_devices(room)
            await self.client.share_group_session(room)
        session=self.client.olm.outbound_group_sessions.get(room)
        expected=self.expected_recipients(room)
        if session is None or session.users_shared_with!=expected:
            self.client.invalidate_outbound_session(room)
            raise ConnectionError('group-key-share-incomplete')
        kind,content=self.client.encrypt(room,'m.room.message',{'msgtype':'m.text','body':text})
        if kind!='m.room.encrypted':raise SafetyStop('plaintext-output-refused')
        result=await self.raw('PUT','/_matrix/client/v3/rooms/'+quote(room,safe='')+
                              '/send/m.room.encrypted/'+txn,data=content)
        bounded_text(result.get('event_id'),255)

    def expected_recipients(self,room):
        """Pinned devices of every room member; direct rooms keep owner-only pins."""
        members=self.room_members.get(room,frozenset([self.c['owner'],self.c['account']]))
        return {(user,device) for user in members if user!=self.c['account']
                for device in self.pins.get(user,{})}

    def exclude_unpinned_devices(self,room):
        # Unpinned family devices never receive megolm sessions; the warning is
        # recorded in state, while sending still waits for every pinned device.
        unpinned={}
        for user in self.room_members.get(room,()):
            if user==self.c['account']:continue
            missing=sorted(d for d in self.client.device_store[user] if d not in self.pins.get(user,{}))
            if missing:unpinned[user]=missing
        if unpinned:
            warnings=self.store.get_meta('family_room_devices') or {}
            if warnings.get(room)!=unpinned:
                warnings[room]=unpinned
                self.store.set_meta('family_room_devices',warnings)
        for user,devices in unpinned.items():
            for device in devices:
                self.client.blacklist_device(self.client.device_store[user][device])

    async def write_worker(self,command):
        payload=(json.dumps(command,ensure_ascii=False)+'\n').encode()
        if len(payload)>65_536:raise SafetyStop('worker-frame-too-large')
        async with self.worker_input_lock:
            self.proc.stdin.write(payload)
            await asyncio.wait_for(self.proc.stdin.drain(),5)

    async def heartbeat(self):
        while True:
            await asyncio.sleep(5)
            await self.write_worker({'type':'heartbeat'})

    async def work(self):
        while True:
            # Do not overlap unknown prior execution after frontend restart.
            if self.store.uncertain():
                for job in self.store.uncertain():
                    self.store.notice(self.as_request(job),'uncertain',
                        '작업이 중단되어 결과 확인이 필요합니다. 자동으로 다시 실행하지 않습니다.\n'
                        '결과를 확인한 뒤 다음 명령으로 대기를 해제할 수 있습니다:\n/ack '+turn_id(job['event_id']))
                await asyncio.sleep(.25);continue
            job=self.store.claim()
            if not job:await asyncio.sleep(.25);continue
            self.active=job;self.approvals=set()
            result=None;heartbeat=None
            try:
                self.proc=await asyncio.create_subprocess_exec(*self.c['worker_argv'],stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL,limit=524_289,start_new_session=True)
                tid=turn_id(job['event_id'])
                await self.write_worker({'type':'turn','turn_id':tid,'prompt':job['body'],
                                         'session_id':self.store.session(job['scope'])})
                if self.c.get('remote_worker'):heartbeat=asyncio.create_task(self.heartbeat())
                self.store.notice(self.as_request(job),'started','작업을 시작했습니다. 취소 명령:\n/cancel '+tid)
                async with asyncio.timeout(1200):
                    while frame:=await self.proc.stdout.readline():
                        if len(frame)>524_288:raise SafetyStop('worker-output-too-large')
                        msg=json.loads(frame)
                        if msg.get('turn_id')!=tid:raise SafetyStop('worker-turn-mismatch')
                        if msg.get('type')=='approval':
                            nonce=msg.get('approval_id','')
                            text=msg.get('description','')+'\n'+json.dumps(msg.get('arguments'),ensure_ascii=False)
                            if not re.fullmatch(r'[A-Za-z0-9_-]{20,64}',nonce):raise SafetyStop('invalid-worker-approval')
                            if len(text.encode())>12_000 or len(self.approvals)>=16:
                                await self.write_worker({'type':'deny','turn_id':tid,'approval_id':nonce})
                            else:
                                self.approvals.add(nonce)
                                self.store.notice(self.as_request(job),'approval-'+nonce,text+
                                    '\n승인: /approve '+tid+' '+nonce+'\n거절: /deny '+tid+' '+nonce)
                        elif msg.get('type')=='result':result=msg;break
                        elif msg.get('type')=='approval-resolved':
                            self.approvals.discard(msg.get('approval_id'))
                        elif msg.get('type')=='session':
                            sid=bounded_text(msg.get('session_id'),255)
                            self.store.set_meta('active_session',{'event_id':job['event_id'],'session_id':sid})
            finally:
                self.active=None;self.approvals=set()
                if heartbeat:heartbeat.cancel()
                interrupted={'value':isinstance(sys.exc_info()[1],asyncio.CancelledError)}
                cleanup=asyncio.create_task(self.cleanup_worker(job,result,interrupted,heartbeat))
                # TaskGroup/SIGTERM can cancel during finally itself. Keep one
                # cleanup task alive and join it, including repeated cancels.
                while not cleanup.done():
                    try:await asyncio.shield(cleanup)
                    except asyncio.CancelledError:
                        interrupted['value']=True
                        self.store.uncertain_job(job['event_id'])
                cleanup.result()
                if interrupted['value']:raise asyncio.CancelledError

    async def cleanup_worker(self,job,result,interrupted,heartbeat=None):
        self.store.set_meta('worker_cleanup_in_progress',True)
        confirmed=False
        try:
            if heartbeat:await asyncio.gather(heartbeat,return_exceptions=True)
            if self.proc:
                if self.proc.stdin:self.proc.stdin.close()
                remote=None
                async def closed():
                    nonlocal remote
                    if self.c.get('remote_worker'):
                        size=0
                        for _ in range(32):
                            line=await self.proc.stdout.readline();size+=len(line)
                            if len(line)>524_288 or size>1_048_576:raise SafetyStop('remote-close-too-large')
                            msg=json.loads(line) if line else None
                            if not isinstance(msg,dict) or msg.get('type')=='remote_closed':
                                remote=msg;break
                            # A control acknowledgement may race the result.
                            if msg.get('type') not in ('control','approval-resolved') or msg.get('turn_id')!=turn_id(job['event_id']):
                                raise SafetyStop('unexpected-remote-output')
                        else:raise SafetyStop('remote-close-missing')
                        if await self.proc.stdout.read(1):raise SafetyStop('extra-remote-output')
                    await self.proc.wait()
                try:await asyncio.wait_for(closed(),25)
                except Exception:
                    try:os.killpg(self.proc.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
                    await self.proc.wait()
                else:
                    confirmed=bool(result and (
                        (result.get('status')=='complete' and self.proc.returncode==0) or
                        (result.get('status')=='uncertain' and result.get('runtime_closed') is True)))
                    if self.c.get('remote_worker'):
                        confirmed=confirmed and bool(isinstance(remote,dict) and remote.get('type')=='remote_closed'
                            and remote.get('turn_id')==turn_id(job['event_id']) and remote.get('clean') is True
                            and remote.get('group_empty') is True and self.proc.returncode==0
                            and remote.get('worker_exit')==(0 if result.get('status')=='complete' else 1))
            if confirmed and result.get('status')=='complete' and not interrupted['value']:
                self.store.finish(job['event_id'],result['text'],result.get('session_id'))
        finally:
            self.store.uncertain_job(job['event_id'])
            self.proc=None
            self.store.set_meta('worker_cleanup_in_progress',False)
            if not confirmed:self.store.set_meta('worker_cleanup_unconfirmed',True)
        if not confirmed:raise SafetyStop('worker-cleanup-unconfirmed')

    async def retry(self,operation):
        import aiohttp
        delay=1
        while True:
            try:await operation();return
            except (ConnectionError,aiohttp.ClientError,TimeoutError):
                self.store.set_meta('health',{'state':'network-retry','updated':time.time()})
                await asyncio.sleep(delay);delay=min(delay*2,30)

    async def run(self):
        if self.store.get_meta('worker_cleanup_unconfirmed') or self.store.get_meta('worker_cleanup_in_progress'):
            raise SafetyStop('worker-cleanup-unconfirmed')
        async with asyncio.TaskGroup() as group:
            group.create_task(self.retry(self.receive))
            group.create_task(self.retry(self.send))
            group.create_task(self.work())

    async def close(self):
        if self.client:await self.client.close()
        if self.http:await self.http.close()
        self.store.close()


async def main(args):
    os.umask(0o077)
    frontend=Frontend(load_config(args.config))
    task=asyncio.current_task()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM,task.cancel)
    try:
        await frontend.open(initialize=args.initialize)
        if not args.initialize:await frontend.run()
    except BaseException as exc:
        frontend.store.set_meta('health',{'state':'stopped','reason':stop_reason(exc),'updated':time.time()})
        raise
    finally:await frontend.close()


def stop_reason(exc):
    if isinstance(exc,BaseExceptionGroup):
        return next((stop_reason(e) for e in exc.exceptions if stop_reason(e)!='unexpected-failure'),'unexpected-failure')
    if isinstance(exc,SafetyStop):return str(exc)
    if isinstance(exc,asyncio.CancelledError):return 'service-stopped'
    return 'unexpected-failure'


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',required=True)
    parser.add_argument('--initialize',action='store_true')
    args=parser.parse_args()
    logging.basicConfig(level=logging.CRITICAL)
    try:asyncio.run(main(args))
    except (asyncio.CancelledError,KeyboardInterrupt):
        sys.exit(0)
    except BaseException as exc:
        print('Matrix pilot stopped; inspect private health and replay state.',file=sys.stderr)
        sys.exit(78 if stop_reason(exc)!='unexpected-failure' else 75)
