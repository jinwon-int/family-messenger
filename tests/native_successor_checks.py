"""Generated public intent fixtures and actual signed loopback process admission."""
import copy
import base64
import hashlib
import json
import subprocess
import time


def run(config, auth, proposals, proof, request, start, stop, command, private_write, blob, media_path, context=False, reservation=False, custody=False, upgrade=None):
    checks = proof['checks'] = {}
    serial = 0

    def proposal(obj):
        nonlocal serial
        serial += 1
        path = proposals / ('successor-' + str(serial) + '.json')
        private_write(path, json.dumps(obj).encode())
        return path

    def commit(revision, obj, want=True, explicit=True):
        cmd = command(revision, proposal(obj)) + (['--successor-policy'] if explicit else [])
        result = subprocess.run(cmd, capture_output=True, timeout=10)
        assert (result.returncode == 0) == want, result.stderr
        return json.loads(result.stdout) if want else None

    def log_status(actor, device, room='old-secure'):
        return request(actor, '/v1/mls/rooms/' + room + '/log', headers={'X-Family-Device': device})[0]

    def wait_denial():
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            if log_status('owner', 'alice-first') == 403:
                return
            time.sleep(0.05)
        raise AssertionError('retirement did not reach live admission')

    group = 'ab' * 16
    assert request('owner', '/v1/mls/reservations', 'POST', obj={'room': 'old-secure', 'peer_actor': 'bob'})[0] == 201
    assert request('owner', '/v1/mls/rooms', 'POST', obj={'room': 'old-secure', 'group_id': group, 'device_id': 'alice-first', 'peer_device': 'bob-first'})[0] == 201
    assert log_status('owner', 'alice-first') == 200
    if context:
        for number, (who, device, kind, revision, epoch, target, data) in enumerate([
            ('family', 'bob-first', 'key_package', 0, 0, 'alice-first', b'generated public package'),
            ('owner', 'alice-first', 'welcome', 1, 0, 'bob-first', b'generated opaque welcome'),
            ('family', 'bob-first', 'ack', 2, 1, 'alice-first', b''),
        ]):
            q = dict(client_id='context-' + str(number), device_id=device, group_id=group,
                     kind=kind, expected_revision=revision, epoch=epoch, target_device=target,
                     payload=base64.b64encode(data).decode())
            assert request(who, '/v1/mls/rooms/old-secure/log', 'POST', obj=q,
                           headers={'X-Family-Device': device})[0] == 201
    legacy = (auth / 'policy-000001.json').read_bytes()
    current = copy.deepcopy(config)
    current['version'] = 2
    current['successors'] = {'administrators': [{'subject': 'family', 'actor': 'bob'}], 'intents': []}
    commit(1, current, want=False, explicit=False)
    assert commit(1, current)['revision'] == 2

    def intent(device, base, number):
        public = bytes([number + 10]) * 32
        now = int(time.time())
        return {'intent_id': 'replacement-' + str(number), 'action': 'replace', 'actor': device['actor'],
            'subject': device['subject'], 'predecessor': device['device_id'], 'predecessor_key': device['signing_key'],
            'predecessor_revision': 1, 'candidate': device['actor'] + '-candidate', 'signing_key': public.hex(),
            'fingerprint': hashlib.sha256(public).hexdigest(), 'package_sha256': hashlib.sha256(b'synthetic public package reference').hexdigest(),
            'previous_room': 'old-secure', 'previous_group': group, 'next_room': 'new-secure-' + str(number),
            'administrator': {'subject': 'family', 'actor': 'bob'}, 'acceptance': 'out-of-band-fingerprint',
            'base_revision': base, 'created_at': now - 1, 'expires_at': now + 120, 'status': 'candidate',
            'decided_at': 0, 'decision_revision': 0}

    current['successors']['intents'].append(intent(current['devices'][0], 2, 1))
    wrong = copy.deepcopy(current)
    wrong['successors']['intents'][0]['administrator'] = {'subject': 'owner', 'actor': 'alice'}
    commit(2, wrong, want=False)
    expired = copy.deepcopy(current)
    expired['successors']['intents'][0]['created_at'] -= 300
    expired['successors']['intents'][0]['expires_at'] -= 300
    commit(2, expired, want=False)
    assert commit(2, current)['revision'] == 3
    context_path = '/v1/mls/successors/replacement-1/context'
    if context:
        assert request('owner', context_path, headers={'X-Family-Device': 'alice-candidate'})[0] == 403
    assert log_status('owner', 'alice-candidate') == 403
    assert commit(2, current)['revision'] == 3  # same proposal lost-response reconciliation
    checks['explicit_mode_owner_not_device_admin_expiry_and_candidate_denial'] = True

    # Two actual CLI writers accepting the same bytes must reconcile one revision.
    current['successors']['intents'][0].update(status='accepted', decided_at=int(time.time()), decision_revision=4)
    current['devices'][0].update(status='revoked', device_revision=2)
    path = proposal(current)
    processes = [subprocess.Popen(command(3, path) + ['--successor-policy'], stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
    results = [p.communicate(timeout=10) for p in processes]
    assert all(p.returncode == 0 for p in processes), [r[1] for r in results]
    assert results[0][0] == results[1][0]
    assert len(list(auth.glob('policy-*.json'))) == 4
    assert commit(3, current) == json.loads(results[0][0])
    wait_denial()
    assert log_status('family', 'bob-first') == 403
    assert log_status('owner', 'alice-candidate') == 403
    checks['two_process_exact_acceptance_one_revision_atomic_retirement_no_candidate_admission'] = True

    def context_read():
        result = request('owner', context_path, headers={'X-Family-Device': 'alice-candidate'})
        assert result[0] == 200 and len(result[1]) < 4096
        assert request('family', context_path, headers={'X-Family-Device': 'bob-first'}) == result
        data = json.loads(result[1])
        assert data['admission'] == 'preflight-only' and data['decision_revision'] == 4
        assert data['source_group'] == group and data['candidate']['device_id'] == 'alice-candidate'
        assert data['peer']['device_id'] == 'bob-first' and data['target_room'] == 'new-secure-1'
        assert request('owner', context_path, headers={'X-Family-Device': 'alice-first'})[0] == 403
        assert request('family', context_path, headers={'X-Family-Device': 'alice-candidate'})[0] == 403
        assert request(None, context_path, headers={'X-Family-Device': 'alice-candidate'})[0] == 401
        assert request('owner', '/v1/mls/rooms', 'POST', obj=dict(room='new-secure-1', group_id='cd'*16,
            device_id='alice-candidate', peer_device='bob-first'))[0] == 403
        return result

    if context:
        observed = context_read()
        checks['signed_current_pair_context_no_old_or_candidate_delivery'] = True
    if reservation:
        from concurrent.futures import ThreadPoolExecutor
        reservation_path = '/v1/mls/successors/replacement-1/reservation'
        # The server encodes one final LF; CAS hashes only the canonical object.
        q = {'reservation_id': 'shared-synthetic-reservation',
             'context_sha256': hashlib.sha256(observed[1].removesuffix(b'\n')).hexdigest()}
        def reserve():
            return request('owner', reservation_path, 'POST', obj=q,
                           headers={'X-Family-Device': 'alice-candidate'})
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: reserve(), range(8)))
        assert sorted(x[0] for x in results) == [200]*7 + [201]
        reserved = results[0][1]
        assert all(x[1] == reserved for x in results)
        assert json.loads(reserved)['phase'] == 'reserved-inactive'
        assert request('family', reservation_path, headers={'X-Family-Device': 'bob-first'}) == (200, reserved)
        wrong = dict(q, reservation_id='conflicting-id')
        assert request('owner', reservation_path, 'POST', obj=wrong, headers={'X-Family-Device':'alice-candidate'})[0] == 409
        assert request('owner', '/v1/rooms', 'POST', obj={'id':'new-secure-1','members':['bob']})[0] == 409
        assert request('owner', context_path, headers={'X-Family-Device':'alice-candidate'})[0] == 409
        checks['concurrent_http_reservation_one_commit_exact_bytes_conflict_no_legacy_conversion'] = True

    if custody:
        upgrade()
        custody_path = '/v1/mls/successors/replacement-1/custody'
        candidate = dict(q, role='candidate', declaration_id='candidate-committed')
        peer = dict(q, role='peer', declaration_id='peer-committed')
        def declare(who, device, body):
            return request(who, custody_path, 'POST', obj=body, headers={'X-Family-Device':device})
        initial = json.loads(request('owner', custody_path, headers={'X-Family-Device':'alice-candidate'})[1])
        assert initial['revision'] == 0 and initial['declarations'] == []
        assert declare('family','bob-first',candidate)[0] == 403
        assert declare('owner','alice-candidate',peer)[0] == 403
        assert declare('owner','alice-first',candidate)[0] == 403
        assert request(None,custody_path)[0] == 401
        assert declare('owner','alice-candidate',dict(candidate,context_sha256='0'*64))[0] == 409
        # First role exact racing sends are one durable slot; discard its reply.
        with ThreadPoolExecutor(max_workers=8) as pool:
            candidate_results = list(pool.map(lambda _: declare('owner','alice-candidate',candidate), range(8)))
        assert sorted(x[0] for x in candidate_results) == [200]*7+[201]
        assert all(x[1] == candidate_results[0][1] for x in candidate_results)
        stop(); start()
        partial = declare('owner','alice-candidate',candidate)
        assert partial == (200,candidate_results[0][1])
        assert json.loads(partial[1])['revision'] == 1
        # A different process instance resumes the other independent role.
        with ThreadPoolExecutor(max_workers=8) as pool:
            peer_results = list(pool.map(lambda _: declare('family','bob-first',peer), range(8)))
        assert sorted(x[0] for x in peer_results) == [200]*7+[201]
        declared = peer_results[0][1]
        assert all(x[1] == declared for x in peer_results)
        result = json.loads(declared)
        assert result['phase'] == 'pair-declared-inactive' and result['revision'] == 2
        assert [x['role'] for x in result['declarations']] == ['candidate','peer']
        assert all(x['context_sha256'] == q['context_sha256'] and x['reservation_id'] == q['reservation_id'] for x in result['declarations'])
        assert declare('owner','alice-candidate',candidate) == (200,declared)
        assert declare('owner','alice-candidate',dict(candidate,declaration_id='changed'))[0] == 409
        assert reserve() == (200,reserved)
        checks['paired_custody_role_cas_concurrent_exact_retry_and_partial_sigkill_no_activation'] = True

    stop()  # actual owned server SIGKILL after durable acceptance/reservation
    start()
    assert log_status('owner', 'alice-first') == 403
    assert log_status('family', 'bob-first') == 403
    assert log_status('owner', 'alice-candidate') == 403
    assert request('family', media_path) == (200, blob)
    history = json.loads(request('owner', '/v1/rooms/family/messages')[1])
    assert len(history) == 1 and history[0]['client_id'] == 'retained'
    assert (auth / 'policy-000001.json').read_bytes() == legacy
    if reservation:
        assert reserve() == (200, reserved)
        assert request('family', reservation_path, headers={'X-Family-Device':'bob-first'}) == (200,reserved)
        for who, device in [('owner','alice-candidate'),('family','bob-first')]:
            assert log_status(who,device,'new-secure-1') == 403
            assert request(who, '/v1/rooms/new-secure-1/messages',headers={'X-Family-Device':device})[0] == 403
        assert request('owner', '/v1/mls/rooms', 'POST', obj=dict(room='new-secure-1', group_id='cd'*16,
            device_id='alice-candidate', peer_device='bob-first'))[0] == 403
        checks['reservation_sigkill_lost_response_retry_same_outcome_and_both_native_delivery_denied'] = True
    elif context:
        assert context_read() == observed
        assert request('owner', '/v1/rooms', 'POST', obj={'id': 'new-secure-1', 'members': ['bob']})[0] == 201
        assert request('family', context_path, headers={'X-Family-Device': 'bob-first'})[0] == 409
        checks['readonly_context_exact_restart_and_late_target_occupation_denied'] = True
    if custody:
        assert declare('owner','alice-candidate',candidate) == (200,declared)
        assert declare('family','bob-first',peer) == (200,declared)
        checks['paired_declaration_sigkill_lost_reply_exact_reconciliation_and_immutable_reservation'] = True
    checks['sigkill_restart_retains_revocation_and_old_chat_media_policy_bytes'] = True

    # Distinct real-process decisions race; only one may win the next CAS.
    current['successors']['intents'].append(intent(current['devices'][1], 4, 2))
    assert commit(4, current)['revision'] == 5
    accept, cancel = copy.deepcopy(current), copy.deepcopy(current)
    for obj, status in [(accept, 'accepted'), (cancel, 'cancelled')]:
        obj['successors']['intents'][1].update(status=status, decided_at=int(time.time()), decision_revision=6)
    accept['devices'][1].update(status='revoked', device_revision=2)
    processes = [subprocess.Popen(command(5, proposal(obj)) + ['--successor-policy'], stdout=subprocess.PIPE, stderr=subprocess.PIPE) for obj in (accept, cancel)]
    results = [p.communicate(timeout=10) for p in processes]
    assert sorted(p.returncode for p in processes) == [0, 1]
    current = accept if processes[0].returncode == 0 else cancel
    latest = json.loads((auth / 'policy-000006.json').read_text())['policy']
    assert latest == current
    commit(2, config, want=False)  # old revision and no successor mode cannot restore old state
    checks['conflicting_process_decisions_one_winner_no_old_policy_restore'] = True

    # Unsafe selected state suspends live admission; restart does not fall back.
    latest_path = auth / 'policy-000006.json'
    intact = latest_path.read_bytes()
    latest_path.chmod(0o644)
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline and request('owner')[0] != 401:
        time.sleep(0.05)
    assert request('owner')[0] == 401
    stop()
    start(False)
    assert latest_path.read_bytes() == intact
    latest_path.chmod(0o600)  # explicit fixture repair, no product auto-recovery
    start()
    assert log_status('owner', 'alice-first') == 403
    checks['unsafe_v2_policy_denied_and_retained_no_fixture_fallback'] = True

    current['people'] = []
    current['successors']['administrators'] = []
    for device in current['devices']:
        device.update(status='revoked', device_revision=2)
    assert commit(6, current)['revision'] == 7
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline and request('owner')[0] != 401:
        time.sleep(0.05)
    assert request('owner')[0] == 401 and request('family')[0] == 401
    stop()
    start()
    assert request('owner')[0] == 401 and request('family')[0] == 401
    saved = json.loads((auth / 'policy-000007.json').read_text())['policy']
    assert len(saved['successors']['intents']) == 2
    assert all(d['status'] == 'revoked' for d in saved['devices'])
    assert (auth / 'policy-000001.json').read_bytes() == legacy
    if reservation:
        assert request('owner', reservation_path, headers={'X-Family-Device':'alice-candidate'})[0] == 401
        assert request('family', reservation_path, headers={'X-Family-Device':'bob-first'})[0] == 401
        checks['reservation_denied_after_emergency_revocation_and_restart'] = True
    if custody:
        assert declare('owner','alice-candidate',candidate)[0] == 401
        assert request('family',custody_path,headers={'X-Family-Device':'bob-first'})[0] == 401
        checks['paired_custody_denies_revoked_accounts_after_restart'] = True
    checks['emergency_empty_people_and_administrators_survives_sigkill_restart'] = True
