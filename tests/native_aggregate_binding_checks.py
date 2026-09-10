"""Identity-bound aggregate custody (#49 second slice).

The aggregate custody container (#49 first slice) sealed under a caller-supplied
synthetic device key. This proof binds that seal to the REAL MLS signer of the
identity-context candidate (#47): the signer public key is extracted from the
qualified candidate, committed as the namespace key, and bound into the capsule
payload and the AAD (label version 2), so a record sealed under one identity
never opens under another. Still synthetic, still no signed admission, peer
pins, native server or replacement activation.
"""
import secrets


def _hex(key):
    return ''.join(f'{byte:02x}' for byte in key)


AGGREGATE_BOOT = '''async () => {
  if (window.aggregateCall) return;
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
    import hashlib
    import json

    # Minimal identity-context helpers: one fresh same-signer candidate pair
    # supplies the REAL signer public keys this proof binds into the vault.
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
    assert len({alice_real, bob_real, synthetic_real}) == 3
    stop = lambda *ds: [d['page'].evaluate('name => stopWorker(name)', d['name']) for d in ds]
    stop(alice, bob)
    database = 'family-mls-aggregate-synthetic-binding'
    foreign = 'family-mls-aggregate-synthetic-binding-synthetic'
    # One fixed password per namespace so every unlock refusal below is
    # attributable to the signer binding alone, never to a password change.
    passwords = {database: secrets.token_urlsafe(32), foreign: secrets.token_urlsafe(32)}

    def boot(page):
        page.evaluate(AGGREGATE_BOOT)

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
                'create': create, 'pub': pub}

    payload_a = list(b'identity-bound aggregate alpha')

    # The namespace seals under the REAL signer public key extracted from the
    # qualified identity-context candidate; the envelope exposes only sealed
    # fields, and the signer key never appears in plaintext anywhere.
    boot(pages[0])
    rpc(pages[0], 'open', args('alice', database, alice_real, create=True))
    got = rpc(pages[0], 'put-room', {'room': 'room-alpha', 'bytes': payload_a})
    assert got['revision'] == 1
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
    receipt['checks']['aggregate_sealed_under_real_mls_signer_identity'] = True

    # The same identity reopens and advances the namespace across a restart.
    sealed = digest(pages[0], database)
    reset(pages[0])
    rpc(pages[0], 'open', args('alice', database, alice_real))
    got = rpc(pages[0], 'put-room', {'room': 'room-beta', 'bytes': list(b'identity-bound beta')})
    assert got['revision'] == 2
    assert [x['room'] for x in got['rooms']] == ['room-alpha', 'room-beta']
    assert got['rooms'][0]['bytes'] == len(payload_a)
    assert digest(pages[0], database) != sealed
    receipt['checks']['aggregate_reopens_and_advances_under_same_signer'] = True

    # A DIFFERENT real MLS identity cannot open the namespace: the refusal
    # happens at unlock, so the committed record stays byte-identical. Both
    # signer keys run on the SAME page because the namespace storage lives
    # there — the bob key is a public value, so it travels to that worker.
    before = digest(pages[0], database)
    reset(pages[0])
    rpc(pages[0], 'open', args('alice', database, bob_real))
    rpc(pages[0], 'put-room', {'room': 'room-alpha', 'bytes': [1]}, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['aggregate_refuses_other_real_signer'] = True

    # A synthetic key that no MLS context ever produced cannot unlock it either.
    rpc(pages[0], 'open', args('alice', database, synthetic_real))
    rpc(pages[0], 'put-room', {'room': 'room-alpha', 'bytes': [2]}, reject=True)
    assert digest(pages[0], database) == before
    reset(pages[0])
    receipt['checks']['aggregate_unlock_refuses_signerless_synthetic_key'] = True

    # A namespace initialized under a synthetic key stays isolated: it opens
    # and advances under its own key and never under the real signer. The
    # foreign namespace lives in the second context's storage.
    boot(pages[1])
    rpc(pages[1], 'open', args('bob', foreign, synthetic_real, create=True))
    assert rpc(pages[1], 'put-room', {'room': 'room-synthetic', 'bytes': [5]})['revision'] == 1
    reset(pages[1])
    rpc(pages[1], 'open', args('bob', foreign, alice_real))
    rpc(pages[1], 'put-room', {'room': 'room-synthetic', 'bytes': [6]}, reject=True)
    assert digest(pages[1], foreign) != digest(pages[0], database)
    receipt['checks']['synthetic_key_namespace_isolated_from_real_signer_namespace'] = True
