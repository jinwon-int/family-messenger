# Synthetic two-conversation device vault

This is an isolated encrypted custody adapter for **two generated native
conversations**, not human enrollment, replacement activation, a product UI or
Yukson deployment. It joins PR47's intact-signer candidate to the existing native
transport engine and standard password/record protection. No existing profile is
imported, migrated, reset, reinterpreted or deleted. The old single-room driver,
native worker, history reader and 9/15/21-file compiled bundles stay unchanged.

## One device record, one atomic write

`AggregateStore` extends the unchanged `NativeVaultStore`. It reuses its standard
age scrypt18 capsule, libsodium secretstream FINAL, bounded KDF/operation locks,
private root handling, IDB read/strict commit, exact outer-byte comparison and
closure behavior. There is no new cipher, nonce, KDF or wrapping construction.

The separate `family-mls-device-vault-synthetic-*` database has one `device` store
and one `state` key. The outer record keeps the existing version1 field set
(`identity,room,vault,revision,capsule,header,cipher` plus `v`), with the fixed
`room` scope **`device-context-v1`**. The age payload remains
`[1,database,identity,scope,vaultID,actualPublicKey,rootKey]`; existing secretstream
AAD remains `['family-native-vault',1,database,identity,scope,vaultID,revision]`.
The new database namespace and fixed scope make this an explicit device-level
selection, not a claim that an old room-bound capsule covers another room. Old
entries reject the new namespace. Copying a valid capsule/record to another
database or actor fails binding checks; no ciphertext-clone import path exists.

Only a new unregistered generated identity can initialize a known marker. Unlock
cannot create missing state. A create attempt on complete state, an unknown store,
extra/missing key or malformed selected state is denied and retained. Registered
missing local keys never generate a replacement. The first public key is released
only after its complete encrypted initial state commits. Independently accepted
device IDs/pins are subsequently bound through the existing native pin operation;
CF admission is not an automatic device approval.

The sealed aggregate has exactly:

```text
version: 1
identity
primary_room
rooms: [complete native-v4 source, optional complete native-v4 target]
fork: null | {id, source, target, source_group, pins}
```

Each native record contains the entire provider, pins, binding, exact outbox,
receipts, committed messages, native cursor/revision/epoch and control phase.
No private provider/root/signing key reaches page code, logs, URLs or the server.
Native status returns only the selected room's authorized committed results.
Private snapshots used internally by the native engine remain inside its worker.

`aggregate-state-v4.js` reuses the frozen history parser for complete bound native
records, including accepted message/receipt linkage, and adds actual library epoch
checks in ack/ready phases. A narrow unbound-record validator allows only empty
history/outbox/cursor and the normal initial group-creation state. Every record's
actual public key must equal the capsule key, rooms/group IDs cannot duplicate,
and the target's retained intent/pins must match the original source. The initial
scope supports the **same active pair** in a second room; changed-peer or additional
device membership is not silently enabled. Full bound state is validated even for
an unselected room, but fresh delivery authorization applies to the selected room.

The aggregate allows at most two records and one immutable fork intent. The 1 MiB
provider limit remains per record; the **2 MiB binary/ledger total is shared across
both**, and the serialized aggregate is at most4MiB. Capsule/header/cipher view and
backing lengths are bounded. The 512 outer revisions and 256 storage operations per
unlocked worker remain. There is no automatic pruning, capacity expansion or third
context. These are prototype limits, not production capacity acceptance.

## Candidate creation and complete-state CAS

`aggregate-native-worker.js` supplies the new store to the unchanged
`serveNative(storage)` engine. Each worker selects one room for its lifetime.
Multiple workers/tabs for either room serialize through the same database Web Lock.
A separate one-shot `aggregate-fork-worker.js` accepts an explicit immutable context
intent, independently supplied pins and a generated password, then closes. It does
not expose a raw-provider import or change the normal registered-create denial.

Before first creation the source must be native-ready, with no retired outbox;
a pending ordinary application or staged source rekey is preserved. Both source
and target room directories must freshly authorize the exact original active pins.
There is **no revoked-peer exception**. PR46 successor candidates remain inactive.
The actual group/key/pair goes through the vetted `staged_identity_context` API.
The target starts with the same signer, independently accepted pins and empty
group/history/outbox/cursor. The complete source record stays byte-exact. This
constructs local custody, not native room readiness: normal fresh group binding,
KeyPackage, targeted Welcome and committed ack barrier still follow.

Under the per-device lock, a readonly IDB transaction obtains the committed outer
record. Unlock/decrypt, full aggregate validation, fresh bounded signed admission,
candidate operation and encryption run **outside** IDB. Admission is repeated
after external waits. A final strict readwrite transaction compares every previous
outer byte/revision and exact store key count before committing the single sealed
aggregate. Only completion permits output. This is one database transaction;
no cross-database atomicity is claimed. A bypassing writer's change is retained
and rejects the candidate without automatic conflict retry or re-encryption.

Exact context-intent replay returns the known committed target without new key,
group or ciphertext generation. A different intent, source/group/pins or target
conflicts. New native operations retain the existing exact-ID semantics, actual
MLS sender/credential/key and inner frame/AAD validation, source pending rekey's
old-epoch receive behavior, ordered control CAS and self-echo handling. Source
outbox bytes are never sent into the target conversation. An uncertain accepted
native response is reconciled from the exact retained outbox after restart.

The worker/caller must retire on all failures. Lock/closure aborts queued locks
and IDB transactions, clears reachable root buffers and denies late output. The
disposable test caller also terminates siblings through a BroadcastChannel on
explicit lock/hide/pagehide and retires on clone/boot/timeout/error. These are
cooperative same-origin controls, not defenses against malicious origin code,
extensions or a compromised OS. Already released plaintext cannot be recalled.
Whole valid encrypted rollback remains undetectable after restart without an
external witness. This is not an active-leaf history archive restore mechanism.

## Reproduce and distinguish test instrumentation

Use PR47's optional `identity-context` WASM/JS bundle, existing generated signed
server/policy binaries and the locked JS dependencies. No new installation is
required when the previous experiments' tools are present:

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --aggregate \
  --bundle artifacts/identity-context-build-smmbyhm5/candidate \
  --binary artifacts/family-dev-successor-fixed \
  --policy-binary artifacts/family-policy-successor-fixed
```

The exact-allowlist loopback proxy injects generated CF-shaped assertions and
serves experiment assets; it is not a production auth proxy or native static asset
deployment. The helper builds a separate original driver and a test-instrumented
driver without rewriting the original inputs/prepared bundles. Proof JSON records
both hashes. Test-only holds place SIGKILL at pending-IDB/CAS boundaries. Private
record inspection returns digests only. A deliberately forged **authenticated**
fixture exercises semantic/aggregate quota rejection after complete decryption;
its hook is absent from runtime source. Restoring saved generated encrypted bytes
between negative cases is test setup, never a supported human import/rollback API.

Required evidence includes native two-room text/8KiB opaque files, source pending
application/rekey preservation, actual owned-browser SIGKILL before commit and
after accepted response loss, exact retry/single self echo, same-ID races, external
CAS conflict, valid-view/oversized-backing rejection, corrupted/swapped bindings,
authenticated invalid records and combined quota, lock/late candidates, missing
registered source and both-room revocation. Browser/resource receipts and final
independent review are recorded in `aggregate-evidence.json` when qualified.

No new dependencies: existing age0.3.1/sodium0.8.4 (core1.0.22), 2 direct/8 transitive
JS runtime instances; OpenMLS 8 direct/151 transitive WASM crates and existing Go
JWT/SQLite. Existing notices/audit limitations remain. The dynamic sodium import
reuses the base driver's initialized library; it does not introduce another cipher
or lower password work. Measure combined OpenMLS+sodium WASM separately from
256MiB JS scrypt scratch and browser/JS/aggregate multi-worker memory. Keep5GiB
additional disk/128MiB per-worker WASM budgets and serialize heavy tests.

Product UI/static packaging, human device lifecycle/recovery/migration, mobile,
actual CF gate, server backup restoration, production capacities and all12 actual
fleet runtimes/owner approval-cancel-dedup-uncertain remain later acceptance gates.
Existing Yukson services/data/backups, original-node credentials and Telegram
fallback stay in place. No Matrix activation or login prerequisite is introduced.
