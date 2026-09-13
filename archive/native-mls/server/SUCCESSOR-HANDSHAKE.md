# Restricted successor handshake relay (synthetic only)

`GET/POST /v1/mls/successors/{intent}/handshake` relays an ordered, immutable
three-slot transcript after both public custody declarations exist. This is an
opaque server transport; it does not parse MLS, prove possession, enroll a
candidate, or activate the target. Existing candidate/peer declaration workers
do not yet use it.

POST has exactly `reservation_id`, `context_sha256`, `kind`, `group_id`, and
`payload`. The payload is a canonical standard-base64 JSON string. Duplicate,
missing, unknown, null and incorrectly typed fields are rejected. The HTTP body
is limited to 96 KiB, each decoded nonempty payload to 64 KiB, and the complete
transcript to 192 KiB. The bound accommodates both maximum-sized opaque payloads.

| Slot | Sender | Required content | Result phase |
| --- | --- | --- | --- |
| `key_package` | candidate | Exact accepted package SHA-256; empty group ID | `awaiting-welcome` |
| `welcome` | intact peer | Nonempty opaque Welcome; canonical new group ID | `awaiting-ack` |
| `ack` | candidate | Empty payload; same group ID as Welcome | `exchange-recorded-inactive` |

The initial phase is `awaiting-key-package`. A group cannot equal the old source,
an existing native group, or another successor transcript's group. Its unique
SQL claim and the Welcome slot are committed in the same statement. Roles come
from the accepted reservation; they are independent of Alice/Bob name order.
The immutable reservation and custody response remain byte-identical. The
ordinary native target remains an empty inactive sentinel with no new events,
messages, attachments or membership changes.

Each response contains version 1, reservation/context binding, revision equal
to the number of slots, the phase, and `records`. Each record has `request`
(the complete normalized POST), `device_id`, and `sha256` of canonical request
JSON. A first append returns 201 only after its SQL CAS completes. Exact old-slot
retries return 200 with current transcript; a different payload/group or an
out-of-order append conflicts. There is no mutable message ID, replacement
slot, reset endpoint or automatic resend.

Every read and retry rechecks the current signed actor/device, accepted unexpired
intent, designated administrator, retired predecessor, active exact peer, old
source binding, complete original reservation, and paired declarations under
`Grant.Run -> Store.mu`. Missing rows and malformed/noncanonical stored data fail
closed without repair. Current revocation and source drift deny later access
while retaining the complete transcript and prior data. Request results describe
a current observation, not a lasting authorization lease.

An empty ack is only the candidate account's public statement. The server cannot
infer that it decrypted the Welcome. The next protected client unit must use the
**exact saved candidate KeyPackage/provider**, consume the Welcome through the
actual library, preserve the peer's old source and pending bytes, and verify
cryptographic continuity. Ordinary native workers generate fresh packages and
cannot be reused blindly. Product lifecycle and human acceptance remain separate.

## Storage and verification

Schema 7 adds `mls_successor_handshake` with a mandatory empty row per existing or
new reservation and a unique optional group claim. A schema 6 database receives
an owner-only `v6-before-successor-handshake-*.sqlite` snapshot before migration.
Old binaries deny schema 7 without mutating it; restoration is verified in a
separate directory. The snapshot allowlist admits the new prefix on subsequent
restarts and preserves unknown files. Older downgrade fixtures explicitly remove
the additive table before reconstructing their original schema.

Go tests cover ordering, exact package binding, strict wire/maximum sizes, role
and context rejection, group separation across reservations, immutable retries,
failed SQL commits, concurrent writers, restart, expiry/revocation/source drift,
corruption retention, and migration with retained declarations. The process
proof adds per-slot concurrent HTTP retries and owned-server SIGKILL, schema 6
upgrade/old-binary denial/isolated restoration, preserved prior chat/media/policy,
and continued denial of ordinary delivery. All payloads in these server proofs
are generated public/opaque fixtures, not proof of a completed MLS exchange.

No browser bundle, cryptographic library, live traffic or Yukson deployment is
changed by this server unit.
