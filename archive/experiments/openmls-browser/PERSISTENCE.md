# Staged synthetic browser state

This extends the library experiment toward the requested messenger integration.
It is an isolated **synthetic development state adapter**, not human E2EE storage,
a deployed messenger or CF login. In the Session workers (#177 M2b-3b) device keys,
group state and the local inbox/outbox are **sealed at rest** under a key from a
synthetic passphrase capsule; the snapshot-API worker (`native-worker.js`) still stores
them unencrypted. Profiles are private and disposable. No actual
family identity, native server database or production service is used.

## Complete candidate state and atomic release

Each operation reconstructs an entirely new OpenMLS provider from a bounded,
versioned JSON snapshot of all its storage entries. `SignatureKeyPair::read` and
`MlsGroup::load` reconstruct the signer and group; an active group's own credential
and public key must match the snapshot identity. The snapshot records group ID,
actor and signer public key plus **all** provider entries, including consumed
KeyPackages and sender/receiver ratchets. Since storage v2 (below) the entries come
from this crate's own `StorageProvider` (`src/store.rs`, `Store::entries`), with
normal public load APIs, without `test-utils`, debug/draft/unchecked features,
custom messaging cryptography, or serializing the nonpublic MlsGroup layout.

## Storage v2 (#177 M2, Rust layer)

- **Store**: `src/store.rs` is `openmls_memory_storage` 0.6.0 vendored with an
  audited, listed set of changes: keys and values are **CBOR** (binary,
  self-describing — OpenMLS 0.9 does not support non-self-describing formats), and
  the map journals the pre-image of every touched key. Nothing reads another crate's
  internals (the old `provider.storage().values` access is gone).
- **Formats**: snapshots now carry `version: 2`. A `version: 1` snapshot (JSON
  values) is upgraded once at load by `src/migrate.rs`; later OpenMLS storage or
  codec changes add one arm there plus one fixture test. The v1 `EpochKeyPairs` key
  concatenates `group ‖ epoch ‖ leaf` without separators; the split is fixed by the
  group's recorded own leaf index, and rejected (not guessed) when that is missing.
- **Resident session** (`src/session.rs`, `Session`): the device stays in WASM;
  `apply` returns only the changed entries (upserts/deletes, framed), which stay in
  flight until the worker's IndexedDB transaction succeeds (`commit`) or fails
  (`abort` → pre-operation store and group). A rejected operation is rolled back the
  same way instead of retiring the device. Full serializations happen only in
  `open`/`export` and are counted. `apply` refuses (and rolls back) any state that
  `open` could not load again (512 entries / framed size), as the snapshot `save`
  did. Opening an older format is a two-phase rewrite: `export` → one transaction
  replacing every entry → `commit`; until then `apply` is refused, and `abort`
  keeps the session migrated.
- **No downgrade**: snapshots saved by this build say `version: 2`, which pre-M2
  builds reject. Rolling the facade back therefore needs a v2→v1 export first
  (not provided — synthetic profiles are disposable); rolling forward is automatic.
- **Measured** (`cargo test -- --nocapture`, CI step "Facade unit tests"; one run —
  sizes vary by a few bytes with random key material): store bytes after 10 /
  100 / 1,000 received messages 5,137 / 5,137 / 5,137 (12 entries); largest
  per-message delta 1,159 B; zero full serializations per message; the same epoch-12
  two-member state is 31,153 B as a format-1 JSON snapshot and 6,108 B as format-2
  entries. Format-1 states holding a pending commit (string-keyed JSON maps in the
  staged diff) migrate and still merge (`format1_with_pending_commit_migrates`).
- **Workers**: `web/durable-worker.js` (M2b-1) and `web/trusted-state-worker.js`
  (M2b-2, pins → `Session.apply_trusted`) run on `Session`; the storage layer below is
  the shared `web/session-store.js`. `native-worker.js` still uses the snapshot API —
  it has no CI smoke and references files that do not exist, so it is not migrated
  blind (to be removed or given a smoke first). The record key comes from the custody
  unlock (M2b-3a); every record is sealed at rest (M2b-3b).

## Storage v2 in the workers (#177 M2b-1/M2b-2, `web/session-store.js`)

- **Database version 2**, two stores: `meta` holds `custody` (the capsule, below) and
  `state` = `{version: 4, sealed}`: the meta fields (identity, room, signer public key,
  group id, store format, revision, cursor, epoch, ledger, acknowledged-id tombstones,
  entry count, set digest, tag) sealed with `custody.js` `sealRecord` (a new
  XChaCha20-Poly1305 secretstream per record, single `TAG_FINAL` chunk, additional data
  `family-mls-meta-v4/<kind>\0identity\0room`). `entries` holds one record per store
  entry: key `[room, index]` with `index = entry_index(auth key, room, entry key)` (an
  HMAC, so labels, group ids and epochs never appear in keys), value `{e, t}` where `e`
  seals `key length ‖ entry key ‖ value` (additional data: domain, room, index) and
  `t = entry_tag(auth key, room, index, e)`; loading re-derives the index from the
  decrypted key. The smoke asserts that neither database contains a message plaintext,
  a store label, an actor label or a public key (mutation-checked: disabling the seal
  fails exactly that check).
  An operation writes only the entries the session changed — an encrypt writes one
  entry (≈1.1 KB) instead of the whole snapshot — plus the `meta` record, which
  carries the ledger and is rewritten on every operation (reported as `meta_bytes`;
  bounded by the ledger cap, so acknowledge promptly). Moving ledger items into their
  own records is a possible follow-up.
- **Authentication** (`src/record.rs`, HMAC-SHA256 under a 32-byte record key derived
  from the custody capsule): every entry is tagged; `meta` carries the entry count and a set digest —
  SHA-256 over all `(key, tag)` pairs sorted by key — and `meta` itself is tagged. So
  a modified, added, removed or swapped entry, a mix of old and new validly tagged
  entries, and any modified meta/ledger field are detected at load. (An XOR of tags
  was rejected in review: it is linear, so enough old entry versions can be combined
  to match without the key.) Each operation hashes ≤512 `(key, tag)` pairs. A whole older database restored as a unit is **not**
  detected (no external witness). The record key is derived from the custody capsule (below).
- **Custody** (#177 M2b-3a, `custody/custody.js` → `<bundle>/custody.js`): `init` takes a
  passphrase, not a key. A new database gets a fresh 32-byte root key + vault id sealed
  in an age password capsule (default scrypt logN 18, never reduced), stored as
  `meta/custody` in the same transaction as the initial state (marker CAS). An existing
  database is unlocked outside any transaction (scrypt is asynchronous); only a single
  default-work scrypt recipient is admitted before the KDF. The record (HMAC) key is
  `crypto_kdf_derive_from_key(…, "fmlsvlt1", root)`; a second subkey is reserved for
  at-rest encryption (M2b-3b). Every transaction re-checks that the stored capsule is the
  one this worker unlocked. Wrong passphrase, corrupted capsule, a swapped capsule
  (another valid capsule under the same passphrase), the same payload re-sealed at a
  reduced work factor, a relabelled vault id, and a capsule replaced under a worker
  that already unlocked are all denied without mutation. Initialization costs one
  scrypt per `init` (≈3.4 s max in the smoke); `web/main.js` gives `init` a 60 s
  deadline (other calls 10 s) instead of ever lowering the KDF.
  Two tabs initializing one fresh database race on the `meta/custody` add: exactly
  one wins; the loser closes its store and forgets its key.
- **Resident session and tabs**: the worker keeps the `Session` between operations.
  Every transaction first reads `meta`; if its revision differs from the one the
  session was built from (another tab wrote, or first use) the session is rebuilt
  from all entries inside that transaction (the one full deserialization, verified
  tags + set digest). Changes are committed to the session only in `oncomplete`;
  `onabort` calls `abort()`, so memory never runs ahead of IndexedDB.
- **Ledger (outbox)**: at most 256 items; `ack({ids})` removes delivered/processed
  items (§3.5 pruning), unknown ids reject. The last 256 acknowledged ids stay as
  authenticated tombstones, so retrying an acknowledged encrypt (e.g. after a lost
  ack reply) is rejected instead of encrypting again; ids must never be reused at
  all (use random ids). A full ledger rejects new operations until acknowledged;
  exact retries of retained items remain available.
- **Smoke** (`native_mls_persistence_smoke.py`, 20 checks): the original 14 on the v2
  layout plus wrong passphrase, corrupted/swapped/weakened/relabelled custody capsule,
  capsule replaced under a live worker, legacy v1 database, stale-tab rebuild (exactly one
  rebuild after another tab wrote, none for same-tab operations) and ack/tombstones.
  Load verification is exercised by rolling one entry back after an encrypt (value
  only → entry tag; value+tag → set digest); a WebCrypto reseal is the positive
  control that makes the forged-actor case test the credential check. Mutation-
  checked: removing entry verification, the set-digest compare, the stale-tab
  rebuild, meta verification or `known` tracking each fails the smoke.
- **Meta version 3** (M2b-2): the authenticated meta encoding is labelled with the
  worker kind (`family-mls-meta-v3/durable` / `…/trusted`), so one worker's meta never
  verifies as the other's. Databases written by M2b-1 (meta version 2) are denied as
  an older format — synthetic profiles are disposable; there is no rewrite.
- **Old databases**: a version-1 (pre-M2) database is retained untouched and denied —
  synthetic profiles are disposable; the format migration itself lives in Rust.

*The rest of this page describes the snapshot-API contract that the durable worker
kept in v2 (and that the other workers still use): same operation IDs, faults, epoch
gate and fail-closed rules; storage and authentication details are as above.*

In the snapshot API, `staged_apply` mutates only
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
method, bytes and receive sequence; non-string IDs are rejected without coercion; changed content is rejected. Successful results
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
cannot infer a removal it has not received. Control-event reconciliation, an
acknowledgment/retirement UX and native room binding are not implemented here (the
durable worker's `ack` is the storage primitive for it).

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

*(Snapshot-API workers; the durable worker uses the HMAC scheme above.)* Before
releasing any cached result, the transaction verifies a SHA-256 checksum
binding the complete snapshot and ledger bytes, IDs, methods, sequences, epochs,
identity, revision and cursor. It uses a fixed-order encoding and the existing
RustCrypto provider synchronously; no awaited WebCrypto call can prematurely close
the IndexedDB transaction. Same-shape accidental corruption is retained and denied.
This checksum is not a MAC, actor authentication or protection from a writer who
can replace both contents and checksum. Pre-checksum experiment records fail closed;
there is no implicit migration or rewrite of earlier private test profiles.

This assumes cooperating same-origin code. It is not an anti-rollback witness,
secure enclave, or protection against a compromised browser/host/page replacing
an entire valid database. Restoring a valid older complete snapshot can restore old
keys; production restore must reconcile externally or rejoin as a new device before
sending. No import, recovery/reset, migration or human enrollment UI is supplied.
A browser deleting its entire profile destroys its keys; it does not justify silent
identity replacement. Atomic IndexedDB commits are tested against browser SIGKILL,
after confirmed commits and during an in-flight transaction, plus controlled
transaction aborts. This is not sudden machine power loss or every browser/OS storage durability guarantee.

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
was found to hang awaiting a response and is not used. For the in-flight crash,
the test patches only served asset bytes to signal and hold the worker callback
after `put` is issued, preventing transaction completion before SIGKILL. The
tracked worker has no spin/kill command. Evidence records both original and
instrumented asset hashes; the uninstrumented 13-group proof is also retained.
After reopening, the complete committed state is unchanged and the same-ID retry
executes once as a fresh operation, then decrypts successfully on the other client.

Assertions cover failed Welcome then valid original, altered ciphertext then
original, unchanged complete-state hash/cursor on abort, lost-response browser
crash with exact ciphertext retry, concurrent tabs, receiver crash with replay
rejection and future-message success, wrong actor, non-string ID rejection, forged snapshot identity,
local epoch change, corrupted cached input/output/state/metadata/checksum, missing/unknown state and capacity preservation. Test fault
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
