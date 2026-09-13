"""Generated two-browser public-API proof. No vault, enrollment or native sends."""


def run(pages, call, receipt):
    receipt['scope'] = 'worker-local signer-only candidate; no encrypted persistence, signed admission, crash retry or replacement activation'
    serial = 0

    def init(page, actor):
        nonlocal serial
        serial += 1
        name = 'identity-' + str(serial)
        page.evaluate('name => spawn(name)', name)
        s = call(page, 'init', actor, name=name)
        return {'page': page, 'actor': actor, 'name': name, 'key': s['key']}

    def command(d, method, arg=None, reject=False):
        return call(d['page'], method, arg, name=d['name'], reject=reject)

    def status(d, context='source'):
        return command(d, 'status', context)

    def op(d, method, peer, wire=None, context='source', aad=None, reject=False):
        return command(d, 'op', {'context': context, 'method': method,
                                'wire': wire or [], 'peer': peer['actor'],
                                'key': peer['key'], 'aad': aad or []}, reject)

    def stop(*devices):
        for d in devices:
            d['page'].evaluate('name => stopWorker(name)', d['name'])

    def pair(join=True):
        a, b = init(pages[0], 'alice'), init(pages[1], 'bob')
        kp = op(b, 'key_package', a)
        op(a, 'create', b)
        if join:
            welcome = op(a, 'invite', b, kp)
            op(b, 'join', a, welcome)
        return a, b

    def intent(d, peer):
        return {'operation': 'synthetic-new-context-1', 'own': d['key'],
                'group': status(d)['group'], 'peer': peer['actor'], 'key': peer['key']}

    def fork(d, peer):
        q = intent(d, peer)
        return command(d, 'fork', q), q

    def target_pair(a, b):
        sa, sb = status(a), status(b)
        ta, qa = fork(a, b)
        tb, qb = fork(b, a)
        assert ta['key'] == a['key'] and tb['key'] == b['key']
        assert ta['entries'] == tb['entries'] == 1
        assert not ta['group'] and not tb['group'] and not ta['pending'] and not tb['pending']
        assert status(a) == sa and status(b) == sb
        kp = op(b, 'key_package', a, context='target')
        op(a, 'create', b, context='target')
        welcome = op(a, 'invite', b, kp, context='target')
        op(b, 'join', a, welcome, context='target')
        ga, gb = status(a, 'target'), status(b, 'target')
        assert ga['group'] == gb['group'] and ga['group'] != sa['group']
        assert status(a) == sa and status(b) == sb
        # Exact memory-only retry returns existing advanced target, no reset.
        assert command(a, 'fork', qa) == ga and command(b, 'fork', qb) == gb
        return qa, qb

    a, b = pair()
    target_pair(a, b)
    receipt['checks']['same_signers_only_one_storage_entry_and_fresh_group'] = True
    receipt['checks']['complete_source_bytes_unchanged_after_target_handshake_and_exact_memory_retry'] = True
    text = list('synthetic second conversation 한글'.encode())
    wire = op(a, 'encrypt', b, text, context='target')
    assert bytes(text) not in bytes(wire)
    assert op(b, 'decrypt_peer', a, wire, context='target') == text
    payload = list(bytes(range(256)) * 32)
    wire = op(b, 'encrypt', a, payload, context='target')
    assert op(a, 'decrypt_peer', b, wire, context='target') == payload
    old_wire = op(a, 'encrypt', b, text)
    assert op(b, 'decrypt_peer', a, old_wire) == text
    receipt['checks']['two_browsers_both_groups_text_and_8192_opaque_bytes'] = True
    op(a, 'decrypt_peer', b, wire, context='target', reject=True)
    command(a, 'status', 'source', reject=True)
    receipt['checks']['target_ciphertext_replay_retires_entire_worker'] = True
    stop(a, b)

    for direction in ['old-to-new', 'new-to-old']:
        a, b = pair()
        target_pair(a, b)
        source = 'source' if direction == 'old-to-new' else 'target'
        target = 'target' if source == 'source' else 'source'
        wire = op(a, 'encrypt', b, [1, 2, 3], context=source)
        op(b, 'decrypt_peer', a, wire, context=target, reject=True)
        receipt['checks']['same_signing_keys_wrong_group_denied_' + direction] = True
        stop(a, b)

    # The source retains its pending commit and can consume old-epoch traffic.
    a, b = pair()
    aad = list(b'synthetic original pending control')
    pending = op(a, 'update', b, aad=aad)
    before = status(a)
    assert before['pending'] and before['epoch'] == '1'
    target_pair(a, b)
    assert status(a) == before
    old_wire = op(b, 'encrypt', a, [8, 9])
    assert op(a, 'decrypt_peer', b, old_wire) == [8, 9]
    op(a, 'merge_update', b, aad=aad)
    op(b, 'peer_update', a, pending, aad=aad)
    assert status(a)['epoch'] == status(b)['epoch'] == '2'
    assert status(a, 'target')['epoch'] == status(b, 'target')['epoch'] == '1'
    receipt['checks']['pending_source_commit_preserved_old_epoch_receive_and_later_merge'] = True
    stop(a, b)

    for field in ['own', 'group', 'peer', 'key', 'operation']:
        a, b = pair()
        q = intent(a, b)
        if field in ['own', 'group', 'key']:
            q[field] = q[field].copy()
            q[field][0] ^= 1
        elif field == 'peer':
            q[field] = 'alice'
        else:
            q[field] = 'unrecognized-intent'
        command(a, 'fork', q, reject=True)
        command(a, 'status', 'source', reject=True)
        stop(a, b)
    receipt['checks']['independent_own_peer_group_and_intent_mismatch_denied'] = True

    a, b = pair()
    _, q = fork(a, b)
    q['key'][0] ^= 1
    command(a, 'fork', q, reject=True)
    stop(a, b)
    receipt['checks']['existing_target_conflicting_retry_denied_without_overwrite'] = True

    a, b = pair(join=False)
    command(a, 'fork', intent(a, b), reject=True)
    stop(a, b)
    a, b = pair()
    removal = op(a, 'remove', b)
    op(b, 'commit', a, removal)
    command(b, 'fork', intent(b, a), reject=True)
    stop(a, b)
    receipt['checks']['unpaired_or_removed_inactive_source_denied'] = True

    for damage in ['truncated', 'oversize', 'identity', 'key', 'missing-signer']:
        a, b = pair()
        q = intent(a, b)
        command(a, 'damage', damage)
        command(a, 'fork', q, reject=True)
        stop(a, b)
    receipt['checks']['damaged_or_mismatched_complete_provider_denied'] = True

    a, b = pair()
    q = intent(a, b)
    q['own'] = [0] * 33
    command(a, 'fork', q, reject=True)
    stop(a, b)
    receipt['checks']['bounded_candidate_arguments_and_failure_retirement'] = True

    for page in pages:
        assert page.evaluate('async () => (await indexedDB.databases()).length') == 0
        assert page.evaluate('localStorage.length + sessionStorage.length') == 0
        page.reload()
        page.wait_for_function('window.ready === true')
        page.evaluate("spawn('lost')")
        call(page, 'status', 'source', name='lost', reject=True)
        page.evaluate("stopWorker('lost')")
    receipt['checks']['no_storage_and_reload_cannot_resume_or_regenerate_missing_source'] = True
