"""Identity-bound aggregate custody with signed admissions (#49 third slice).

The aggregate custody container (#49 first slice) sealed under a caller-supplied
synthetic device key; the second slice (#51) bound that seal to the REAL MLS
signer identity of the identity-context candidate (#47) through the capsule
payload and the AAD. This proof adds the ADMISSION contract: every record write
carries a fresh Ed25519-signed admission received outside IndexedDB, the
admission fixes the committed rooms and peer pins (immutable after the first
seal), and the store enforces the revision the admission grants. Still
synthetic, still no native server, peer-pin ceremony, replacement activation or
capacity measurement.
"""
import hashlib
import json
import secrets
import time


def _hex(key):
    return ''.join(f'{byte:02x}' for byte in key)


AGGREGATE_BOOT = '''async () => {
  if (window.aggregateCall) return;
  if (!window.policySigner) {
    const m = await import('/aggregate-policy-signer.js');
    window.policySigner = m.policySigner; window.policyKeypair = m.policyKeypair;
  }
  const worker = new Worker('/aggregate-vault-worker.js', {type: 'module'});
  let serial = 0;
  const pending = new Map();
  worker.addEventListener('message', ({data}) => {
    if (data.boot) return;
    const settle = pending.get(data.id);
    if (settle) { pending.delete(data.id); settle(data); }
  });
  await new Promise((resolve, reject) => {
    worker.addEventListener('message', function boot({data}) { if (data.boot) resolve(); });
    worker.addEventListener('error', () => reject(new Error('aggregate boot failure')), {once: true});
  });
  window.aggregateCall = (method, argument) => new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => { worker.terminate(); reject(new Error('aggregate worker deadline')); }, 10000);
    pending.set(id, data => { clearTimeout(timer); resolve(data); });
    worker.postMessage({id, method, argument});
  });
  window.aggregateReset = () => { worker.terminate(); delete window.aggregateCall; };
}'''

AGGREGATE_DIGEST = '''async name => {
  const d = await new Promise((resolve, reject) => { const q = indexedDB.open(name); q.onsuccess = () => resolve(q.result); q.onerror = () => reject(q.error); });
  const v = await new Promise((resolve, reject) => { const q = d.transaction('aggregate').objectStore('aggregate').get('state'); q.onsuccess = () => resolve(q.result); q.onerror = () => reject(q.error); });
  d.close();
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(v)))));
}'''


def run(pages, call, receipt):
    # Minimal identity-context helpers: one fresh same-signer candidate pair
    # supplies the REAL signer public keys the admission must bind.
    serial = 0

    def device(page, actor):
        nonlocal serial
        serial += 1
        name = 'binding-' + str(serial)
        page.evaluate('name => spawn(name)', name)
        s = call(page, 'init', actor, name=name)
        return {'page': page, 'actor': actor, 'name': name, 'key': s['key']}

    def command(d, method, arg=None, reject=False):
        return call(d['page'], method, arg, name=d['name'], reject=reject)

    def op(d, method, peer, wire=None, context='source', reject=False):
        return command(d, 'op', {'context': context, 'method': method, 'wire': wire or [],
                                 'peer': peer['actor'], 'key': peer['key'], 'aad': []}, reject)

    alice = device(pages[0], 'alice')
    bob = device(pages[1], 'bob')
    key_package = op(bob, 'key_package', alice)
    op(alice, 'create', bob)
    welcome = op(alice, 'invite', bob, key_package)
    op(bob, 'join', alice, welcome)
    qa = {'operation': 'synthetic-new-context-1', 'own': alice['key'],
          'group': command(alice, 'status', 'source')['group'], 'peer': 'bob', 'key': bob['key']}
    qb = {'operation': 'synthetic-new-context-1', 'own': bob['key'],
          'group': command(bob, 'status', 'source')['group'], 'peer': 'alice', 'key': alice['key']}
    command(alice, 'fork', qa)
    command(bob, 'fork', qb)
    assert command(alice, 'status', 'target')['key'] == alice['key']
    assert command(bob, 'status', 'target')['key'] == bob['key']
    alice_real, bob_real = _hex(alice['key']), _hex(bob['key'])
    synthetic_real = secrets.token_hex(32)
    stop = lambda *ds: [d['page'].evaluate('name => stopWorker(name)', d['name']) for d in ds]
    stop(alice, bob)

    database = 'family-mls-aggregate-synthetic-admission'
    foreign = 'family-mls-aggregate-synthetic-admission-synthetic'
    passwords = {database: secrets.token_urlsafe(32), foreign: secrets.token_urlsafe(32)}

    def boot(page):
        page.evaluate(AGGREGATE_BOOT)

    # The policy keypair stands in for the admission server. The secret lives
    # on the page only; the worker sees the public key alone. All admissions
    # are signed on page 0 (the admission server role).
    boot(pages[0])
    kp = pages[0].evaluate('() => window.policyKeypair()')
    policy_secret, policy_public = kp['secret'], kp['public']

    def rpc(page, method, argument=None, reject=False):
        value = page.evaluate('([m, a]) => window.aggregateCall(m, a)', [method, argument])
        assert isinstance(value, dict) and 'ok' in value, (method, value)
        if reject:
            assert value['ok'] is False and 'result' not in value, (method, value)
            return
        assert value['ok'] is True, (method, value)
        return value.get('result')

    def reset(page):
        page.evaluate('() => window.aggregateReset && window.aggregateReset()')
        boot(page)

    def digest(page, database_):
        return page.evaluate(AGGREGATE_DIGEST, database_)

    def args(actor, database_, pub, create=False):
        return {'actor': actor, 'database': database_, 'password': passwords[database_],
                'create': create, 'pub': pub, 'policy': policy_public}

    def admission(i, rooms, revision, peers=None, actor=None, not_after_ms=None, tamper=False,
                  signing_key=None):
        act = actor or ['alice', 'bob'][i]
        doc = {'v': 1, 'rooms': list(rooms), 'actor': act, 'device_id': act + '-device',
               'signing_key': signing_key or (alice_real if i == 0 else bob_real),
               'peers': [] if peers is None else peers, 'revision': revision,
               'not_after': not_after_ms or (int(time.time() * 1000) + 300000), 'signature': ''}
        doc['signature'] = pages[0].evaluate('([d, s]) => window.policySigner(s)(d)', [doc, policy_secret])
        if tamper:
            doc['rooms'] = ['room-alpha']
        return doc

    def put(page, i, room, payload, revision, rooms=('room-alpha', 'room-beta'),
            peers=None, reject=False, fresh_wrong=False, **kw):
        doc = admission(i, rooms, revision, peers=peers, **kw)
        argument = {'room': room, 'bytes': list(payload) if isinstance(payload, (bytes, bytearray)) else payload,
                    'admission': doc}
        if fresh_wrong:
            argument['freshAdmission'] = admission(i, tuple(list(rooms)[:1]), revision, peers=peers)
        return rpc(page, 'put-room', argument, reject=reject)

    payload_a = list(b'identity-bound aggregate alpha')

    # The namespace seals under the REAL signer key with a SIGNED admission
    # granting revision 1; the envelope exposes only sealed fields.
    boot(pages[0])
    rpc(pages[0], 'open', args('alice', database, alice_real, create=True))
    got = put(pages[0], 0, 'room-alpha', payload_a, 1)
    assert got['revision'] == 1 and got['rooms'] == ['room-alpha', 'room-beta']
    envelope = pages[0].evaluate('''async name => {
      const d = await new Promise((resolve, reject) => { const q = indexedDB.open(name); q.onsuccess = () => resolve(q.result); q.onerror = () => reject(q.error); });
      const v = await new Promise((resolve, reject) => { const q = d.transaction('aggregate').objectStore('aggregate').get('state'); q.onsuccess = () => resolve(q.result); q.onerror = () => reject(q.error); });
      d.close();
      return v && {v: v.v, actor: v.actor, vault: v.vault, revision: v.revision,
        capsule: Array.from(v.capsule ?? []), header: Array.from(v.header ?? []), cipher: Array.from(v.cipher ?? [])};
    }''', database)
    assert sorted(envelope) == ['actor', 'capsule', 'cipher', 'header', 'revision', 'v', 'vault']
    assert envelope['revision'] == 1
    assert alice_real.encode() not in json.dumps(envelope).encode()
    receipt['checks']['aggregate_sealed_under_signed_admission'] = True

    # The same identity reopens and advances the namespace across a restart,
    # with the admission granting the NEXT revision.
    sealed = digest(pages[0], database)
    reset(pages[0])
    rpc(pages[0], 'open', args('alice', database, alice_real))
    got = put(pages[0], 0, 'room-beta', b'identity-bound beta', 2)
    assert got['revision'] == 2
    assert digest(pages[0], database) != sealed
    receipt['checks']['aggregate_reopens_and_advances_under_same_signer'] = True

    # A DIFFERENT real MLS identity cannot unlock: the committed record stays
    # byte-identical, and the refusal happens even with a valid signature.
    before = digest(pages[0], database)
    reset(pages[0])
    rpc(pages[0], 'open', args('alice', database, bob_real))
    put(pages[0], 0, 'room-alpha', [1], 3, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['aggregate_refuses_other_real_signer'] = True

    # A synthetic key that no MLS context ever produced cannot unlock either.
    rpc(pages[0], 'open', args('alice', database, synthetic_real))
    put(pages[0], 0, 'room-alpha', [2], 3, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['aggregate_unlock_refuses_signerless_synthetic_key'] = True

    # A namespace initialized under a synthetic key stays isolated: it opens
    # and advances under its own key and never under the real signer. The
    # foreign namespace lives in the second context's storage.
    reset(pages[1])
    rpc(pages[1], 'open', args('bob', foreign, synthetic_real, create=True))
    assert put(pages[1], 1, 'room-synthetic', [5], 1, rooms=('room-synthetic',),
               signing_key=synthetic_real)['revision'] == 1
    reset(pages[1])
    rpc(pages[1], 'open', args('bob', foreign, alice_real))
    put(pages[1], 1, 'room-synthetic', [6], 2, reject=True)
    assert digest(pages[1], foreign) != digest(pages[0], database)
    receipt['checks']['synthetic_key_namespace_isolated_from_real_signer_namespace'] = True

    # --- Admission-contract checks (#49 third slice) ---

    # A forged signature (valid shape, wrong signing key) is refused.
    before = digest(pages[0], database)
    reset(pages[0])
    rpc(pages[0], 'open', args('alice', database, alice_real))
    forged = admission(0, ['room-alpha', 'room-beta'], 3)
    forged['signature'] = secrets.token_hex(64)
    rpc(pages[0], 'put-room', {'room': 'room-alpha', 'bytes': [3], 'admission': forged}, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['forged_admission_signature_denied'] = True

    # A tampered document (valid signature over different content) is refused.
    tampered = admission(0, ['room-alpha', 'room-beta'], 3, tamper=True)
    rpc(pages[0], 'put-room', {'room': 'room-alpha', 'bytes': [3], 'admission': tampered}, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['tampered_admission_body_denied'] = True

    # An expired admission is refused even with a valid signature.
    expired = admission(0, ['room-alpha', 'room-beta'], 3, not_after_ms=int(time.time() * 1000) - 1000)
    rpc(pages[0], 'put-room', {'room': 'room-alpha', 'bytes': [3], 'admission': expired}, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['expired_admission_denied'] = True

    # The ADMISSION GRANTS the revision: a stale one (covering the current
    # revision when a new seal is due) cannot advance the namespace.
    stale = admission(0, ['room-alpha', 'room-beta'], 2)
    rpc(pages[0], 'put-room', {'room': 'room-alpha', 'bytes': [3], 'admission': stale}, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['stale_admission_revision_denied'] = True

    # Peer pins and rooms are committed with the FIRST seal and are immutable:
    # a later admission that changes them cannot seal a record.
    peers_swapped = [{'actor': 'bob', 'signing_key': synthetic_real}]
    put(pages[0], 0, 'room-alpha', [4], 3, peers=peers_swapped, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['committed_pins_immutable_after_first_seal'] = True

    # The fresh admission re-received outside IndexedDB must match exactly: a
    # worker handed a DIFFERENT admission between staging and commit refuses.
    changed = admission(0, ['room-alpha'], 3)
    rpc(pages[0], 'put-room', {'room': 'room-alpha', 'bytes': [5], 'admission': admission(0, ['room-alpha', 'room-beta'], 3),
                               'freshAdmission': changed}, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['fresh_admission_mismatch_denied'] = True

    # Valid pin commits work: an admission that COMMITS the peer pin (alice
    # pins bob for the first time, matching the first seal's empty set? no —
    # the pins are immutable, so the honest path extends the seal's own
    # admission set only when it matches) — here the honest retry advances.
    reset(pages[0])
    rpc(pages[0], 'open', args('alice', database, alice_real))
    got = put(pages[0], 0, 'room-alpha', [7], 3)
    assert got['revision'] == 3 and got['pins'] == []
    assert got['rooms'] == ['room-alpha', 'room-beta']
    receipt['checks']['honest_admission_advances_sealed_aggregate'] = True
