"""Real E2EE/restart proof using disposable preview identities only.

Requires matrix-nio[e2e] and a running loopback preview. No human login.
Pass --real-worker only on an explicitly authorized CCC node.
"""
import argparse
import asyncio
import json
import logging
import os
from pathlib import Path
import secrets
import sys
import tempfile
import time

import aiohttp
from nio import AsyncClient, AsyncClientConfig, RoomMessageText, SyncResponse
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from admin import create_user, local_base, request
from fleet_matrix import Frontend
from fleet_matrix_state import SafetyStop


async def main(real_worker=False):
    os.umask(0o077)
    meta=json.loads((ROOT/'.runtime/installation.json').read_text())
    assert meta['mode']=='preview' and meta['server_name']=='preview.invalid'
    (ROOT/'artifacts').mkdir(exist_ok=True)
    evidence=Path(tempfile.mkdtemp(prefix='frontend-live-',dir=ROOT/'artifacts'))
    base=local_base();suffix=secrets.token_hex(4)
    a=create_user('frontend_owner_'+suffix,secrets.token_urlsafe(32))
    b=create_user('frontend_bot_'+suffix,secrets.token_urlsafe(32))
    (evidence/'credentials.json').write_text(json.dumps([a,b]))
    crypto=evidence/'owner';crypto.mkdir(mode=0o700)
    owner=AsyncClient(base,a['user_id'],device_id=a['device_id'],store_path=str(crypto),
        config=AsyncClientConfig(pickle_key=secrets.token_urlsafe(32),store_sync_tokens=False,
                                max_timeouts=0,max_limit_exceeded=0,request_timeout=35))
    owner.restore_login(a['user_id'],a['device_id'],a['access_token'])
    received=[]
    async def callback(room,event):received.append(event)
    owner.add_event_callback(callback,RoomMessageText)
    frontend=task=None
    async def sync_owner():
        result=await owner.sync(timeout=500)
        assert type(result).__name__=='SyncResponse'
        if task and task.done():task.result()
        return result
    async def wait_reply(body):
        async with asyncio.timeout(180):
            while not any(e.sender==b['user_id'] and e.decrypted and e.body.strip()==body for e in received):
                await sync_owner()
            while any(j['reply'].strip()==body for j in frontend.store.outbox()):await asyncio.sleep(.05)
    async def shutdown():
        nonlocal task,frontend
        if task:
            task.cancel();await asyncio.gather(task,return_exceptions=True);task=None
        if frontend:await frontend.close();frontend=None
    try:
        assert type(await owner.keys_upload()).__name__=='KeysUploadResponse'
        await sync_owner()
        created=await owner.room_create(name='Synthetic persistent frontend proof',federate=False,is_direct=True,
            invite=[b['user_id']],initial_state=[{'type':'m.room.encryption','state_key':'',
                                                'content':{'algorithm':'m.megolm.v1.aes-sha2'}}])
        room=created.room_id
        request('/_matrix/client/v3/join/'+room,{},token=b['access_token'])
        work=evidence/'work';work.mkdir(mode=0o700)
        argv=([ '/opt/ccc-node/bridge/venv/bin/python',str(ROOT/'scripts/fleet_worker.py'),
                '--workdir',str(work),'--codex-cli','/root/.claude/hooks/ccc-codex','--turn-timeout','150']
              if real_worker else [sys.executable,str(ROOT/'tests/fixtures/matrix_worker.py'),'complete'])
        c=dict(homeserver=base,preview=True,account=b['user_id'],device_id=b['device_id'],
            access_token=b['access_token'],pickle_key=secrets.token_urlsafe(32),state_directory=str(evidence/'state'),
            owner=a['user_id'],rooms=[room],devices={a['device_id']:owner.olm.account.identity_keys},
            worker_argv=argv,not_before_ms=int(time.time()*1000)-1000)
        (evidence/'config.json').write_text(json.dumps(c))
        frontend=Frontend(c);await frontend.open(initialize=True)
        await sync_owner();await owner.joined_members(room);await owner.keys_query()
        device=owner.device_store[b['user_id']][b['device_id']]
        assert device.ed25519==frontend.client.olm.account.identity_keys['ed25519']
        assert device.curve25519==frontend.client.olm.account.identity_keys['curve25519']
        owner.verify_device(device)
        task=asyncio.create_task(frontend.run())
        request('/_matrix/client/v3/rooms/'+room+'/send/m.room.message/plaintext-probe',
                {'msgtype':'m.text','body':'This plaintext must not execute.'},token=a['access_token'],method='PUT')
        token='FRONTEND_'+secrets.token_hex(8) if real_worker else 'synthetic answer'
        sent=await owner.room_send(room,'m.room.message',{'msgtype':'m.text','body':
            'Reply only with '+token+'. Do not use tools or read files.'})
        assert type(sent).__name__=='RoomSendResponse'
        await wait_reply(token)
        raw=request('/_matrix/client/v3/rooms/'+room+'/event/'+sent.event_id,token=a['access_token'])
        assert raw['type']=='m.room.encrypted' and 'body' not in raw['content']
        assert not frontend.store.uncertain()
        sid=frontend.store.db.execute('SELECT session_id FROM sessions').fetchone()[0]
        await shutdown()
        # Crash window: SDK persisted to-device keys, durable raw pending exists,
        # but inbox/token commit has not happened yet. Reopen the actual SDK.
        second=await owner.room_send(room,'m.room.message',{'msgtype':'m.text','body':
            'Repeat only the exact token from the preceding turn. Do not use tools or read files.'})
        frontend=Frontend(c);await frontend.open()
        await frontend.process_pending()
        raw=await frontend.raw('GET','/_matrix/client/v3/sync',params={'timeout':'1000',
            'since':frontend.store.token(),'filter':json.dumps({'room':{'rooms':[room]}})})
        frontend.store.stage_sync(raw)
        frontend.client.next_batch=None
        await frontend.client.receive_response(SyncResponse.from_dict(raw))
        assert any(e.get('event_id')==second.event_id for e in raw['rooms']['join'][room]['timeline']['events'])
        await shutdown()
        previous=len([e for e in received if e.sender==b['user_id'] and e.body.strip()==token])
        frontend=Frontend(c);await frontend.open();task=asyncio.create_task(frontend.run())
        async with asyncio.timeout(180):
            while len([e for e in received if e.sender==b['user_id'] and e.body.strip()==token])<=previous:
                await sync_owner()
        await wait_reply(token)
        assert frontend.store.db.execute('SELECT session_id FROM sessions').fetchone()[0]==sid
        assert frontend.store.db.execute("SELECT count(*) FROM jobs WHERE body!='notice'").fetchone()[0]==2
        assert not frontend.store.uncertain()
        await shutdown()
        frontend=Frontend(c);await frontend.open();await frontend.process_pending()
        # A sync gap is preserved, never silently skipped.
        frontend.store.stage_sync({'next_batch':'synthetic-gap','rooms':{'join':{room:{'timeline':{'limited':True}}}}})
        try:await frontend.process_pending()
        except SafetyStop as exc:assert str(exc)=='timeline-gap-requires-backfill'
        else:raise AssertionError('gap accepted')
        assert frontend.store.get_meta('pending_sync')['next_batch']=='synthetic-gap'
        pin=c['devices'][a['device_id']]['ed25519']
        c['devices'][a['device_id']]['ed25519']='a'*43
        try:await frontend.pin_devices()
        except SafetyStop as exc:assert str(exc)=='owner-device-key-changed'
        else:raise AssertionError('wrong pin accepted')
        finally:c['devices'][a['device_id']]['ed25519']=pin
        stranger=create_user('frontend_stranger_'+suffix,secrets.token_urlsafe(32))
        await owner.room_invite(room,stranger['user_id'])
        request('/_matrix/client/v3/join/'+room,{},token=stranger['access_token'])
        try:await frontend.room_gate(room)
        except SafetyStop as exc:assert str(exc)=='private-room-membership-changed'
        else:raise AssertionError('extra room member accepted')
        proof=dict(persistent_frontend=True,actual_ccc_runtime=real_worker,encrypted_request=True,
            encrypted_reply=True,device_fingerprints_pinned=True,raw_pending_replay_after_sdk_restart=True,
            scoped_session_resume=True,no_duplicate_execution=True,plaintext_not_executed=True,
            sync_gap_preserved=True,wrong_device_pin_rejected=True,extra_member_rejected=True,
            scope='isolated loopback preview')
        (evidence/'verification.json').write_text(json.dumps(proof,indent=2))
        print(json.dumps({'ok':True,'evidence':str(evidence/'verification.json'),'checks':proof}))
    finally:
        await shutdown();await owner.close()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--real-worker',action='store_true')
    logging.basicConfig(level=logging.CRITICAL)
    asyncio.run(main(parser.parse_args().real_worker))
