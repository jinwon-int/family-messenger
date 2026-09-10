# Signed replacement context preflight

This is a runnable **read-only authorization boundary**, not replacement activation
or completed recovery. `GET /v1/mls/successors/{intent_id}/context` connects a
version-2 accepted [successor intent](SUCCESSORS.md) to the actual old native room.
Existing signed synthetic authentication, same-origin/Host, exact paths, no-store
and nosniff apply. Fixture bearers cannot call it. Non-GET methods, missing or
ambiguous device headers and every query alias, including bare `?`, deny.

Two callers may obtain the same public descriptor: the currently enrolled
replacement actor naming its exact candidate device ID, and the old room's still
active peer naming its enrolled device ID. A candidate ID is not proof of its
private key. Neither caller gains device-administrator or owner-execution powers.
The descriptor omits subjects, administrators, messages, outboxes and secrets.

At verification, the authority captures only accepted intents whose original
subject/actor remains enrolled and whose designated administrator is still
enrolled and designated. Grant.Run checks token/key expiry and retires all captured
inputs after policy replacement or suspension. Under the subsequent Store lock,
preflight rechecks intent expiry, actual group, canonical stored pair pins,
creator/peer, exact room membership, revoked predecessor (revision 2) and active
peer (revision 1). A changed subject cannot inherit an old subject's intent.
Cancelled, merely proposed, unknown and expired intents deny. No tombstone or
one-device uniqueness rule is relaxed; candidates stay outside DeviceBindings
and activePin even after successful preflight.

The source must have completed its fixed-pair native handshake (`ready`, matching
control revision/epoch). Pending local applications or a not-yet-accepted local
update may coexist with that state and remain untouched. A server-accepted update
awaiting its ack **denies in this unit**. Native metadata is not proof of MLS
validity: actual providers, credential/signing keys, frames and controls still
require client OpenMLS validation.

Version-1 output binds intent/decision revision/expiry, old room/group, proposed
new room, original predecessor pin, prospective candidate pin, active peer pin,
candidate fingerprint and package digest. `admission: preflight-only` is explicit;
the prospective candidate revision 1 does not mean active device status. Consumers
must independently accept full bindings, not treat directory data as a ceremony
or automatic repin instruction. The package digest is still a management reference,
not verification of an actual KeyPackage or private-key possession.

The target name must be unused, including by legacy or reserved rooms. Checks use
authority -> Store lock order without network/crypto waits or IDB access. GET
does not reserve a target. A room may be claimed or policy revoked after response:
this is **not a distributed lease** and cannot authorize a client slot commit or
bypass native CAS. Repeated reads before changes return identical public bytes;
after target occupation they conflict instead of returning stale eligibility.
Future committed write outcomes need separate durable identity/retry rules.

Accepted-intent expiry never refreshes on reads/restart. Its original maximum
900-second window is enforced. There is no implemented renewal of an accepted
intent; after expiry this preflight cannot advance it. Historical archives remain
readable with their password and never resume a sender or prove rollback freshness.

## Reproduce and continue

```sh
python3 tests/native_policy_smoke.py --successor --successor-context \
  --binary /private/generated-build/family-dev \
  --policy-binary /private/generated-build/family-policy
```

The extension uses generated signed accounts and opaque native fixtures, not a
browser E2EE or human recovery proof. It checks both authorized readers, denial
before acceptance and for old/wrong devices, actual server SIGKILL/restart with
exact descriptor replay, candidate delivery denial and late legacy occupation.
Original policy/chat/media checks and original `--successor` compatibility remain.
Go regressions additionally cover captured-intent expiry, snapshot isolation,
account/administrator/peer revocation, cancelled/unknown intents, wrong room/group,
corrupt pins/creator/epoch, extra/missing members and unacked source controls.

No schema/migration, custody/crypto, UI/asset pins, dependency/license or production
service changes. Existing limits and profiles remain. Next: explicit durable
successor target reservation and custody barrier, preserving the intact peer's
source and pending state; new candidate worker custody; independent acceptance;
targeted Welcome/ack before new-room delivery. Do not disable old-room admission
to reuse ordinary both-active context preparation. Human ceremony, expired-intent
renewal, unacked-control recovery, mobile, actual CF, backup/capacity/fleet
acceptance remain before Yukson cutover.
