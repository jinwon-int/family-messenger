# Durable synthetic trusted clients

This joins the staged provider/outbox from PR28 with the signed native directory
and independent first-device pins from PR29. It is an isolated runnable
**synthetic client-state adapter**. The native server authenticates directory
reads; the test coordinator still relays the small MLS exchange. Native ordered
control/ciphertext delivery and production human enrollment are not implemented.
Generated private keys and cached local plaintext remain unencrypted in private
disposable browser profiles. No production service, CF setting or human key changes.

## State and explicit acceptance

`trusted-state-worker.js` uses the `family-mls-trusted-synthetic-` database namespace
and, since #177 M2b-2, the shared storage v2 layout of `session-store.js` (IndexedDB
version 2: one authenticated `meta` record + one record per Session store entry; see
PERSISTENCE.md). Older (version-1) experiment databases are retained and denied, not
opened, rewritten or migrated. A new database atomically creates a known initialization
marker. Initialization first requires a successful signed room-directory read;
only an actor with no registered device can generate initial keys from that marker.
An existing registration plus missing local keys is denied, not silently replaced.
An unexpected/missing record, old/unknown schema or corrupt state is retained and
rejected. Database/profile eviction is not a recovery ceremony.

The durable state contains actor, fixed room, accepted public pins (an authenticated
`meta` field) or an explicit unconfirmed state, group ID, the Session store entries,
revision, exact operation ledger with acknowledged-id tombstones, receive cursor and
epoch. Initialization releases only the public key
and public status after commit. No group operation is available while unconfirmed.
The caller must explicitly supply independently accepted own/peer pins; directory
results never become pins automatically. Pin acceptance checks the generated own
key and native directory and commits with the full state in one transaction.
Repeating identical acceptance is idempotent; changed pins are rejected. This is
still a synthetic ceremony fixture, not a human verification UI.

All local fields, including pins and room/group identity, are bound by HMAC-SHA256
under the record key (`src/record.rs`): per-entry tags, and a `meta` tag over the
entry count, sorted (key, tag) set digest, ledger and pins. Without the record key
nothing can be modified undetected; the smoke also shows that an attacker *with* the
key who rewrites the pins is still denied by the live directory check. The record key
is derived from the device's custody capsule, unlocked with the `init` passphrase
(#177 M2b-3a, see PERSISTENCE.md); a registered device never gets a new capsule. This is not key
transparency, and whole-database rollback still requires an external
witness/reconciliation policy before human use.

Operations run on a resident `Session` through `apply_trusted`: before and after
each operation the group must hold exactly our leaf and, where present, the pinned
peer (exactly the pair for encrypt/decrypt), and invite/join accept only the pinned
credential and signing key. A rejection is rolled back inside the session; the
worker still retires itself on any failure, as before.

## Admission, staging and retry

The shared `trust-directory.js` validates signed native responses with the expected
actor and exact room, bounded body/time, no redirects, and explicit `cache:no-store`.
The explicit fetch cache policy also avoids observed browser request coalescing:
a held directory request otherwise caused another tab to wait until that response
was released. An actual two-tab held-response proof now permits the other tab to
complete an operation while the first waits.

Every initialization, status, pin and crypto command fetches admission **outside**
IndexedDB. It then starts a strict-durability read/write transaction, reads the
complete latest record under that transaction, and compares its current pins with
the obtained directory before any output release. Network waiting holds no IDB
transaction. A second tab that has already committed the same operation ID wins;
the delayed tab sees that latest ledger and returns identical cached bytes without
another encryption. No cached plaintext/ciphertext result bypasses admission.

Fresh native directory observation is not an atomic future delivery lease. Server
revocation between the directory reply and a later operation/delivery, or a hostile
server withholding/replaying a valid directory, remains a transport acceptance
problem. Native control/epoch CAS must close the relevant delivery race. This unit
does not claim that a client can infer an unseen revocation or revoke past plaintext.

The new public-library wrapper loads a fresh complete provider for every candidate.
It checks own and peer credentials/signing keys in existing groups; trusted invite
and join use PR29's validated KeyPackage and authenticated Welcome member checks.
Only key-package/create/invite/join/encrypt/decrypt are available here. Application
messages require exactly the accepted pair. Membership control/removal is left to
the upcoming ordered native control protocol; it is not accepted unchecked.
Group ID, once set by create/join, cannot change within this local record.

A local room field and MLS group ID are not yet a shared immutable server group-to-
room binding or an authenticated outer message-ID envelope. Those remain native
transport work. The adapter cannot be used to label existing plaintext rooms E2EE.

Candidate state, serialized output and receive cursor commit atomically before
release. An operation ID requires identical method/bytes/sequence on retry. A
changed request or duplicate ciphertext under a new ID is rejected. Any failed
command retires this worker and closes its DB connection; no failed candidate or
live group is reused. Explicit reopen loads the known committed state and performs
fresh admission before continuing. A malformed message follows that retirement
path too. A lost completion requires reopen/reconciliation, never re-encryption
or ratchet rollback. Unknown/corrupt records are not repaired automatically.

Limits remain one group and two accepted synthetic actors; 256 ledger operations
(`ack` prunes delivered items), 512 store entries, 64 KiB wire, 16 KiB application
plaintext and 2 MiB ledger binary, plus bounded public metadata. Pin acceptance is
one additional revision. No history restore or import/reset UI exists.

## Runnable proof

Build the pinned Rust/WASM assets as in README.md. Reuse the native signed CLIs:

```sh
timeout 120s .venv/bin/python tests/native_trusted_state_smoke.py \
  --bundle artifacts/mls-trusted-state-pkg \
  --binary artifacts/family-dev-trust-final \
  --policy-binary artifacts/family-policy-trust-final
```

Two persistent Chromium profiles use generated signed accounts behind the
loopback-only test assertion proxy. The proof checks pin abort/idempotency,
unconfirmed denial, damaged Welcome/ciphertext then original after reopen,
unchanged complete state on abort, exact retry after actual browser SIGKILL,
receiver replay-state restart, a held-network/two-tab same-ID race, no silent key
replacement, actor/room/pin mismatch, corrupted state preservation and durable
revocation blocking even cached output/reopen.

It also SIGKILLs the owned browser while a test-instrumented callback holds a
pending IDB write. The exact private profile is checked in the process command
line before termination. Full pins/crypto/ledger remain unchanged and the subsequent
same-ID retry executes once. The spin/marker exists only in test-served asset bytes,
with original and served hashes distinguished. It is not a runtime kill command
or a machine power-loss guarantee. CI uploads only proof JSON, not profiles/keys.

See `trusted-state-evidence.json` for this version's proof and resource/source
hashes. Prior receipts remain historical. No new Go/Rust external package or
messaging cryptography is introduced; existing licenses/notices still apply.
Next: native ordered room/group/control transport with ciphertext-only delivery,
then key protection/recovery, actual CF and mobile acceptance before human rollout.
