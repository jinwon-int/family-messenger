# Two-device preparation for a new synthetic conversation

This is an isolated native control boundary preceding the aggregate chat UI.
The previous server accepted target binding after just one local aggregate fork.
That could make the other device's first fork ineligible and strand the pair.
A new, explicit protected reservation now waits for both enrolled devices'
preparation declarations. The existing legacy and unprotected synthetic room
protocols are preserved. No product UI, production activation or recovery is
implemented here.

## Public API and atomic order

All calls require signed admission plus `X-Family-Device` matching the admitted
actor. No fixture fallback, email/owner-role inference or enrollment is added.
The existing host/origin, bounded body, exact JSON and authority -> Store lock
order applies. Body reads occur before authority/Store admission; no network or
client cryptographic operation runs inside either lock.

- `POST /v1/mls/context-reservations` has exactly
  `{room,source_room,source_group}`. The source creator device must still belong
  to a ready source room with the specified group and two active immutable pins.
  One SQLite transaction creates the MLS-only target, its member pair, a required
  custody marker, and the immutable source/group/pin descriptor. Existing legacy,
  unprotected, conflicting or nonempty rooms cannot convert. Exact reservation
  retry reconciles the existing outcome after later source/target progression.
- `GET /v1/mls/rooms/{room}/preparation` returns exactly
  `{version:1,room,source_room,source_group,pins,prepared}`. Both source and target
  must authorize the caller and both exact active device pins. `prepared` contains
  zero to two `{device_id,intent_id}` entries, one immutable entry per device.
- `POST` to the same preparation route has exactly
  `{source_room,source_group,intent_id}`. Only the caller's own device entry can
  be added, before binding; the same entry retries exactly, a conflicting intent
  is denied, and no delete/reset route exists. Each accepted entry is durable
  before the response. Exact accepted retries remain queryable after binding.
- The existing `POST /v1/mls/rooms` bind operation checks the protected marker
  and both preparations under its actual Store lock. Zero/one declaration denies
  with409. Revoked, substituted, wrong-actor or missing/corrupt preparation state
  denies. Calling the old reservation endpoint cannot remove the barrier. A missing
  preparation row cannot downgrade a marked target to the old protocol.

A family principal's device administration is separate from AI owner execution.
Source creator here means the existing MLS room creator, not an account's owner
flag. No additional/replacement device activation or signing-key change is added.
The target still needs a fresh group, KeyPackage, targeted Welcome, ack barrier and
actual OpenMLS sender/pin validation before application delivery.

## Client bridge: complete custody before declaring

`prepared-fork-worker.js` is an explicit new experiment entry using the unchanged
`AggregateStore`. It checks the protected public descriptor with independently
accepted source/group/room/pins, calls the existing complete encrypted local fork,
and only after its strict IDB commit sends its own native preparation declaration.
All HTTP responses are bounded to4KiB/5seconds, exact fields and expected actor;
redirects/cache are denied. Malformed/unknown/locked/missing state retires the
worker. No password, root or provider leaves it. The one-shot caller must terminate
on boot/clone/timeout/error; the existing disposable aggregate caller exercises
this contract. Generated passwords retain the32..128/defaultscrypt18 boundary.

The response distinguishes local `committed`, `preparation_accepted` and
`pair_prepared`. None means MLS connection or message delivery. If the native
response is lost after local commit, the encrypted target/intent stays in place;
reopen repeats the exact local outcome and the exact native declaration. There is
no automatic rollback, re-encryption, repinning or new-key generation. No crypto
or network wait is introduced into IDB. Source provider/outbox/cursor/cache and
old-epoch pending rekey behavior remain unchanged.

These are authenticated **declarations**, not cryptographic proofs that a hostile
principal stored private state. The server cannot inspect that state. The selected
worker orders its declaration after local commit; a malicious authorized caller
can lie about its own readiness. Nor is this a distributed server/IDB transaction:
a server change after the last read can still cause denial, and revocation freezes
the pair. Missing target history cannot be repaired by clearing the slot. This
closes premature binding by the conforming clients, without claiming recovery,
a rollback witness or protection from malicious same-origin code.

## Storage preservation and bounds

Additive SQLite schema4 adds `mls_preparations` and an explicit required-custody
marker on `mls_rooms`. A real schema3 database is first retained as a fresh private
`v3-before-preparation-*.sqlite` snapshot. Upgrades from1/2 retain their existing
original pre-migration snapshot once. Unknown files, partial snapshots, journals
and unsupported schemas stay preserved/denied. No old database or browser profile
is reinterpreted as a protected reservation. Old binaries reject the new schema;
rollback means an isolated prior snapshot, never replaying a stale live sender.

The existing32-room server quota bounds descriptors; each has two public pins and
at most two short intent IDs. No cache service, new crypto or runtime dependency
is introduced. Original9/15/21 asset bundles, old aggregate fixtures and default
workers are unchanged. No preparation worker is embedded by this unit.

Run the generated proofs with a newly built schema4 binary:

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --preparation \
  --bundle artifacts/identity-context-build-smmbyhm5/candidate \
  --binary PATH_TO_NEW_FAMILY_DEV --policy-binary PATH_TO_FAMILY_POLICY
.venv/bin/python tests/native_mls_transport_smoke.py --preparation \
  --binary PATH_TO_NEW_FAMILY_DEV --policy-binary PATH_TO_FAMILY_POLICY \
  --legacy-binary PATH_TO_PRESERVED_SCHEMA3_BINARY --legacy-version 3
```

The browser proof uses actual OpenMLS state and native APIs, including lost
preparation response plus owned-browser SIGKILL, server restart, exact retry,
source pending preservation, encrypted text/8KiB file exchange and revocation.
It is not a DOM UX proof. The next unit is aggregate UI orchestration selecting
this protected reservation and worker; all existing synthetic/plaintext modes
must remain explicit. Human lifecycle/mobile/actual CF/backup/capacity/fleet
acceptance and Yukson deployment remain open.
