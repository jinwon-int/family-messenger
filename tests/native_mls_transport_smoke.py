#!/usr/bin/env python3
"""Private generated fixtures against only subprocesses spawned by this test."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--policy-binary', required=True, type=Path)
    parser.add_argument('--legacy-binary', type=Path)
    args = parser.parse_args()
    binary, policy_binary = args.binary.resolve(strict=True), args.policy_binary.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    work = Path(tempfile.mkdtemp(prefix='native-mls-transport-', dir=root / 'artifacts'))
    auth, state, proposals = [work / x for x in ('auth', 'state', 'proposals')]
    for directory in (auth, state, proposals):
        directory.mkdir(mode=0o700)
    proof = {'synthetic_only': True, 'production_cf_gate': False, 'e2ee': False,
             'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
             'policy_binary_sha256': hashlib.sha256(policy_binary.read_bytes()).hexdigest()}
    serving_binary = args.legacy_binary.resolve(strict=True) if args.legacy_binary else binary
    process = output = None
    log = work / 'server.log'
    address = '127.0.0.1:0'
    url = None

    def private_write(path, data):
        with path.open('xb') as f:
            f.write(data)
        path.chmod(0o600)

    # These keys are generated for this disposable test only and never uploaded
    # in CI artifacts. OpenSSL is test tooling, not a server runtime dependency.
    key = proposals / 'synthetic-private.pem'
    private_write(key, subprocess.check_output(['openssl', 'genpkey', '-algorithm', 'RSA',
                  '-pkeyopt', 'rsa_keygen_bits:2048'], stderr=subprocess.DEVNULL))
    modulus = subprocess.check_output(['openssl', 'rsa', '-in', str(key), '-noout', '-modulus'], stderr=subprocess.DEVNULL).decode().strip().split('=', 1)[1]
    b64 = lambda data: base64.urlsafe_b64encode(data).decode().rstrip('=')
    config = {'version': 1, 'issuer': 'https://synthetic.cloudflareaccess.com', 'audience': 'synthetic-app',
              'keys': [{'kid': 'test-key', 'n': b64(bytes.fromhex(modulus)), 'e': 65537}],
              'people': [{'subject': 'owner', 'actor': 'alice', 'owner': True},
                         {'subject': 'family', 'actor': 'bob', 'owner': False}]}
    tokens = {}
    for subject in ('owner', 'family'):
        now = int(time.time())
        claims = {'iss': config['issuer'], 'aud': [config['audience']], 'sub': subject,
                  'type': 'app', 'iat': now - 1, 'nbf': now - 1, 'exp': now + 300}
        unsigned = b64(json.dumps({'alg': 'RS256', 'typ': 'JWT', 'kid': 'test-key'}).encode()) + '.' + b64(json.dumps(claims).encode())
        signature = subprocess.check_output(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=unsigned.encode())
        tokens[subject] = unsigned + '.' + b64(signature)

    def candidate(name, include_bob):
        obj = dict(config)
        obj['people'] = config['people'] if include_bob else config['people'][:1]
        path = proposals / name
        private_write(path, json.dumps(obj).encode())
        return path

    config['devices'] = []
    for i,p in enumerate(config['people']):
        raw=bytes([i+1])*32
        config['devices'].append({'device_id':p['actor']+'-first','actor':p['actor'],'subject':p['subject'],'signing_key':raw.hex(),'fingerprint':hashlib.sha256(raw).hexdigest(),'status':'active','device_revision':1,'acceptance':'out-of-band-fingerprint'})
    initial = candidate('initial.json', True)
    revoked = candidate('revoked.json', False)
    def command(expected, path):
        return [str(policy_binary), '--synthetic-only', '--auth-state', str(auth), '--input', str(path), '--expected-revision', str(expected)]

    def commit(expected, path):
        result = subprocess.run(command(expected, path), capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        info = json.loads(result.stdout)
        assert info['revision'] == expected + 1
        return info

    def start(want_success=True):
        nonlocal process, output, address, url
        output = log.open('ab')
        offset = log.stat().st_size
        process = subprocess.Popen([str(serving_binary), '--synthetic-only', '--state', str(state), '--auth-state', str(auth), '--listen', address], stdout=subprocess.DEVNULL, stderr=output)
        if not want_success:
            assert process.wait(timeout=5) != 0
            assert b'listening' not in log.read_bytes()[offset:]
            output.close()
            return
        until = time.monotonic() + 5
        while time.monotonic() < until:
            if process.poll() is not None:
                raise RuntimeError('signed prototype exited before listening')
            match = re.search(r'listening (127\.0\.0\.1:\d+)', log.read_bytes()[offset:].decode())
            if match:
                address = match[1]
                url = 'http://' + address
                return
            time.sleep(0.02)
        raise RuntimeError('signed prototype start timeout')

    def stop():
        if process and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        if output:
            output.close()

    def request(who, path='/v1/rooms', method='GET', obj=None, body=None, headers=None):
        hs = {'Cf-Access-Jwt-Assertion': tokens[who], 'Content-Type': 'application/json'} if who else {}
        hs.update(headers or {})
        if obj is not None:
            body = json.dumps(obj).encode()
        req = urllib.request.Request(url + path, method=method, headers=hs, data=body)
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as e:
            response = e
        with response:
            return response.status, response.read()

    def call(who,path,method='GET',obj=None,want=200):
        actor='alice' if who=='owner' else 'bob'
        status,raw=request(who,path,method,obj,headers={'X-Family-Device':actor+'-first'})
        assert status==want,(path,status,want)
        return json.loads(raw) if status<300 else None
    try:
        commit(0,initial);start()
        call('owner','/v1/rooms','POST',{'id':'legacy','members':['bob']},201)
        call('owner','/v1/rooms/legacy/messages','POST',{'client_id':'old','payload':'eA=='},201)
        if args.legacy_binary:
            stop(); serving_binary=binary; start()
            import sqlite3
            snapshots=list((state/'snapshots').glob('v2-before-mls-*.sqlite'))
            assert len(snapshots)==1
            with sqlite3.connect(snapshots[0]) as old:
                assert old.execute('PRAGMA user_version').fetchone()[0]==2
                assert old.execute('SELECT count(*) FROM messages').fetchone()[0]==1
            proof['actual_v2_binary_migration_snapshot']=True
        call('owner','/v1/mls/reservations','POST',{'room':'secure','peer_actor':'bob'},201)
        call('family','/v1/rooms/secure/devices')
        call('owner','/v1/rooms/secure/messages','POST',{'client_id':'bad','payload':'eA=='},403)
        group='ab'*32
        bind={'room':'secure','group_id':group,'device_id':'alice-first','peer_device':'bob-first'}
        call('owner','/v1/mls/rooms','POST',bind,201)
        proof['reservation_binding_and_legacy_isolation']=True
        def q(id,who,kind,revision,epoch,target,raw):
            return {'client_id':id,'device_id':who+'-first','group_id':group,'kind':kind,'expected_revision':revision,'epoch':epoch,'target_device':target+'-first' if target else '', 'payload':base64.b64encode(raw).decode()}
        path='/v1/mls/rooms/secure/log'
        kp=q('kp','bob','key_package',0,0,'alice',b'synthetic package')
        call('family',path,'POST',kp,201)
        welcome=q('welcome','alice','welcome',1,0,'bob',bytes(range(256))*256)
        accepted=call('owner',path,'POST',welcome,201)
        stop();start()  # Actual SIGKILL after an accepted response, discarded by caller.
        assert call('owner',path,'POST',welcome)==accepted
        received=call('family',path+'?after=1')
        assert len(received)==1 and received[0]==accepted
        proof['targeted_welcome_and_exact_outcome_after_sigkill']=True
        premature=q('early','alice','application',2,1,'',b'opaque')
        call('owner',path,'POST',premature,409)
        ack=q('ack','bob','ack',2,1,'alice',b'');call('family',path,'POST',ack,201)
        data=q('file','alice','application',3,1,'',os.urandom(49152))
        accepted=call('owner',path,'POST',data,201)
        stop();start();assert call('owner',path,'POST',data)==accepted
        assert call('family',path+'?after=3')[0]==accepted
        proof['opaque_large_application_restart_history']=True
        control=q('commit','alice','commit',3,1,'bob',b'opaque commit')
        call('owner',path,'POST',control,201)
        stale=dict(data,client_id='stale');call('owner',path,'POST',stale,409)
        assert call('owner',path,'POST',data)==accepted
        proof['stale_epoch_denial_and_accepted_old_outcome_reconciliation']=True
        # An incomplete HTTP body cannot commit an event or hold policy authority.
        import socket
        sock=socket.create_connection(tuple([address.split(':')[0],int(address.split(':')[1])]))
        raw=json.dumps(data).encode()
        headers=(f'POST {path} HTTP/1.1\r\nHost: {address}\r\nCf-Access-Jwt-Assertion: {tokens["owner"]}\r\nX-Family-Device: alice-first\r\nContent-Type: application/json\r\nContent-Length: {len(raw)}\r\n\r\n').encode()
        sock.sendall(headers+raw[:20]);stop();sock.close();start()
        assert call('owner','/v1/mls/rooms/secure/status')['next_seq']==6
        proof['interrupted_body_sigkill_no_partial_event']=True
        assert len(call('family','/v1/rooms/legacy/messages'))==1
        config['devices'][1]['status']='revoked';config['devices'][1]['device_revision']=2
        revoked=candidate('device-revoked.json',True);commit(1,revoked)
        until=time.monotonic()+6
        while time.monotonic()<until:
            status,_=request('owner',path,'POST',data,headers={'X-Family-Device':'alice-first'})
            if status==403:break
            assert status in (200,401)
            time.sleep(.05)
        else:raise AssertionError('revocation timeout')
        stop();start();call('owner',path,'POST',data,403);call('family',path,want=403)
        proof['durable_revocation_denies_history_and_cached_retry']=True
        proof['passed']=True
    finally:
        stop()
        (work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n')
    print(work/'verification.json')

if __name__=='__main__': main()
