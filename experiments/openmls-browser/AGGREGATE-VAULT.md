# Aggregate custody container: multiple conversations under one sealed record

Status: **isolated runnable container qualification, the first slice of the
new device-vault namespace defined by
[IDENTITY-CONTEXT.md](IDENTITY-CONTEXT.md) and tracked as #49; the second
slice (#49, this document) binds the seal to the REAL MLS signer identity from
the same candidate.** It proves the custody container and its signer binding.
It does not fetch signed admission, does not establish peer pins and is not
replacement activation, encrypted-IDB production storage or a human profile
migration.

The complete native-state/admission continuation is documented in
[the device custody adapter](../device-keystore/AGGREGATE-VAULT.md). This earlier
container and namespace remain an isolated proof, with no migration or product
activation. The signing key is caller-supplied to this container; its fixture uses
an actual MLS key, but that does not make the container a full provider validator.

## Container contract

`experiments/device-keystore/native-aggregate-vault.js` adds a device-scoped
namespace alongside, never replacing, the single-room
`native-vault-store.js` profile:

- One IndexedDB database per device namespace
  (`family-mls-aggregate-synthetic-*`), one object store, **one state record**.
- The sealed envelope `{v,actor,vault,revision,capsule,header,cipher}` holds a
  bounded aggregate of complete conversation records: at most two records,
  65536 bytes each, canonical room-sorted order, per-record SHA-512 checksum.
- The format is deliberately disjoint from the single-room vault: a different
  capsule payload arity (6 fields), a different AAD label
  (`family-native-aggregate`, label version 2) binding database/actor/vault-id/
  **signer public key**/revision, and a decoded-envelope guard that refuses the
  single-room record shape.
- The signer public key rides in the capsule payload and the AAD, so a record
  sealed under one MLS identity never opens under another: the second slice
  seals the namespace under the real signer extracted from the qualified
  identity-context candidate and denies unlocking with a different real signer
  or a synthetic key no MLS context ever produced.
- Every write re-seals the whole aggregate with `TAG_FINAL` and commits through
  **one strict durability readwrite transaction** whose exact-bytes CAS compare
  runs inside the transaction. An unchanged candidate is an exact retry: no
  re-seal, no revision advance.
- Initialization is denied for an actor the directory already lists; a
  registered device with a missing source never initializes this namespace.
- Old single-room profiles are never opened, imported, rewritten or deleted;
  the proof asserts a foreign single-room database stays byte-identical while
  the aggregate is exercised.

Root/password/provider state stays inside the worker. The capsule reuses the
already qualified age passphrase (scrypt18) and secretstream FINAL contracts
with the explicit new format/AAD binding above; no new cipher, KDF or wrapping
construction.

## Runnable proof

```sh
node experiments/device-keystore/node_modules/esbuild/bin/esbuild \
  experiments/device-keystore/native-aggregate-vault.js --bundle --format=esm \
  --platform=browser --target=es2023 --minify \
  --outfile=experiments/device-keystore/bundle/native-aggregate-vault.js
python tests/native_aggregate_smoke.py --synthetic-only
```

The harness bundles an instrumented store (CAS hold, KDF hold, crash
boundaries), serves a disposable fixture page and drives two persistent
Chromium contexts. Twelve checks pass: envelope shape, exact retry, budget and
identifier denials without state change, registered-actor init refusal,
per-device namespace isolation, cross-tab write serialization and convergence,
strict CAS under a conflicting external writer, capsule/cipher corruption
denial, cross-database record-swap denial, **actual browser SIGKILL at the
commit boundary with no torn state**, lost-reply-after-commit exact retry
without double advance, and foreign single-room profile preservation.
`aggregate-evidence.json` records the receipt; CI runs the same harness.

The identity binding slice (`#49` second slice) runs on the identity-context
harness: the candidate signer key from the qualified two-browser proof seals a
namespace, the same identity reopens and advances it across a worker restart, a
different real signer and a signerless synthetic key are both denied at unlock
with the committed record untouched, and a synthetic-key namespace stays
isolated from the real-signer one. Five checks are recorded in the
identity-context verification receipt; CI runs the same harness with the
bundled store.

## Costs and limits

No new dependency, package, lockfile, license or Go/schema change. The store
bundle measures about 572 KB minified (age-encryption and libsodium bundled,
same libraries as the single-room vault); maximum observed worker WASM linear
memory in the probe was 4 MiB against the 128 MiB budget. Default WASM/JS
asset profiles are untouched and this worker is never embedded or delivered by
the Go server.

This container does not yet claim: MLS provider identity binding (the device
public key is caller-supplied and only bind-checked), fresh signed admission
outside IDB, independent peer pins, native transport/CAS/Welcome/ack barriers,
or capacity beyond two records. Those are the next slices of #49; replacement
candidates remain inactive under PR46 and human lifecycle, mobile, CF,
server-backup and fleet acceptance remain before any Yukson cutover.
