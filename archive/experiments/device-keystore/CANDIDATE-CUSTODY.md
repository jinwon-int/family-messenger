# Inactive candidate proposal custody

This isolated, generated-data worker prepares a replacement key **before** a
management intent fixes the candidate's public identity. It is not a sender,
enrollment endpoint, recovery import, or production UI. Existing native devices,
aggregate profiles, compiled bundles, and room authorization are unchanged.

## Explicit two-stage contract

`candidate-worker.js` accepts one operation, then closes. `proposal` takes
`{identity,database,password,create}`. The new database name begins
`family-mls-candidate-synthetic-`; actor is the signed synthetic Alice or Bob.
Passwords are generated test strings of 32–128 characters. A successful
`/v1/session` must say `signed` and match the independently expected actor;
email, owner labels, fixture bearers, and directory enrollment are not substitutes.
Creation has **no candidate ID, room, reservation, or enrollment input**. A signed
account can create an unassigned proposal, but obtains no decrypting membership.

The worker uses the existing OpenMLS public `staged_init` and `staged_apply`
KeyPackage operation. The entire returned provider and the **exact** public
KeyPackage are encrypted and committed before any public material is returned.
The package's SHA-256 is its actual wire digest. Public output contains the
signing key, package, digest, phase, and reservation ID (initially null).
No private signer/provider/root leaves the worker. The unchanged server still
treats `package_sha256` as an opaque reference; this client binds it to actual
validated package bytes, not a server proof of possession.

After a management intent is independently accepted and a reservation committed,
`bind` takes `{identity,database,password,intent:{accepted:true,reservation}}`.
It always opens existing state with `create=false`. The full reservation, actual
stored signing key and package digest must agree. The caller must independently
accept the candidate, old group, target room, intact peer, and intent pins. The
server directory, CF login, and archive/password possession alone do not satisfy
this acceptance. The OOB policy marker remains a management declaration, not
proof that a human ceremony occurred.

Restricted signed reservation reads use the candidate's exact device ID, never
ordinary `activePin`. Both the immutable expected descriptor and current server
authorization/expiry must agree before opening, before KDF, and before commit.
Only `GET` requests are issued. Binding adds the immutable descriptor to the
same sealed record; it does not declare custody, activate a device, bind a room,
send a KeyPackage/Welcome, or remove the native successor delivery prohibition.

## Persistence and failure behavior

The inner v1 record has identity, full provider, exact hex KeyPackage/digest,
nullable binding, and an accidental-corruption checksum. The existing age
password capsule (default scrypt18) protects the generated session root; existing
libsodium secretstream FINAL protects the entire record. AAD includes the new
database, actor, scope `candidate-proposal-v1`, vault ID, and revision. There is
no new cipher, KDF, nonce protocol, password reduction, or plaintext fallback.

The unchanged `NativeVaultStore` provides private worker root custody, shared
origin KDF lock, bounded per-database lock, strict exact-outer-byte/revision CAS,
sole-key checks, and commit-before-output. Crypto and network work remain outside
IDB transactions. Original profiles are neither imported nor reinterpreted.
The limits remain 1 MiB provider, 64 KiB package, 4 MiB serialized state, 512
revisions, 256 operations, 15-second locks, 5-second/4 KiB admission responses,
and 128 MiB combined worker WASM. Scrypt's 256 MiB JS scratch is separate.

`create=true` rejects an already committed record. `create=false` reconciles the
same unassigned proposal without generating or resealing another package. Once
bound, only an exact `bind` retry with fresh authorization succeeds; the generic
proposal read is denied. Interrupted creation may leave an uncommitted v0
placeholder; no public package was released. A bind cannot initialize it. Missing,
unknown, corrupt, locked, conflicting, or mismatched state is retained and denied.
Failures retire the one-shot worker; callers must terminate it on timeout, clone
failure, lock/hide, or lost boot. This unit does not provide a product caller/UI.

The library validates the actual package signature/credential, retained provider
identity, and absence of an active group. Generated browser fixtures additionally
consume the saved package's Welcome using the retained private provider, without
persisting the test group or returning private bytes. This does not establish a
server proof of possession or qualify hostile replacement of an entire valid
encrypted database. Same-origin compromise and whole-valid rollback remain
outside this protection; no external rollback witness exists.

An accepted intent's expiry, peer revocation, or late reservation change may
freeze retained custody. A reservation is not a distributed client lease. There
is no automatic renewal, reset, repinning, package regeneration, or re-encryption
of uncertain state. The intact peer's old provider, pending control, outbox,
cursor, and history are not copied to the candidate.

## Verification and remaining integration

Run the generated native-browser fixture with the existing optional PR47 WASM:

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --candidate \
  --bundle artifacts/identity-context-build-smmbyhm5/candidate \
  --binary artifacts/family-dev-successor-reservation-fixed \
  --policy-binary artifacts/family-policy-successor-reservation-fixed
```

Add `--candidate-original` to exercise uninstrumented original worker/store
bytes. The full fixture records separate original and test-served hashes; only
the latter has private continuity, commit hold, transaction abort, and browser
SIGKILL hooks. Neither is a compiled product asset. The proxy injects generated
assertions on loopback only. No human account/password, actual CF setting, or
production service changes are involved.

Both custody completions, declarations/activation, ordered native Welcome/ack,
and exact package continuity into the new conversation still need a separately
reviewed integration. In particular, current native handshake code must not
generate a fresh package in place of the accepted candidate package. Device
lifecycle, UI/history format support, mobile/KDF limits, backups, CF acceptance,
capacity and fleet operation remain deployment gates.
