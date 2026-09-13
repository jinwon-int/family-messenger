"""Real OpenMLS qualification, not an enrollment state machine or auth proxy."""
import hashlib
import json


def run(pages, call, receipt):
    alice, bob = pages
    receipt['scope'] = 'memory-only library carrier/removal/new-group proof; no native enrollment, approval CAS, persistence or recovery'
    serial = 0

    def init(page, actor):
        nonlocal serial
        serial += 1
        name = 'lifecycle-' + str(serial)
        page.evaluate('name => spawn(name)', name)
        key = call(page, 'init', actor, name=name)
        return {'page': page, 'actor': actor, 'name': name, 'key': key}

    def op(device, method, value=None, peer=None, reject=False):
        if peer:
            value = {'wire': value, 'peer': peer['actor'], 'key': peer['key']}
        return call(device['page'], method, value, name=device['name'], reject=reject)

    def pair():
        a, b = init(alice, 'alice'), init(bob, 'bob')
        kp = op(b, 'key_package')
        op(a, 'create')
        welcome = op(a, 'invite', kp, b)
        op(b, 'join', welcome, a)
        assert op(a, 'group') == op(b, 'group')
        return a, b

    def stop(*devices):
        for device in devices:
            device['page'].evaluate('name => stopWorker(name)', device['name'])

    # Same BasicCredential is not the same independently accepted signing key.
    old, new = init(bob, 'bob'), init(bob, 'bob')
    assert old['key'] != new['key']
    kp = op(new, 'key_package')
    verifier = init(alice, 'alice')
    assert op(verifier, 'verify', kp, new) is True
    op(verifier, 'verify', kp, old, reject=True)
    op(verifier, 'group', reject=True)
    receipt['checks']['same_actor_fresh_key_valid_package_does_not_match_old_pin'] = True
    stop(verifier)
    for field in ['actor', 'signature']:
        verifier = init(alice, 'alice')
        if field == 'actor':
            op(verifier, 'verify', kp, {**new, 'actor': 'alice'}, reject=True)
        else:
            altered = kp.copy()
            altered[-1] ^= 1
            op(verifier, 'verify', altered, new, reject=True)
        stop(verifier)
    receipt['checks']['wrong_credential_and_tampered_keypackage_denied'] = True
    stop(old, new)

    # Carry an explicitly expected public intent over an existing authenticated
    # channel. No public server-verifiable signature or durable approval claimed.
    a, b = pair()
    candidate = init(bob, 'bob')
    package = op(candidate, 'key_package')
    intent = {'v': 1, 'intent_id': 'synthetic-replace-1', 'action': 'replace',
              'actor': 'bob', 'predecessor': 'bob-first', 'candidate': 'bob-next',
              'signing_key': bytes(candidate['key']).hex(),
              'fingerprint': hashlib.sha256(bytes(candidate['key'])).hexdigest(),
              'package_sha256': hashlib.sha256(bytes(package)).hexdigest(),
              'room': 'synthetic-old-room', 'group': bytes(op(a, 'group')).hex(),
              'device_revision': 1, 'policy_revision': 7, 'status': 'candidate',
              'expires': 2000000000}
    plain = list(json.dumps(intent, separators=(',', ':')).encode())
    wire = op(b, 'encrypt', plain, a)
    assert bytes(plain) not in bytes(wire)
    assert op(a, 'decrypt_peer', wire, b) == plain
    receipt['checks']['actual_pinned_member_carries_exact_public_candidate_intent'] = True
    op(a, 'decrypt_peer', wire, b, reject=True)
    receipt['checks']['same_ciphertext_replay_denied'] = True
    stop(a, b, candidate)

    # A valid MLS sender can make false application claims. This counterexample
    # is why a bare decrypted label MUST NOT serve as enrollment authorization.
    a, b = pair()
    false_claim = list(b'{"actor":"alice","role":"owner","action":"replace"}')
    wire = op(b, 'encrypt', false_claim, a)
    assert op(a, 'decrypt_peer', wire, b) == false_claim
    receipt['checks']['valid_bob_message_can_claim_alice_owner_no_implicit_authority'] = True
    stop(a, b)

    for test in ['tamper', 'wrong_pin', 'wrong_group']:
        a, b = pair()
        wire = op(b, 'encrypt', list(b'synthetic approval carrier'), a)
        other = init(bob, 'bob')
        if test == 'tamper':
            wire[-1] ^= 1
            op(a, 'decrypt_peer', wire, b, reject=True)
        elif test == 'wrong_pin':
            op(a, 'decrypt_peer', wire, other, reject=True)
        else:
            c, d = pair()
            op(c, 'decrypt_peer', wire, d, reject=True)
            stop(c, d)
        receipt['checks']['carrier_' + test + '_denied'] = True
        stop(a, b, other)

    # Generic library Remove -> Add, with only one member left at Add. This is
    # intentionally outside native fixed-pair control and admission machinery.
    for receive_removal in [False, True]:
        a, b = pair()
        candidate = init(bob, 'bob')
        before = op(a, 'group')
        removal = op(a, 'remove')
        if receive_removal:
            op(b, 'commit', removal)
        welcome = op(a, 'invite', op(candidate, 'key_package'), candidate)
        op(candidate, 'join', welcome, a)
        assert op(candidate, 'group') == before
        payload = list(bytes(range(256)) * 4)
        wire = op(a, 'encrypt', payload, candidate)
        assert op(candidate, 'decrypt_peer', wire, a) == payload
        response = op(candidate, 'encrypt', list(b'new member'), a)
        assert op(a, 'decrypt_peer', response, candidate) == list(b'new member')
        op(b, 'raw_decrypt', wire, reject=True)
        receipt['checks']['removed_key_denied_new_epoch_' + ('processed_commit' if receive_removal else 'withheld_commit')] = True
        stop(a, b, candidate)

    a, b = pair()
    op(b, 'commit', op(a, 'remove'))
    op(b, 'encrypt', list(b'old device cannot send'), a, reject=True)
    receipt['checks']['removed_inactive_member_cannot_send'] = True
    stop(a, b)

    # Total loss means fresh keys and fresh group, not ReInit or archive restore.
    a, b = pair()
    old_group = op(a, 'group')
    old_keys = [a['key'], b['key']]
    old_wire = op(a, 'encrypt', list(b'past history'), b)
    stop(a, b)
    for page in pages:
        page.reload()  # destroys the original workers; no IDB/localStorage exists
        page.wait_for_function('window.ready === true')
        assert page.evaluate('async () => (await indexedDB.databases()).length') == 0
        assert page.evaluate('localStorage.length + sessionStorage.length') == 0
    a, b = pair()  # synthetic coordinator supplies new pins explicitly
    assert op(a, 'group') != old_group
    assert a['key'] != old_keys[0] and b['key'] != old_keys[1]
    new_wire = op(b, 'encrypt', list(b'new conversation'), a)
    assert op(a, 'decrypt_peer', new_wire, b) == list(b'new conversation')
    op(b, 'raw_decrypt', old_wire, reject=True)
    receipt['checks']['after_page_loss_fresh_group_works_but_old_ciphertext_does_not'] = True
    stop(a, b)

    a = init(alice, 'alice')
    op(a, 'key_package', [1], reject=True)
    op(a, 'init', 'alice', reject=True)
    receipt['checks']['malformed_no_payload_call_retires_without_regeneration'] = True
    stop(a)
