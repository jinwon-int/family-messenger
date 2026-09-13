# Paired inactive successor custody declarations

Signed `GET/POST /v1/mls/successors/{intent_id}/custody` adds a durable,
server-only readiness boundary to the [inactive reservation](SUCCESSOR-RESERVATION.md).
It records each participant's statement that its independently accepted local
custody is committed. It does **not** verify private storage, possession of a
signer, a human fingerprint ceremony, or an atomic lease with IndexedDB. Both
statements still leave the candidate and target inactive. Native delivery,
ordinary preparation and activePin/one-device admission remain closed.

## Stable binding, independent slots

POST accepts exactly four fields, with a 1 KiB JSON decoding cap:

```json
{"reservation_id":"shared-reservation","context_sha256":"<64 lowercase hex>","role":"candidate","declaration_id":"candidate-committed"}
```

`context_sha256` hashes the original canonical reservation **context** object,
excluding the final LF used in its HTTP encoding. This is the same hash used to
reserve the target. It binds the intent/decision/expiry, retired predecessor,
exact candidate key and package SHA, intact peer, source group and target room.
It is a consistency check, not an enrollment signature. The role must be
`candidate` or `peer`, and declaration IDs use the existing 1–64 ASCII ID grammar.
The current signed actor and `X-Family-Device` must match that exact role. A peer
cannot declare candidate custody, nor can an owner act as both participants.

Each role has one immutable empty-to-declared slot. First success is 201; an
exact retry is 200. Changed ID, reservation or context hash conflicts with 409;
there is no overwrite, delete, new-ID retry, expiration cleanup or renewal.
Different roles can race without a global expected-readiness revision: their
independent slots are serialized under authority -> Store, and the single SQL
update compares the complete prior declaration bytes. An aborted or failed CAS
returns no successful receipt. Restart uses the retained exact request.

GET and POST return `version:1`, `reservation_id`, `context_sha256`, `revision`
(the count 0, 1 or 2), `phase`, and canonical role-sorted `declarations`. Each
entry contains `role`, `declaration_id`, `device_id`, `reservation_id` and
`context_sha256`. Phase is `custody-pending` until both entries exist, then
`pair-declared-inactive`. A retry can observe newer readiness after the other
participant declared, but its own receipt cannot change. Readiness revision is
not a policy revision, MLS epoch or authorization to send.

The existing `/reservation` response remains byte-identical, with
`phase:reserved-inactive`, after either declaration. Current candidate and peer
custody workers therefore keep their immutable descriptor and exact retry
contract. Those original workers remain unchanged. Separate paired client workers
now derive the immutable public retry ID from the exact binding authenticated by
the protected commit, then POST and reconcile current readiness. This replaces
the proposed additional persisted random ID; see [client custody](CLIENT-CUSTODY.md)
for its frozen encoding, paired browser proof, and limits.

## Fresh authorization and retained failures

Every GET, first POST and retry rechecks the current signed grant, original
subject, designated administrator, accepted unexpired intent, actual source
ready group/canonical pins/membership, retired predecessor and active exact
peer. It validates the immutable reservation and empty target sentinel too.
Expiry, revocation, changed source control or corrupt state denies even an exact
old retry and retains all data. Declarations are not enough to join a new group;
separate activation, exact Welcome/ack and actual MLS sender validation remain
necessary. No old-room permission, new device enrollment, active archive restore,
repinning or recovery of a lost sender is introduced.

The declaration row is mandatory even when empty. Readers reject missing rows,
noncanonical/unknown/duplicate fields, invalid role ordering, substituted device
or context bindings, and more than two entries. Reservation reads also validate
this row, so corruption cannot be reinterpreted as uninitialized state. Local
root/same-UID replacement of a whole valid historical database remains outside
this synthetic boundary; there is no external rollback witness.

## Private additive storage and verification

Schema 6 adds `mls_successor_custody`: one row per immutable reservation, at most
16 rows and two entries/1 KiB per row. Migration from schema 5 creates a private
`v5-before-successor-custody-*.sqlite` snapshot and initializes empty declaration
rows for existing reservations inside the additive transaction. New reservations
insert the empty custody row in their allocation transaction. No existing room,
message, media, provider, outbox, cursor, policy or reservation bytes are rewritten.
Earlier schema snapshot paths, owner/0700/0600/single-link/no-symlink/flock/fsync,
unknown-file and orphan-journal retention rules remain. Old binaries refuse
schema 6; restore tests use a separate copy of the matching old snapshot only.

No browser assets, private custody code, runtime dependencies or cryptographic
libraries change. Public signed fixtures and opaque server payloads exercise the
boundary; they do not establish a paired private-client completion claim.

```sh
python3 tests/native_policy_smoke.py --successor --successor-context \
  --successor-reservation --successor-custody \
  --binary /private/build/family-dev --policy-binary /private/build/family-policy
# Optional: --legacy-binary /private/build/schema5-family-dev
```

Tests cover both role orders, exact/conflicting races, source preservation,
unchanged reservation bytes, denied old/target delivery, malformed and corrupt
state, revocation/expiry, failed SQL commit, partial and complete declaration
SIGKILL/restart, lost-response reconciliation and old schema snapshot/isolated
restore. All services remain loopback signed `--synthetic-only`. No human-use,
actual CF gate, candidate activation or Yukson deployment is claimed by this unit.
