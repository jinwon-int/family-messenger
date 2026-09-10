# Durable inactive successor reservation

Signed `POST /v1/mls/successors/{intent_id}/reservation` reserves the accepted
intent's new room without activating its candidate. `GET` on the same path reads
that committed reservation. This is the next server boundary after
[SUCCESSOR-CONTEXT.md](SUCCESSOR-CONTEXT.md); it does not yet implement client
custody, an enrolled replacement, Welcome/ack or recovered live conversation.

Both the currently enrolled candidate actor naming its exact candidate ID and
the intact source peer naming its active ID can request the same reservation.
Neither may choose a different target, peer, key or administrator. Every read,
first write and retry rechecks the current signed grant, original enrolled subject
and designated administrator, accepted unexpired intent, retired predecessor,
active exact peer, actual source membership/pins/group and ready control state.
The authority -> Store lock order is unchanged. Slow HTTP bodies are consumed
outside authority; reservation JSON is capped at 1 KiB before decoding. There
are no network or cryptographic operations inside the SQLite transaction.

## Explicit immutable request and retry

The two exact JSON fields are `reservation_id` (a shared immutable client-chosen
ID) and `context_sha256`. The latter is lowercase SHA-256 of the **exact canonical
JSON object bytes** returned by signed context preflight, excluding its one final
LF. Do not parse/re-serialize the object with another field order. This hash is a
compare-and-swap consistency check, not a signature, independent fingerprint
acceptance or proof of private-key custody. Clients must independently validate
and accept the complete public bindings before using it.

The server derives the complete current descriptor under the same Store lock
that guards competing native and legacy room allocation, and compares its hash.
A transaction inserts the room, both actor memberships, an empty MLS reservation
with `custody_required=1`, and the immutable successor reservation record. One
intent, target and reservation ID are each unique. The owner field is the
candidate actor even if the peer performs the allocation. First success is 201;
exact retry by either authorized participant is 200 with identical JSON. A
changed ID/hash or already occupied target conflicts. No fresh ID, overwritten
record, automatic retry with changed bindings, deletion or expiration cleanup is
implemented. A lost response or process restart is reconciled by the same POST or
GET, subject to fresh admission, without another allocation.

Output has `version: 1`, `reservation_id`, the original public `context`, and
`phase: reserved-inactive`. Its nested `admission: preflight-only` describes the
public context; only the enclosing response attests to a committed reservation.
An existing row must exactly match that context and the untouched empty target:
canonical bytes, owner, membership, NULL group, counters, required-custody marker,
no events/messages/media or ordinary preparation. Corrupt or partial state is
retained and denied. Different valid old database copies are not detected by an
external rollback witness. This local transaction is not an atomic lease with
browser IndexedDB or the separately reloaded policy store.

## Admission stays closed

All ordinary MLS room reads and bind routes explicitly reject successor reservations, including a peer
trying to reuse ordinary context preparation. Only the separately authorized reservation reader may inspect its empty target. A corrupt ready-phase or active-pin declaration cannot open the ordinary log/status/context routes. Candidate keys remain outside
DeviceBindings/activePin; old-room delivery still denies because its predecessor
is retired. Legacy text/media/member mutation cannot convert this new MLS room.
The old source provider, pending client frames, outbox, cursor and all server
history are unchanged. No public declaration of private storage is accepted by
this unit. A returned descriptor is not permission to commit a new client slot:
the separately qualified custody/activation protocol must still enforce that
boundary. The separate [intact-peer custody experiment](../experiments/device-keystore/SUCCESSOR-PEER-CUSTODY.md)
now reads this route solely to preserve an existing peer signer in an inactive
encrypted target context. Candidate custody and delivery are still unavailable.

Expiry/revocation also denies reads and exact retries of a previously committed
reservation, while retaining it. Neither reloading nor restart renews the original
at-most-900-second intent. A server-accepted source update awaiting ack remains
ineligible. Expired-intent renewal and unacked-control recovery are explicit
remaining blockers; no apparent success is manufactured by resetting the old
room, re-pinning, restoring an archive's active sender, or silently re-encrypting.

## Schema preservation and bounds

Schema 5 adds only `mls_successor_reservations`; existing room, event, message,
attachment and preparation data remain. Opening a v4 database takes a private
`v4-before-successor-reservation-*.sqlite` snapshot before the atomic additive
migration. Earlier versions keep their original pre-migration snapshot path.
The existing owner/0700/0600/single-link/no-symlink/flock/fsync and unknown-file or
orphan-journal retention checks still apply. Existing snapshot attempt/total caps
are unchanged. Older binaries refuse the new schema before SQLite recovery;
inspect an isolated original snapshot with its matching binary, never roll the
live database back after writes. No automatic pruning or schema downgrade exists.

At most 16 reservations and the existing 32 rooms are permitted; canonical public
context is at most 4 KiB. No new dependencies, crypto, UI assets, private key
handling, auth fallback, CORS or production services are introduced. Server-boundary tests use
generated signed loopback data and opaque payload fixtures; the separate browser
custody proof is linked above and is not human recovery evidence.

```sh
python3 tests/native_policy_smoke.py --successor --successor-context \
  --successor-reservation --binary /private/build/family-dev \
  --policy-binary /private/build/family-policy
```

The isolated intact-peer worker qualifies signer-only storage with independent
pins/intent and commit-before-output; its new inner format is not yet a product
client or history-reader migration. Next: qualify the candidate's own protected
private key and context against this reservation, then
explicit durable declarations and separately reviewed activation/Welcome/ack.
Human ceremony, lifecycle renewal, mobile, actual CF, isolated backups, capacity
and fleet acceptance remain before Yukson cutover.
