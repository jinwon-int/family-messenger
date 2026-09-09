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
    parser.add_argument('--successor', action='store_true', help='version-2 public intent/retirement process proof')
    args = parser.parse_args()
    binary, policy_binary = args.binary.resolve(strict=True), args.policy_binary.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    work = Path(tempfile.mkdtemp(prefix='native-successor-' if args.successor else 'native-policy-', dir=root / 'artifacts'))
    auth, state, proposals = [work / x for x in ('auth', 'state', 'proposals')]
    for directory in (auth, state, proposals):
        directory.mkdir(mode=0o700)
    proof = {'synthetic_only': True, 'production_cf_gate': False, 'e2ee': False,
             'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
             'policy_binary_sha256': hashlib.sha256(policy_binary.read_bytes()).hexdigest()}
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
    if args.successor:
        config['devices'] = []
        for number, person in enumerate(config['people'], 1):
            public = bytes([number]) * 32  # public policy fixture, no MLS key possession claim
            config['devices'].append({'device_id': person['actor'] + '-first', 'actor': person['actor'],
                'subject': person['subject'], 'signing_key': public.hex(), 'fingerprint': hashlib.sha256(public).hexdigest(),
                'status': 'active', 'device_revision': 1, 'acceptance': 'out-of-band-fingerprint'})
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
        process = subprocess.Popen([str(binary), '--synthetic-only', '--state', str(state), '--auth-state', str(auth), '--listen', address], stdout=subprocess.DEVNULL, stderr=output)
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

    def wait_status(who, status):
        until = time.monotonic() + 6
        while time.monotonic() < until:
            if request(who)[0] == status:
                return
            time.sleep(0.05)
        raise AssertionError('auth policy was not applied')

    try:
        # Selected but missing/empty auth config never initializes fixture auth.
        start(False)
        result = subprocess.run([str(binary), '--synthetic-only', '--state', str(state), '--auth-state', ''], capture_output=True, timeout=5)
        assert result.returncode != 0 and b'listening' not in result.stderr
        assert not list(state.iterdir())
        commit(0, initial)
        start()
        assert request('owner', method='POST', obj={'id': 'family', 'members': ['bob']})[0] == 201
        message = {'client_id': 'retained', 'payload': base64.b64encode(b'synthetic retained message').decode()}
        assert request('family', '/v1/rooms/family/messages', 'POST', obj=message)[0] == 201
        blob = b'synthetic policy restart attachment'
        headers = {'Content-Type': 'application/octet-stream', 'X-Upload-ID': 'retained-file', 'X-File-Name': 'test.bin', 'X-Content-SHA256': hashlib.sha256(blob).hexdigest()}
        code, raw = request('owner', '/v1/rooms/family/attachments', 'POST', body=blob, headers=headers)
        assert code == 201
        media = json.loads(raw)
        path = '/v1/rooms/family/attachments/' + media['id']
        assert request('family', path) == (200, blob)
        assert request(None, headers={'Authorization': 'Bearer synthetic-alice'})[0] == 401
        assert request(None, headers={'Cf-Access-Authenticated-User-Email': 'owner@example.invalid'})[0] == 401
        proof['explicit_signed_mode_and_no_fixture_fallback'] = True

        if args.successor:
            from native_successor_checks import run
            run(config, auth, proposals, proof, request, start, stop, command, private_write, blob, path)
            proof['ok'] = True
            return

        old = (auth / 'policy-000001.json').read_bytes()
        commit(1, revoked)
        wait_status('family', 401)
        stop()
        start()
        assert request('family', path)[0] == 401
        assert request('owner', path) == (200, blob)
        history = json.loads(request('owner', '/v1/rooms/family/messages')[1])
        assert len(history) == 1 and history[0]['client_id'] == 'retained'
        assert (auth / 'policy-000001.json').read_bytes() == old
        proof['revocation_survives_sigkill_restart_preserving_chat_media_and_history'] = True

        commit(2, initial)
        wait_status('family', 200)
        latest = auth / 'policy-000003.json'
        latest.chmod(0o644)
        wait_status('owner', 401)
        latest.chmod(0o600)
        time.sleep(1.2)
        assert request('owner')[0] == 401, 'same revision silently resumed after failure'
        commit(3, revoked)
        wait_status('owner', 200)
        assert request('family')[0] == 401
        proof['unsafe_reload_suspends_until_newer_valid_revision'] = True

        # Simulate damaged current state and preserve its bytes: do not fall back
        # to an earlier, otherwise valid enrollment on reload or restart.
        latest = auth / 'policy-000004.json'
        intact = latest.read_bytes()
        latest.write_bytes(b'corrupt synthetic policy')
        wait_status('owner', 401)
        stop()
        start(False)
        assert latest.read_bytes() == b'corrupt synthetic policy'
        # Test-only explicit repair and fresh decision; no product auto-restore.
        private_write(proposals / 'damaged-record.bin', latest.read_bytes())
        latest.write_bytes(intact)
        commit(4, revoked)
        start()
        assert request('family')[0] == 401
        proof['malformed_latest_never_falls_back_and_evidence_preserved'] = True

        before = {p.name: p.read_bytes() for p in auth.glob('policy-*.json')}
        processes = [subprocess.Popen(command(5, revoked), stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        results = [(p, p.communicate(timeout=10)) for p in processes]
        assert sorted(p.returncode for p, _ in results) == [0, 1]
        winner = [data[0] for p, data in results if p.returncode == 0][0]
        assert json.loads(winner)['revision'] == 6
        assert all((auth / name).read_bytes() == data for name, data in before.items())
        assert len(list(auth.glob('policy-*.json'))) == 6
        proof['two_process_compare_and_swap_no_lost_update_or_overwrite'] = True

        # Generated lease metadata exercises the actual CLI/server boundary;
        # separate Go tests acquire the same shape through real synthetic TLS.
        leased = json.loads(revoked.read_bytes())
        leased['keys_fetched_at'] = int(time.time()) - 3601
        leased['keys_expire_at'] = leased['keys_fetched_at'] + 3600
        expired = proposals / 'expired-keys.json'
        private_write(expired, json.dumps(leased).encode())
        commit(6, expired)
        wait_status('owner', 401)
        stop()
        start()
        assert request('owner')[0] == 401
        assert request('family')[0] == 401
        stale_fetch = subprocess.run([str(policy_binary), '--synthetic-only', '--auth-state', str(auth),
                                      '--fetch-keys', '--expected-revision', '6'], capture_output=True, timeout=5)
        assert stale_fetch.returncode != 0 and b'revision conflict' in stale_fetch.stderr
        mixed_fetch = subprocess.run([str(policy_binary), '--synthetic-only', '--auth-state', str(auth),
                                      '--fetch-keys', '--inspect'], capture_output=True, timeout=5)
        assert mixed_fetch.returncode != 0
        leased['keys_fetched_at'] = int(time.time())
        leased['keys_expire_at'] = leased['keys_fetched_at'] + 3600
        fresh = proposals / 'fresh-keys.json'
        private_write(fresh, json.dumps(leased).encode())
        commit(7, fresh)
        wait_status('owner', 200)
        assert request('family')[0] == 401
        assert request('owner', path) == (200, blob)
        assert (auth / 'policy-000001.json').read_bytes() == old
        proof['expired_key_lease_denies_after_restart_new_lease_preserves_enrollment_and_media'] = True
        proof['fetch_cli_stale_revision_and_mixed_modes_rejected'] = True
        proof['ok'] = True
    finally:
        stop()
        (work / 'verification.json').write_text(json.dumps(proof, indent=2) + '\n')
        if args.successor:
            print(work / 'verification.json')
    print(work / 'verification.json')

if __name__ == '__main__':
    os.umask(0o077)
    main()
