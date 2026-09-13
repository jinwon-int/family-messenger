# Intact signer in a fresh conversation: library boundary

Status: **isolated runnable candidate, not encrypted multi-conversation custody
or replacement activation**. This resolves the library-level question left by
[DEVICE-LIFECYCLE.md](../../docs/DEVICE-LIFECYCLE.md): a healthy existing signer
can initialize a separate provider without copying the old group's ratchets.
Native vault, browser UI, signed admission, policy, room delivery and the three
compiled asset profiles are unchanged. No human keys, CF or Yukson changes.

## Public library contract

The optional Cargo feature `identity-context` exposes `staged_identity_context`.
It is absent from default builds. The caller supplies a complete private provider
snapshot, expected actor, independently accepted own/peer public keys and exact
source group ID. All private inputs/outputs must remain within a trusted worker.
This is not a page-callable enrollment or credential-import interface.

The function loads the complete source through the existing bounded staged
validator, requires an active group containing exactly the expected pair and
checks the actual own leaf/credential/signing key and group ID. A source without
a group, an unpaired group, an inactive removed member, changed public bindings,
missing signer or malformed snapshot is rejected. The original provider byte
slice is immutable. A pending own rekey may remain pending in the source.

The pinned public `SignatureKeyPair::store` writes that existing signer to a
**fresh** RustCrypto provider. `SignatureKeyPair::read` reconstructs it using the
expected public key and signature scheme. The destination has exactly one stored
entry (the signer) and no group. Saving/loading it again verifies its identity.
There is no `from_raw`, private-key getter, custom signature, key derivation,
message cipher, ratchet or copying of the old storage map into the destination.
Normal public OpenMLS KeyPackage/create/Welcome operations then produce fresh
group state. An actual two-client handshake validates signatures with the retained
public keys; checking a label or comparing two key arrays alone would not prove it.

Primary source: pinned OpenMLS commit
[`3a3e35de3feeca8f6605143c464d5452ae584d43`, basic_credential/src/lib.rs](https://github.com/openmls/openmls/blob/3a3e35de3feeca8f6605143c464d5452ae584d43/basic_credential/src/lib.rs).
The installed registry package's `.cargo_vcs_info.json` matches that commit.
Its public `store` delegates to `StorageProvider::write_signature_key_pair`;
`read` uses `signature_key_pair` with a public-key/scheme storage ID. This is a
library storage facility, **not proof of account ownership or consent**. A caller
must first authenticate the encrypted whole source and validate current device
authority. This isolated function cannot infer revocation, actor enrollment,
room permission, freshness or protection against a maliciously replaced snapshot.

## Runnable two-browser proof

Build to a new private output; do not replace existing pinned bundles:

```sh
cargo build --offline --locked --release --target wasm32-unknown-unknown \
  --features identity-context --manifest-path experiments/openmls-browser/Cargo.toml
"$MLS_WASM_BINDGEN" "$CARGO_TARGET_DIR/wasm32-unknown-unknown/release/family_mls_browser_experiment.wasm" \
  --target web --out-dir "$MLS_NEW_CONTEXT_BUNDLE"
.venv/bin/python tests/native_mls_browser_smoke.py --identity-context \
  --bundle "$MLS_NEW_CONTEXT_BUNDLE"
```

Use the existing verified Rust 1.91.1/wasm-bindgen 0.2.126, browser entropy flags
and path remaps documented in README.md and CI. The feature adds only owned
wrapper code. Default builds reproduce the existing WASM and JS byte hashes;
existing 9/15/21-file manifests and prepared outputs remain untouched. CI first
builds/tests the default bundle, then builds this feature to a separate directory.
The job budget is 20 minutes to include the additional release-link step, with
the individual probe still capped at 90 seconds.

`identity-context-worker.js` is an **experiment fixture**, not a product entry.
It keeps at most a source and a target snapshot in worker memory, supports one
explicit immutable test intent and returns only public status/ciphertext or the
synthetic application result. Exact memory-only retry returns the current target
without regenerating it; conflicting retry retires the worker. It includes an
explicit `damage` negative-test method for internally altering generated source
bytes. That fixture is never embedded or delivered by the Go server. All failure
paths retire both contexts and subsequent valid-ID calls return a denial.

The loopback exact-allowlist harness uses two disposable Chromium contexts.
Generated text and an 8 KiB opaque byte array work in the new group while the old
group remains usable. Full source-provider byte digests are identical across
candidate construction, target handshake and exact memory retry. A pending source
rekey stays at its old epoch, can consume preceding old-epoch peer traffic and
later merge normally; the target remains a separate epoch/group. Old/new group
ciphertext substitution and replay fail despite identical signing identities.
Wrong own/peer/group/intent, removed/unpaired source and malformed provider tests
deny. No source/root/private-key/provider bytes are returned to the page or receipt.

The fixture stores nothing in IDB/localStorage/sessionStorage. Reload destroys
both contexts and cannot resume them. **This is not a crash-persistence, signed
admission, encrypted-IDB, native-outbox preservation, revocation or room-ACL proof.**
The source-provider digest includes any library pending commit, but there is no
native cursor/outbox in this fixture. Exact memory retry is not durable retry.
Those distinctions are recorded in `identity-context-evidence.json`.

Independent review reproduced both default and optional builds byte-for-byte.
The 13 candidate checks plus four independent worker-boundary groups passed
(sparse arguments, duplicate initialization, malformed envelopes and queued denial
after retirement), as did the nine default and 13 prior lifecycle groups. No
findings were reproduced. The regular Python suite passed 111 tests. This review
does not extend the proof to encrypted custody or human authorization.

## Concrete custody decision and next implementation

Do not wire this candidate into the current `NativeVaultStore.tx` by simply
removing its registered-device creation denial. Its capsule binds one room and
its database has one state record. Two different IndexedDB databases cannot
participate in one atomic transaction: reading the old source and then writing
a new target does not prove they committed together. A cooperative Web Lock
alone does not close writes that bypass that lock. This is the remaining concrete
integration boundary, not a library inability to reuse the healthy signer.

The first two slices of that synthetic implementation are qualified in
[AGGREGATE-VAULT.md](AGGREGATE-VAULT.md): the custody container, and the
identity binding that seals the namespace under the real signer identity
reused from this candidate (capsule payload plus AAD label version 2). The
admission slice adds a fresh Ed25519-signed admission per write, received
outside IndexedDB, that grants the revision and commits rooms/peer pins
immutably inside the sealed aggregate. Native delivery binding and capacity
measurement remain future slices.
For the next synthetic implementation, qualify a **new device-vault namespace**
initialized with generated unregistered devices, holding a bounded aggregate of
complete conversation records under one authenticated encrypted record and one
strict IDB CAS. Preserve every old single-room profile without importing, rewriting
or deleting it. Do not initialize that new namespace for an already registered
device whose legitimate source is missing. This is a new generated-data experiment,
not a supported human profile migration or active-leaf archive restore.

Use the already qualified standard age password capsule and secretstream FINAL
contracts with explicit new format/AAD/context binding; no new cipher, KDF or
wrapping construction. Root/password/provider remain worker-only. Define and
review the device-level capsule binding rather than pretending the current
room-bound capsule covers a second room. Start with at most two conversation
records sharing the existing aggregate serialized/binary budget, then measure
capacity. A new context gets the same signer but no old group, receipts, messages,
native cursor or pending outbox. The old complete conversation remains byte-exact
inside the authenticated aggregate. Independent target peer pins and immutable
intent/room/device bindings must be committed explicitly, never derived as trust
from a directory response.

The worker must authenticate/validate every complete source record and actual
provider identity, obtain fresh signed device/room admission outside IDB, stage
the isolated candidate, seal the aggregate, then compare the exact prior sealed
bytes/revision in one strict readwrite transaction. Recheck latest authority/state
after bounded external waits. No crypto/network awaits in IDB; no output before
whole commit. Cross-tab serialization, target conflict, unchanged source including
uncertain outbox, lock/late callbacks, corruption/swapped records, actual browser
SIGKILL and lost-reply exact retry are required tests. A stale candidate retires;
no reset, automatic retry/re-encryption, repinning or ratchet rollback.

The first proof may use the same two active enrolled devices in a second room.
Replacement candidates remain inactive under PR46. When an old peer is revoked,
any restricted intact-own-device gate must be reviewed separately; do not weaken
both-pin old-room admission. New room/group binding, ordered native CAS, actual
MLS sender/inner frame/AAD checks, targeted Welcome and ack barrier remain required
before claiming native replacement delivery. Same-actor device administration
does not imply owner execution authority or automatic family-room bots.

## Costs and limits

No package/lockfile/license changes. Same 8 direct and 151 transitive external
WASM crates (197 across all targets), existing provider features and notices.
The source-only feature does not alter the external dependency graph. Browser
support remains upstream unsupported/built-only; the historical core audit does
not cover the crypto/storage providers, this wrapper or future custody integration.
No production-keystore or audited-stack claim.

Measured optional WASM: 1,452,247 bytes / 507,122 gzip; generated JS: 29,748 /
4,995 gzip. Maximum per-worker WASM linear memory in this probe was 2,424,832
bytes, excluding JS, browser and aggregate multi-worker memory. Two local build
outputs use about 2.9 MiB; existing target cache measured 456 MiB after build.
There is no KDF in this proof. Preserve the 5 GiB additional disk / 128 MiB WASM
budgets and separately account the existing 256 MiB scrypt18 scratch in the future
custody test. Human lifecycle/recovery, mobile, actual CF gate, server backup,
production capacity and all-12-node acceptance remain before Yukson cutover.
