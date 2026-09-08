# Synthetic encrypted native delivery

`native-worker.js` joins the independently pinned staged OpenMLS client to the
signed native server's real reservation/group/log APIs. Two private Chromium
profiles now exchange actual MLS-encrypted text and a small byte-file through
SQLite-backed native HTTP delivery. The test coordinator supplies generated
principals and accepted public pins; it does not relay crypto payloads between
clients. This is an isolated runnable worker/harness, **not the product chat UI,
production CF login or human-safe key storage**. Prior workers/profiles remain
unchanged. All native processes still require loopback `--synthetic-only`.

## Bootstrap and identity

The fixture reserves an explicitly MLS-only room before key generation. A new
`family-mls-native-synthetic-...` namespace contains a version-3 client record;
no old experiment database is opened or silently imported. The known initial
marker can generate keys only after signed directory admission reports no own
registered device. Missing registered keys, unknown schema, corrupt state and
actor/room mismatch fail closed and remain preserved. A separate new synthetic
identity/policy is used for each proof; no human enrollment/replacement is done.

`pin` commits independently accepted own/peer pins with the complete state. The
server directory never becomes trusted pins automatically. The initial fixed
pair uses Alice as creator and Bob as peer. Alice's `create` durably establishes a
library-generated group ID, then `bind` idempotently sends its immutable proposal
to the native room API. Bob's `attach` checks the native group's pair and public
keys against its independent pins. Repeating bind/attach cannot reset state.
A changed native binding is denied before a new crypto candidate is constructed.

Every command uses fresh bounded signed directory admission. Native requests use
same-origin cookies, expected actor and explicit own device headers, `no-store`,
no redirects and a five-second deadline. JWTs never reach JS/sessionStorage/URLs;
the loopback-only fixture injects generated assertions upstream. Native JSON bodies
are bounded to 1 MiB before parsing. Device/account/room authorization remains
separate from owner execution authority, and family rooms acquire no automatic bots.

## Durable initial control and application processing

The worker exposes init/pin/create/bind/attach, `advance`, `prepare`, `flush`,
`sync` and `status`. `advance` stages the next initial control operation: Bob's
KeyPackage, Alice's Welcome, or Bob's acknowledgement after durable validated join.
Only these initial controls are supported in this unit. Control IDs are fixed and
scoped by native room/device, and the client validates every expected sender,
target, revision, epoch and resulting native state. The native log is ordered;
control cursors are separate from cryptographic ratchet generations.

`prepare` accepts an `app-...` immutable ID, text/file kind and at most 8 KiB of
synthetic bytes. It places canonical version/room/group/message-ID/sender-actor/
sender-device/type/payload framing **inside** MLS application data. It commits the
complete staged provider and exact serialized native request together before any
network send. A pending or completed same-ID retry must match the original data;
a different operation cannot overwrite an outstanding outbox item.

`flush` sends the persisted request bytes. A successful HTTP reply only confirms
native acceptance and does not clear the outbox or display a new message. Only
`sync`'s committed exact self echo clears it. Lost replies/restarts retry the same
request; they never cause another encryption. Own echoes must exactly match the
outbox and do not enter the peer decrypt ratchet. Stored native receipts allow a
second tab's already-applied batch to reconcile without duplicate display.

For peer applications, `decrypt_peer` uses OpenMLS's authenticated processed
sender, credential and leaf signing key. The decrypted canonical inner frame must
also match the outer room/group/message ID and that independently pinned peer.
A genuine ciphertext containing a forged inner sender label is still denied;
changing a valid outer ID/group/device or replaying an earlier ciphertext cannot
turn it into a new authorized message. Welcome validates the accepted peer and
own leaf through the existing library wrapper, then compares the actual joined
group ID to the native binding.

Each candidate reconstructs the whole provider inside a strict-durability IDB
transaction. The record stores pins, group/native binding, provider, native
cursor/revision/epoch/phase, exact pending request, receipts and bounded cached
messages atomically. Network waiting is outside IDB. After network admission or
history fetch, the transaction rereads and validates the latest complete record.
No failed candidate is retained. Outputs/messages are released only after commit.

Every failure retires the worker and closes its DB connection. Reopen performs
fresh admission and loads only committed state. A later valid command to a retired
worker receives a bounded failure reply; malformed input cannot leave it usable.
Corruption checks cover the complete record with the existing synchronous provider
SHA-256. This detects accidental corruption, not hostile whole-record replacement
or valid database rollback. There is no automatic repair, repinning or ratchet reset.

## Later controls and limits

Subsequent update/membership commits are explicitly **rejected** by this client;
its provider and cursor remain unchanged, and it freezes instead of pretending to
have validated a new epoch. Full commit/rotation/removal processing is next. The
server's current support for opaque commit declarations is not client validation.

If a never-accepted pending application is rejected by native CAS after the server
advances control/epoch, the exact pending request is durably marked retired. Its
ciphertext and complete crypto snapshot remain unchanged; it cannot be sent or
silently re-encrypted. A previously accepted old request can reconcile by exact
server ID before its committed self echo. Account/device revocation blocks fresh
admission, including cached status and reopen; it cannot recall past plaintext.

Limits are 32 native receipts/messages, 8 KiB application bytes, 64 KiB wire,
1 MiB provider snapshot and 2 MiB combined binary state. This worker's retained
history cap is intentionally smaller than the server's 256-event room cap.
No pruning/reset exists. Keys and cached messages remain unencrypted at rest in
private synthetic profiles. Whole-database rollback, device loss recovery,
protected human keys, a multi-room device lifecycle, broader groups/devices,
media streaming and mobile acceptance
are not solved by this roundtrip. Actual CF deployment is unchanged.

## Reproducible proof

Build the pinned Rust/WASM wrapper and use PR31's native signed CLIs:

```sh
timeout 120s .venv/bin/python tests/native_encrypted_browser_smoke.py \
  --bundle artifacts/mls-native-pkg --binary artifacts/family-dev-mls-fixed \
  --policy-binary artifacts/family-policy-mls-fixed
```

The proof covers native KeyPackage/Welcome/ack, actual encrypted text/file, no
plaintext in native storage, self echoes, two-tab retry, real browser SIGKILL after
native acceptance with its response withheld, receiver restart, tamper/replay and
outer/inner sender mismatch, corrupt state retention, stale pending retirement,
malformed-command retirement and durable revocation. A test-served callback hold
also stops the owned browser during a pending write; full crypto/outbox remain
unchanged and the same operation can be staged once afterward.

The pending-write hold and deliberately forged inner sender exist only in served
fixture bytes; production-source and instrumented hashes are recorded separately.
The exact owned profile argument is checked before SIGKILL. Generated profiles,
private keys and policy state are never uploaded by CI; only verification JSON is.
The normal native source contains no forged-sender or infinite-loop test command.
See `native-delivery-evidence.json` for source/artifact/resource hashes. No external
crate/module or runtime process was added. Next: vetted subsequent control handling
and product UI integration, then human key/recovery/CF/mobile acceptance and an
isolated Yukson candidate before production cutover.
