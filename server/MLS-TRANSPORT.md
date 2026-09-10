# Isolated native MLS delivery boundary

This is a runnable **synthetic-only transport API**, not production E2EE or an
integrated encrypted browser UI. It persists opaque bytes and orders admission;
it cannot verify MLS signatures, epoch values, membership contents or possession
of a registered device's private key. A valid CF-shaped principal may only name
its own explicitly enrolled active device. Clients must still check independent
pins and validate every KeyPackage/Welcome/Commit/application with OpenMLS.
The client integration must bind the outer room, device and immutable message ID
inside authenticated MLS application data before any human use.

## Explicit room lifecycle

All routes require signed admission. Public fixture bearer mode is denied. Host,
Origin, expected actor, assertion expiry and policy generation retain AUTH.md's
bounds. Owner execution privileges are not used or granted here. These two-person
rooms do not implicitly enroll any bot or additional device.

1. `POST /v1/mls/reservations` with exact `room,peer_actor` creates an explicitly
   MLS-only empty room before device keys exist. Same reservation is idempotent.
   Its signed `/v1/rooms/{room}/devices` directory is available to PR30's client
   bootstrap; legacy text/media/membership routes are denied from creation.
2. Clients generate and independently accept first keys through the existing
   policy mechanism. The transport offers no enrollment/signature ceremony.
3. `POST /v1/mls/rooms` with `room,group_id,device_id,peer_device` binds the reservation
   once to two active public keys and one group. The creator must own the
   reservation, and its fixed pair of actors must match. A fresh room can also
   be created directly when devices already exist. Group IDs are canonical hex,
   16–128 bytes, unique across all rooms. Existing legacy rooms cannot convert,
   even when empty; existing bound groups/keys cannot reset. Exact create retry
   returns the current room status, not its earlier revision.
4. `GET /v1/mls/rooms/{room}/status` and `.../log?after=N` require a single
   `X-Family-Device`. Both fixed devices and both actors must still be active
   and authorized for the room. Revoking either device freezes both directions,
   including old-result retrieval. Removing/replacing devices or continuing as
   a one-person group requires later reviewed MLS membership control.

The existing `/v1/rooms` UI listing excludes these rooms until the encrypted client
is integrated. There are at most 32 rooms total, including reservations and legacy
rooms. Reserved rooms cannot expose transport status/log before binding.

## Ordered log contract

`POST .../log` requires `X-Family-Device` matching the exact request fields:

```json
{"client_id":"immutable-id","device_id":"alice-first","group_id":"<hex>",
 "kind":"application","expected_revision":3,"epoch":1,
 "target_device":"","payload":"<base64 opaque bytes>"}
```

All fields are required; nulls, duplicates, unknown keys and case aliases are
rejected. The 96 KiB JSON body is read with a five-second deadline **before**
acquiring identity authority. The bound device must belong to the authenticated
actor; its peer's public binding must also exactly match the stored pair.
Account/device checks hold authority → Store through each bounded write/response.
Room names such as `events` never opt into the legacy streaming authorization path.
Legacy text/history/membership/media operations recheck the room mode under their
actual Store lock, closing the race between an early route check and concurrent
reservation of a previously absent room.

`GET /v1/mls/rooms/{room}/context` is a separate **read-only custody check**.
It returns exact `version:1,room,group_id,phase,pins`, with public pins shaped as
`device_id,actor,signing_key,device_revision`. A single `X-Family-Device` must
belong to the signed actor. For an unbound reservation, both member actors must
have active enrolled devices; bound rooms retain the ordinary both-pin admission.
Legacy/missing rooms, substituted devices, inactive peers, extra query parameters
and non-GET methods deny. It neither enrolls devices nor writes/resets/reserves a
group or a log entry. The existing strict device-directory wire is unchanged.
Reserved transport status/log are still denied. This response is a current
observation under authority → Store, not a lease across future client IDB work.

There is one monotonically ordered room sequence for every log event. A separate
control revision changes only on control events. New events require exact current
control revision and epoch; applications from an old epoch cannot be appended.

| Kind | Sender → target | Required phase | Result |
|---|---|---|---|
| `key_package` | peer → creator | key-package, epoch 0 | revision 1, welcome phase |
| `welcome` | creator → peer | welcome, epoch 0 | revision 2, epoch 1, ack phase |
| `ack` | peer → creator | ack | next revision, ready phase |
| `application` | either; empty target | ready | next log sequence; unchanged control revision/epoch |
| `commit` | creator → peer | ready | next revision/epoch; ack phase |

`ack` has an empty payload. It records the authenticated client's declaration
that its durable validated state is ready; it is **not** server proof of MLS
validation. Clients must never acknowledge before their full candidate/state/cursor
commit. Every other payload is nonempty and at most 64 KiB. New application sends
are blocked until ack, including after subsequent commits. Only the creator may
order commits in this initial fixed-pair protocol; arbitrary proposals, external
joins, membership changes and simultaneous peer commits are not implemented.
The initial Welcome itself is the target's library-verifiable join artifact; this
server phase does not supply the creator's discarded initial commit bytes.

The stored canonical request, SHA-256 integrity checksum, resulting revision/epoch
and sequence commit in one SQLite transaction with FULL synchronous durability.
`201` means a new stored event; exact same room/device/client-ID/request yields
`200` with the original event. Any changed request conflicts. An accepted old-epoch
request can still be reconciled by exact ID after epoch advancement; that never
appends it again. A never-accepted stale outbox item gets `409` and must be retained
and retired by the client, without ratchet rollback or silent re-encryption.

History returns up to eight ordered records after the cursor (zero for initial).
Future cursors are denied. Targeted control bytes are returned only to their sender
or target. The pair is fixed in this phase. HTTP pull/reconnect is implemented;
SSE/notifications and actual browser outbox/self-echo/control-cursor integration
remain next. The client must tolerate its own accepted echoes without trying to
consume its own ratchet ciphertext as a new peer message.

Limits: 256 events per room, 1,024 total, 32 MiB of canonical stored request bytes,
96 KiB per request and 64 KiB decoded opaque payload. No pruning or reset endpoint.
Exact accepted retry remains possible at capacity. Request hashes detect stored
request-byte corruption; they are not authentication against a malicious server
or whole-database rollback. The server's framing is not a new crypto protocol.

## Private additive schema and evidence

Schema 3 adds `mls_rooms` and `mls_events`; existing messages/media are unchanged.
A version-2 database first gets a fresh private `v2-before-mls-*.sqlite` snapshot.
A version-1 upgrade keeps its pre-media version-1 snapshot before the two additive
migrations, without a redundant intermediate snapshot. Fresh empty databases
need no recovery copy. File owner/mode/symlink/hardlink checks, process lock,
exclusive snapshot creation and file/directory fsync are unchanged. Four attempts
per migration prefix/eight total bound retained snapshots. Unknown names or unsafe files are retained and denied. Recognized snapshot
attempt files, including partial copies, remain retained and count toward the
limit; they are never automatically selected for recovery. Old binaries reject schema 3; restore the original snapshot
into an isolated private directory for recovery, never run an old binary on the new
live database. No automatic rollback, deletion or production migration occurred.

Run Go tests/race/vet, then:

```sh
go -C server build -trimpath -o ../artifacts/family-dev-mls-transport ./cmd/family-dev
go -C server build -trimpath -o ../artifacts/family-policy-mls-transport ./cmd/family-policy
python tests/native_mls_transport_smoke.py --binary artifacts/family-dev-mls-transport \
  --policy-binary artifacts/family-policy-mls-transport
```

Optional `--legacy-binary` runs the actual prior schema-2 binary first, creates a
synthetic message, then verifies the new binary's snapshot and preservation. The
process proof uses generated signed principals and generated opaque byte arrays;
**these arrays are not claimed to be encrypted messages**. It checks SIGKILL/restart,
large targeted Welcome retry/history, 48 KiB application bytes, incomplete-body
crash, old-epoch denial, exact prior reconciliation and durable policy revocation.
New Go tests cover concurrent control CAS, capacity, corrupt request retention,
reservation/legacy boundaries, exact JSON and revocation during body reads.

Next: integrate PR30's actual browser/library with this delivery boundary, expand
membership controls through vetted APIs and test authenticated outer framing and
atomic outbox/cursor. Human protected keys/recovery, actual CF and mobile acceptance
remain prerequisites for an isolated Yukson candidate and production cutover.
