# Staged synthetic browser state

This extends the library experiment toward the requested messenger integration.
It is an isolated **synthetic development state adapter**, not human E2EE storage,
a deployed messenger or CF login. Device keys and local inbox/outbox are stored
**unencrypted in private disposable browser profiles** for this test. No actual
family identity, native server database or production service is used.

## Complete candidate state and atomic release

Each operation reconstructs an entirely new OpenMLS provider from a bounded,
versioned JSON snapshot of all its storage values. `SignatureKeyPair::read` and
`MlsGroup::load` reconstruct the signer and group; an active group's own credential
and public key must match the snapshot identity. The snapshot records group ID,
actor and signer public key plus **all** provider entries, including consumed
KeyPackages and sender/receiver ratchets. This uses the public storage map and
normal public load APIs, without `test-utils`, debug/draft/unchecked features,
custom messaging cryptography, or serializing the nonpublic MlsGroup layout.

There is no live crypto object shared between requests. `staged_apply` mutates only
that candidate, checks the output snapshot can load, and returns candidate bytes
and output to the dedicated worker. The worker stores candidate state and immutable
operation ID/input/output in **one IndexedDB read/write transaction** with strict
durability requested. Only the transaction's completion event releases the output
to the page/test coordinator. Thus ciphertext is not sent and decrypted plaintext
is not acknowledged before the transaction commits. Rejection or transaction abort
discards the entire candidate and leaves the committed provider unchanged.

For application receive operations, a synthetic receive sequence is committed
with crypto state and the cached plaintext result. It must advance the cursor by
one; a duplicate operation returns its previous result without advancing it.
This sequence is a test inbox cursor, **not yet the native SSE/control-event
cursor**. Welcome/Commit ordering and native delivery CAS are later integration.

The previous memory-only `Device` remains conservative: any failed operation
permanently retires it. The new worker has no persistent in-memory group to retire;
a timed-out or unacknowledged operation requires worker/browser restart and
reconciliation against durable state. It does not reconstruct a snapshot from
partial state or keep using a failed candidate. In particular, a damaged Welcome
or application ciphertext no longer consumes **committed** KeyPackage/ratchet
material. The original unchanged input can subsequently succeed once; duplicate
ciphertext under a new ID is still rejected by OpenMLS after a committed receive.

## Retry, concurrency and limits

An immutable ID is scoped to one synthetic device database. Reuse requires exact
method, bytes and receive sequence; changed content is rejected. Successful results
are retained in a bounded ledger. A lost response followed by process restart
returns the same serialized ciphertext, not another encryption operation. All
connections/tabs use read/write transactions over the same complete object store,
so competing requests read the latest committed state; there is no read outside
the transaction followed by an unlocked write. Two tabs racing the same ID produce
one new operation and one cached result.

The ledger retains the post-operation epoch. Releasing a previous **encrypt** result
is rejected if the locally committed epoch has since changed; the record is retained,
not silently re-encrypted or deleted. This is a local stale-outbox gate. A real send
still needs current server room/device policy and epoch admission; an offline client
cannot infer a removal it has not received. Control-event reconciliation, explicit
outbox acknowledgment/retirement UX and native room binding are not implemented here.

Limits: 64 KiB incoming wire, 16 KiB application plaintext, 1 MiB encoded crypto
snapshot, 512 provider entries, 32 committed operations and 2 MiB total stored binary
state/input/output. JSON snapshot parsing retains serde's recursion bound; unknown
fields, versions, duplicate provider keys and mismatched active-group credentials
fail. JavaScript/serde/browser copies add memory beyond these binary limits. A
full ledger fails without pruning data; existing exact retries remain available
subject to the epoch gate. These are experiment limits, not family storage quotas.

The only database names accepted start `family-mls-synthetic-` with bounded suffixes.
Fresh database creation atomically writes a recognized pending-initialization marker;
only that marker permits initial key creation. An existing empty database, missing
state, unexpected record, unknown schema/version or invalid state fails without
regenerating a device or deleting records. Initial creation has no outward result
until the full initial snapshot is committed. Unknown/corrupt material is retained.
A new program version must provide an explicit reviewed migration; the adapter
never guesses that an unknown database is an empty new device.

This assumes cooperating same-origin code. It is not an anti-rollback witness,
secure enclave, or protection against a compromised browser/host/page replacing
an entire valid database. Restoring a valid older complete snapshot can restore old
keys; production restore must reconcile externally or rejoin as a new device before
sending. No import, recovery/reset, migration or human enrollment UI is supplied.
A browser deleting its entire profile destroys its keys; it does not justify silent
identity replacement. Atomic IndexedDB commits are tested against browser SIGKILL,
not sudden machine power loss or every browser/OS storage durability guarantee.

## Runnable evidence

Build with the same pinned tooling/flags as [README.md](README.md), then:

```sh
.venv/bin/python tests/native_mls_browser_smoke.py --bundle "$MLS_NEW_BUNDLE"
timeout 120s .venv/bin/python tests/native_mls_persistence_smoke.py --bundle "$MLS_NEW_BUNDLE"
```

The first preserves all nine memory-only regression groups. The second creates
private persistent Chromium profiles under its fresh artifact directory; keys
remain there and are never uploaded by CI. It injects IDB aborts after candidate
computation and after issuing the write, and an intentional lost reply after
commit. It obtains the PID of its own test browser through CDP, verifies the exact
private `--user-data-dir` in that PID's command line, then SIGKILLs **only that
browser** and opens the same profile again. The earlier CDP Browser.crash command
was found to hang awaiting a response and is not used.

Assertions cover failed Welcome then valid original, altered ciphertext then
original, unchanged complete-state hash/cursor on abort, lost-response browser
crash with exact ciphertext retry, concurrent tabs, receiver crash with replay
rejection and future-message success, wrong actor, forged snapshot identity,
local epoch change, missing/unknown state and capacity preservation. Test fault
options live only in the isolated worker and no HTTP management route is added.
They do not simulate a full node outage, human key recovery or production rollout.

See `persistence-evidence.json` for the observation and current bundle/source
hashes. `browser-evidence.json` retains the earlier PR27 observation; it is not a
hash claim for this enlarged bundle. The target graph still has 159 external
packages: **8 direct / 151 transitive** after declaring serde 1.0.229 and serde_json
1.0.151 directly; both were already in the lock. The all-target lock still has
197 external packages. Existing notices apply and no new Go package is added.
`dependencies.json` describes the current graph. Historical toolchain/source
receipts from PR27 remain evidence of that earlier version, not current source.

Next: independently qualify real device trust and native room/control transport
binding, then production key protection/recovery, CF admission and mobile acceptance
before applying this to human conversations. The operator has requested application;
this state adapter completes a prerequisite and does not claim the live messenger
has been switched to owned E2EE.
