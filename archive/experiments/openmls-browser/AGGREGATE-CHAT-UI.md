# Protected two-conversation chat UI (synthetic only)

This isolated own UI selects `aggregate-native-worker.js` → complete
`AggregateStore`, with `prepared-fork-worker.js` for the second conversation.
It is not yet embedded, deployed, or accepted for human use. The only primary
room in this UI is `family`, and the generated actors are Alice and Bob.
Existing 9/15/21-file UI bundles, profiles and prepared outputs are unchanged.

`aggregate-chat.js` is an isolated derivative of our pinned `chat.js` at
74a675b. Keeping this entry separate avoids silently replacing previously
reviewed compiled assets. It shares the existing CSS, native worker, complete
custody driver, MLS wrapper and preparation worker. No framework, runtime
service, crypto implementation or dependency is added. A subsequent packaging
unit must inventory and pin every actual delivered byte and notice.

The concurrently merged PR54 edits the separate generic
`native-aggregate-vault.js` precursor and its Ed25519 admission format. This UI
neither imports it nor interprets its profiles, admissions or keys. Its tests
remain in the repository; PR53 evidence does not qualify PR54. There is one
selected native product path here: complete native-v4 records in AggregateStore.

## Lifecycle and public intent

A generated 32–128 character password is entered explicitly for each unlock or
one-shot preparation. The input is cleared before async work and its transient
reference is dropped after worker handoff. Immutable JS strings cannot be
forcibly erased. Passwords, roots, private providers and assertions are never
written to page storage or URLs. Only committed authorized messages leave the
worker. The existing age scrypt18 (256 MiB JS scratch) and secretstream FINAL
custody boundary is unchanged; the password is not reused across room switches.

The new database is `family-mls-device-vault-synthetic-ui-ACTOR`. Old single-room
profiles are not imported, migrated, reset or regenerated. Generation is allowed
only before enrollment, for first-room generated fixtures. Missing enrolled
state fails closed. Independently supplied fingerprints are required at initial
pinning; directory presence alone is not trust. The complete aggregate validates
both rooms, actual provider identity, pins, receipts and pending bytes on use.

A metadata-only tab draft uses `family-aggregate-ui-draft-v1:ACTOR:ROOM`, with
immutable ID/type/size/SHA256. A pending encrypted outbox survives separately in
the worker's sealed state. Lost bytes require exact reselection; accepted
self-echo alone permits clearing a message draft. No silent re-encryption occurs.

Second-room preparation requires an explicitly entered immutable `context-`
intent ID, target room and fresh password. The committed first-room group and
independently accepted pins form the rest of the public intent. Its bounded
metadata is retained under `family-aggregate-ui-intent-v1:ACTOR` and conflicts
fail closed. This tab hint is not a source of cryptographic trust. If the hint is
lost, entering the exact original intent is required; encrypted custody and
server declarations still reject conflicting retries. There is no slot reset.

The UI locks its prior worker and siblings before reserving/checking the native
protected target. The existing source creator reserves; the peer checks the
same descriptor. The one-shot worker commits complete local custody and only
then declares its own preparation. The UI distinguishes local commit, accepted
declaration, both declarations, MLS handshake/ack and final message self-echo.
An unbound secondary room checks the exact signed descriptor and both entries
before any create/bind/attach; the Go server independently enforces this barrier.
One entry leaves the context intact and the Join button available to retry.

These are authenticated declarations, not proof of a hostile client's private
storage or a distributed lease. Later revocation or server changes can freeze a
committed context. Never clear, repin or replace it to bypass that outcome.

Lock, hide, room edits, identity errors, worker failures and sibling lock events
retire handles/timers/generations, clear rendered messages and revoke Blob URLs.
Native calls remain serialized per worker, with the shared bounded device/KDF
locks and exact sealed-record CAS. Async crypto/network never runs inside IDB.
Polling backs off to 15 seconds, unlock expires after five minutes, and existing
256-operation/512-revision, 2-context, 1 MiB-provider/2 MiB-combined/4 MiB-serialized
limits remain unchanged. Files are inert authenticated downloads capped at
8 KiB; this is not photo/video playback or production capacity acceptance.

## Verification

Run the generated browser harness with `--aggregate-ui`, the optional pinned
identity-context WASM bundle, and current native development/policy binaries.
The proxy serves an exact isolated asset list and injects disposable signed
assertions. It is not a deployed CF gate. No test-forge worker or instrumented
custody driver is served for this DOM mode. The receipt records original and
served hashes. Test-page hooks may hold requests, track Blob URLs and discard
one prepare to simulate transport/caller failure; these are never product code.

The shared UI suite and aggregate-specific DOM checks cover two actual Chromium
profiles, independent pins, encrypted text/files, exact retries after SIGKILL,
protected preparation and no premature bind, room switching, immutable intent,
identity/revocation, encrypted IDB, corruption and late lock callbacks. Separate
complete-adapter tests retain private source/pending digest and old-epoch/control
coverage. A primitive or synthetic DOM success is not human recovery, mobile,
CF, server-backup, capacity or fleet acceptance. These gates precede Yukson cutover.
