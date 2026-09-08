#!/usr/bin/env python3
"""Preview-only API integration tests. Does not prove client E2EE decryption."""
import json
from pathlib import Path
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'scripts'))
from admin import request,create_user

meta=json.loads((ROOT/'.runtime/installation.json').read_text())
assert meta['mode']=='preview' and meta['server_name']=='preview.invalid','Never run test account creation on production'
suffix=secrets.token_hex(4)
users=[create_user('test_'+n+'_'+suffix,secrets.token_urlsafe(24)) for n in ('alice','bob','outsider')]
a,b,outsider=users;passed=[]

def denied(path,token=None,data=None,method=None,expected=(401,403,404)):
    try:request(path,data,token,method)
    except urllib.error.HTTPError as e:assert e.code in expected,(path,e.code);return
    raise AssertionError('Unauthorised request unexpectedly succeeded: '+path)

denied('/_matrix/client/v3/register',data={'username':'public_signup','password':secrets.token_urlsafe(24)},expected=(403,))
passed.append('public registration disabled')
room=request('/_matrix/client/v3/createRoom',{'preset':'private_chat','name':'API integration fixture','invite':[b['user_id']],
              'creation_content':{'m.federate':False}},a['access_token'])['room_id']
rid=urllib.parse.quote(room,safe='')
request('/_matrix/client/v3/join/'+rid,{},b['access_token'])
denied('/_matrix/client/v3/join/'+rid,outsider['access_token'],{},expected=(403,))
denied('/_matrix/client/v3/rooms/'+rid+'/messages?dir=b',outsider['access_token'],expected=(403,))
passed.append('invited member joins; outsider cannot join/read private room')
encryption=request('/_matrix/client/v3/rooms/'+rid+'/state/m.room.encryption/',token=a['access_token'])
assert encryption['algorithm']=='m.megolm.v1.aes-sha2';passed.append('new private room has encryption enabled')
# Opaque encrypted-event fixture: verifies routing/idempotency only, not cryptography.
payload={'algorithm':'m.megolm.v1.aes-sha2','session_id':'fixture','ciphertext':'dGVzdA==','device_id':'FIXTURE','sender_key':'fixture'}
path='/_matrix/client/v3/rooms/'+rid+'/send/m.room.encrypted/fixture_'+suffix
e1=request(path,payload,a['access_token'],'PUT')['event_id'];e2=request(path,payload,a['access_token'],'PUT')['event_id']
assert e1==e2;passed.append('retry transaction is idempotent')
sync=request('/_matrix/client/v3/sync?timeout=0',token=b['access_token'])
events=sync['rooms']['join'][room]['timeline']['events'];assert any(e['event_id']==e1 for e in events)
passed.append('invited member receives encrypted-event fixture through sync')
req=urllib.request.Request('http://127.0.0.1:18809/_matrix/media/v3/upload?filename=fixture.txt',data=b'private synthetic attachment',headers={'Authorization':'Bearer '+a['access_token'],'Content-Type':'text/plain'})
op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
with op.open(req,timeout=20) as r:uri=json.load(r)['content_uri']
server,media=uri[6:].split('/',1)
download='/_matrix/client/v1/media/download/'+server+'/'+media
denied(download,expected=(401,))
with op.open(urllib.request.Request('http://127.0.0.1:18809'+download,headers={'Authorization':'Bearer '+b['access_token']}),timeout=20) as r:assert r.read()==b'private synthetic attachment'
passed.append('media requires authentication; authenticated fixture downloads correctly')
denied('/_matrix/federation/v1/version',expected=(404,))
passed.append('federation HTTP resource disabled')
print(json.dumps({'passed':passed,'count':len(passed),'client_encryption_decryption':'not covered'},ensure_ascii=False,indent=2))
