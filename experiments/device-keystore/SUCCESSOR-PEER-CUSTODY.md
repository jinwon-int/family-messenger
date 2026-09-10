# Restricted intact-peer successor custody

This experiment prepares **only the intact peer's signer** against a committed
[inactive successor reservation](../../server/SUCCESSOR-RESERVATION.md). It does
not initialize the candidate's private device, declare either party ready, create
a new MLS group, send a Welcome, activate the candidate, or permit messages. The
candidate public key in the fixture is a generated declaration; this proof does
not establish possession of its private key. There is no product UI or native
asset activation for this worker yet.

## Explicit preserving transition

`successor-peer-worker.js` accepts one `successor` request, with generated
`identity`, existing `database`, disposable 32–128-character `password`, and
`intent: {accepted: true, reservation: <independently expected full descriptor>}`.
Acceptance must be supplied independently; neither a directory response, CF
login, archive password nor the boolean alone proves a human ceremony. The
worker accepts only the descriptor's intact peer, never its candidate actor.

The future UI caller must bound and own public arguments before structured
clone, clear its transient password input, and immediately retire the worker on
clone/boot/timeout errors. This unit uses the existing disposable fixture caller;
it does not qualify a new product caller. The worker validates individual bounded
fields before serializing metadata and exposes no general native commands.

The caller explicitly selects this experimental entry for an existing **single
context**, encrypted AggregateStore database. Opening it never creates a root,
signer or missing record. The one atomic write changes the authenticated inner
aggregate from version 1 to version 2 with fields `version`, `identity`,
`primary_room`, `rooms`, `successor`. Both complete native-v4 records and the
immutable accepted reservation are sealed together in the same IndexedDB record.
The source record, including its pending local old-epoch update, receipts,
messages, provider, cursor and pins, is unchanged. A second slot already used by
an ordinary fork cannot be replaced. No source state is copied to another
database, imported from an archive, deleted, reset or automatically re-pinned.

This is an explicit experimental format transition, not an automatic product
migration. Older aggregate-v1 drivers/readers reject version 2 and cannot resume
it. Existing profiles not explicitly selected, old bundles/manifests and prepared
asset outputs remain unchanged. Before human use, a separately reviewed client
and history reader must support this format. Whole valid database rollback still
requires an external witness; authenticated ciphertext alone cannot detect it.

## Custody and admission

The existing age scrypt18 capsule/root and libsodium secretstream FINAL APIs are
reused without new ciphers, nonces, KDFs or wrapping. The existing device scope,
database/identity/vault/revision AAD and capsule are retained. Full validation
authenticates both native records, actual provider signing keys and group state,
source pins and pending state. A group marked empty alone is insufficient: the validator recomputes the exact
signer-only provider through the vetted API and compares all target bytes,
wiping the temporary result. The target has the same actual own signer and the
independently accepted **new** peer pins, but no group, active leaf, history,
outbox, cursor or messages.

The pinned optional OpenMLS public `staged_identity_context` operation validates
the source's actual **old** pair and group and copies only `SignatureKeyPair`
through its vetted store/read APIs into a fresh empty provider. It does not
generate a different enrolled key or treat new peer labels as membership proof.
The descriptor's predecessor revision is its historical room pin (1); current
retirement (tombstone 2) is separately enforced by signed server admission.

Only bounded signed GET of the exact successor reservation is used: same origin,
expected actor and intact device headers, no cache or redirect, five seconds and
4 KiB. The complete response must equal the independently expected normalized
descriptor. Checks occur before the KDF, after decrypt/validation and just before
the final local commit. No ordinary old-room or activePin authorization is
weakened. Expiry, revoked peer, changed policy, metadata, target or reservation
denies both initial preparation and retries while retaining existing bytes.

Network and asynchronous crypto are outside IDB transactions. The existing
15-second per-device and origin-wide KDF locks bound serialization; strict
readwrite CAS rechecks the sole state key and exact prior sealed bytes/revision.
Complete encryption, validation and commit precede any public success. A lost
reply retries the identical accepted descriptor and reads the same committed
outcome without another seal. Failure/lock retires the one-shot worker; no
provider, root, password or JWT is returned. Plaintext remains private to worker
memory. Same-origin malicious code, browser key exposure and immutable JS string
erasure are not solved by this experiment.

A fresh server read and local CAS are **not a distributed lease**. Authority can
change after the last read; retained custody then freezes. This worker offers no
delivery capability, rollback, renewal, slot clearing or silent re-encryption to
hide that uncertainty. Candidate custody, both durable declarations, separately
qualified activation, new-group Welcome/ack and actual sender validation remain
required before delivery. Expired intents and accepted-but-unacked old control
remain blocked by the server.

## Bounds and reproduction

Two contexts, 1 MiB per provider, 2 MiB combined binary content, 4 MiB serialized
state, 512 revisions and 256 operations retain the existing limits. Standard
scrypt18 has a separate ~256 MiB JS scratch cost. Combined worker WASM must stay
below 128 MiB. No new dependencies: existing age/sodium and optional OpenMLS
inventory/notices apply; original asset pins are not changed.

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --successor-peer \
  --bundle artifacts/identity-context-build-smmbyhm5/candidate \
  --binary artifacts/family-dev-successor-reservation-fixed \
  --policy-binary artifacts/family-policy-successor-reservation-fixed
```

The loopback fixture proxy supplies generated signed assertions and serves
experimental assets. It is not a deployed CF gate. Source-digest, abort,
pending-transaction SIGKILL and lost-reply holds are separately hashed test-only
instrumentation. They are not shipped as native embedded assets. Only generated
pair state, passwords, bytes and public candidate declarations are used.
