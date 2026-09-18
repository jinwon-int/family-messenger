# Lost and replacement devices: qualification and implementation decision

The subsequent [signed successor context preflight](https://github.com/jinwon-int/family-messenger/blob/archive-frozen-20260917/archive/native-mls/server/SUCCESSOR-CONTEXT.md)
checks accepted intent against the actual old room and healthy peer. It is
read-only; replacement custody, activation and human acceptance remain open.

Status: **reviewable design and isolated library evidence, no native enrollment
change or human recovery acceptance**. Additional/replacement devices remain
denied by [the native policy](../server/DEVICES.md). CF login identifies an
enrolled account; it does not approve a new decrypting key. Nothing in this
change alters the server, asset manifests, production services or old profiles.

Subsequent implementation: [public successor policy](https://github.com/jinwon-int/family-messenger/blob/archive-frozen-20260917/archive/native-mls/server/SUCCESSORS.md)
records candidates and atomic retirement, while continuing to deny new-device
activation. The design below describes the full lifecycle; its ready/bootstrap
and healthy-signer custody requirements remain open. Disk retirement reaches a
live server on its next validated reload, not synchronously when the CLI returns.

The subsequent [intact-signer library boundary](https://github.com/jinwon-int/family-messenger/blob/archive-frozen-20260917/archive/experiments/openmls-browser/IDENTITY-CONTEXT.md)
constructs a signer-only fresh provider without changing the old group. It is an
optional memory-only generated-data proof, not encrypted multi-room custody or
replacement activation; its concrete atomic-storage follow-up remains required.

## Decision

Keep two different authorization paths explicit. An intact, independently trusted
device can communicate its same-actor replacement intent through an authenticated
MLS application message. OpenMLS supplies that message's authenticated member,
credential and signing key, **not** the application's authority to approve devices.
The exact immutable candidate must be confirmed on that trusted device through a
separate user action. Merely receiving a KeyPackage or a message claiming to be
from the owner cannot enroll anything. A compromised trusted device remains a
compromised authorization factor; this mechanism cannot infer human consent.

When no trusted same-actor device survives, do not fabricate such approval from a
login, server-directory entry or history archive. Use explicit independently
authenticated out-of-band reprovisioning, retire the old device, and establish a
**new conversation with a new room/group binding** after both participants accept
the new public bindings. Preserve the old room and its history as closed historical
data. This is a new MLS group, not RFC 9420 ReInit, PSK resumption or an archive
restore. ReInit assumes prior group secrets; an archive cannot resume a sender.

For the first native lifecycle implementation select an **operator-assisted,
out-of-band successor/new-conversation path**, also available when an intact old
device helps confirm the candidate. Defer automatic same-actor approval and
in-place group membership replacement until their complete authorization/control
contracts are implemented. This avoids asserting that an encrypted approval
message is a signature the server can independently verify. The server cannot
read that message; a client saying “approved” is not independently verified proof.

An acceptable human ceremony requires an independently known person/contact
channel, direct comparison of the new device's displayed full public fingerprint
and actor/intent, a separate explicit confirmation by a designated device
administrator, and peer acceptance before decrypting membership. The contact
channel must not be derived solely from the untrusted login/directory/recovery
request. The administrator records the comparison, identity-verification method,
intent and exact public binding, without secrets. The application can enforce
record structure and permissions; it cannot prove that a person performed that
comparison. A local policy marker is a management declaration, not cryptographic
proof of a ceremony. No actual family ceremony has occurred in this experiment.

## Immutable public transition and separation of authority

Use a new versioned lifecycle policy, preserving old encodings/history and
tombstones. The candidate record must bind all of:

- Unique intent and candidate device IDs, action (`replace`, not implicit add),
  stable actor and enrolled issuer/subject binding.
- Actual public credential/signing key, the existing SHA-256 fingerprint of its
  raw public key, and the exact validated KeyPackage or its digest/reference.
  MLS validates the KeyPackage's signature and credential against independently
  expected public material. It does not authenticate a bare account label.
- Exact predecessor device/key and device revision; current policy revision;
  expiry and explicit `candidate` / `accepted` / `revoked` status transitions.
- A designated authorizing principal and evidence method/intent. Device
  administration is distinct from family room access and owner-only AI execution.
  Same-actor approval is allowed only from that actor's independently trusted,
  active device, not from another family member or an unverified new device.
- The closed predecessor conversation and new immutable room/group/member
  bindings. Approval for one candidate/room cannot authorize another room, group,
  device, operation or execution privilege.

Device IDs/keys and accepted intent bytes never change in place. No tombstone
deletion, key substitution, device-ID reuse, reactivation, implicit family bots,
owner-role inheritance or automatic peer re-pinning. At most one active device
per actor in the first successor policy; extra simultaneous devices are a later
feature. An accepted candidate is not automatically a ready MLS member.

The current policy's one-device-ever constraint **must not simply be removed**.
A future additive, explicitly selected schema must validate the entire retained
predecessor/successor chain, unique immutable keys and IDs, and a single active
successor. Old binaries must reject that schema, not silently ignore its semantics.
Selected missing/corrupt/unknown state fails closed; retain recovery artifacts.
Independent account removal/revocation still denies admission after a successful
device ceremony. Changing device administrators must not change owner execution
authority. Existing node runtime credentials stay on all 12 original nodes.

## Ordered activation, uncertainty and restart requirements

These are **required future implementation tests**, not results of the library
probe. A policy/database transition is not atomic merely because both use CAS.
The design uses fail-closed phases so a crash never exposes a half-active device:

| Phase or failure | Required outcome |
|---|---|
| Candidate created | No directory-active key, group membership or send permission; immutable bounded proposal and expiry |
| Fresh authorization/confirmation | Recheck subject, predecessor, policy and intent revisions after external waits; no IDB or identity lock across network/prompt |
| Competing proposals or duplicate confirmation | Exact accepted ID/bytes returns the existing outcome; conflicting ID/bytes or stale revision denied, no automatic conflict retry |
| Retirement committed | One durable policy revision revokes predecessor and records accepted successor intent; successor remains inactive. Old-room admission freezes immediately; partial progress is closed, never rollback to active predecessor |
| Crash before new-room creation | Restart retains tombstone and accepted intent; resume only exact unexpired authorized candidate, or explicitly abandon it without resurrecting the old key |
| New conversation bootstrap | Reserve a new MLS-only room, bind independently accepted keys and actual group ID, use targeted KeyPackage/Welcome and committed ack barrier. No plaintext conversion or reset of old group |
| Crash/lost response during bootstrap | Persist full provider/pins/exact outbox/cursor/cached result before output. Reopen the exact committed operation; do not regenerate keys, repin or silently re-encrypt |
| Ready transition | All required membership/Welcome acknowledgements and current policy revisions match; only then expose new conversation sending. A server assertion of readiness cannot replace client MLS validation |
| Revocation/expiry during any phase | Deny late output/activation and retire worker; keep uncertain bytes/evidence. Locked/unavailable keys are not automatically revoked, and revocation is not a reason to erase ciphertext |
| Old pending application/control | Never replay into the new group. Preserve it as unresolved historical outbox; exclude never-accepted local frames from delivered history |
| Whole valid policy/profile rollback | Without an independent monotonic witness, cannot safely infer freshness after restart. A valid old archive is history only, never restored active state |

For a later **in-place** replacement, the library can Remove then Add, but the
product additionally needs membership-authorized staged commits, exact ordered
control CAS, commit broadcast to every current member, targeted Welcome,
old-epoch receive before own commit merge, and an ack barrier. Validate the actual
MLS control sender/credential/key, all proposals and resulting member set. Do not
reuse the fixed-pair `peer_update` path: it deliberately rejects membership
proposals. If a removed device does not receive its Remove commit, it still must
not decrypt future-epoch traffic; withholding a commit is not a safety bypass.

## What the runnable proof establishes

Run from the repository root with the already verified pinned browser bundle:

```sh
.venv/bin/python archive/native-mls/tests/native_mls_browser_smoke.py --lifecycle \
  --bundle artifacts/mls-remapped-pkg
```

The existing exact-allowlist loopback harness serves a separate
`lifecycle-worker.js` only for this option. Two disposable Chromium contexts
coordinate public keys, KeyPackages and synthetic application ciphertext.
Staged provider/signer state remains in workers, never page/storage/log/URL or
proof JSON. No native server, enrollment endpoint, network protocol relay,
encrypted vault, actual account or history import is invoked. Worker errors
retire the instance; fresh test cases explicitly create unrelated devices.

The proof uses unchanged public wrapper APIs over OpenMLS 0.9.0:
`verify_device_package`, `staged_trusted_apply` with `decrypt_peer`, and generic
staged Remove/Add/Welcome. `decrypt_peer` checks actual processed MLS member,
credential and leaf signing key before releasing application bytes. A negative
wrong-pin case can fail at the wrapper's prior group-member binding check; it is
not evidence that the test bypassed that check to reach an inner comparison.

It demonstrates different keys with the same BasicCredential, wrong-key/actor
and damaged-package denial, exact public candidate-intent carriage, replay/
tamper/wrong-group denial, removal before/after delivery of its commit, and new
member text/1 KiB opaque bytes. It also demonstrates the important counterexample:
a valid pinned Bob message can contain a false `alice/owner` application label.
MLS does not validate that claim; production must reject it as authorization.
The sample intent is **test data**, not a new approval protocol or signature.
There is no claim that expiry/revision/role semantics are enforced by this probe.

The generic Remove/Add probe leaves one member before adding the new device;
the synthetic coordinator immediately merges its own commit. It does not test
native membership authorization, concurrent commits, crash persistence, server
CAS, delivery ack barriers or three-device groups. The final page-loss case
destroys all original worker state, then independently accepts **both** fresh
synthetic keys and a fresh group. New messages work; old ciphertext is denied.
This is not a SIGKILL/restart proof of a persistent replacement implementation.

## Concrete remaining integration blockers and next work

1. Implement and adversarially test the additive **public successor policy and
   fail-closed retirement phases** before any native replacement acceptance.
   Native APIs must keep rejecting unsupported replacement even if the library
   can perform Remove/Add. Include concurrent policy writers and actual process
   crash/restart with original data preserved.
2. Qualify fresh-group creation for an **intact enrolled signing identity** in a
   separate encrypted conversation context. The current snapshot has one group
   and `staged_init` generates a new signer. This probe replaces both synthetic
   keys; it does not solve preserving a healthy peer's signer across conversations.
   Never regenerate a healthy enrolled key or transfer provider state through
   the page as a shortcut. Needs public OpenMLS APIs and atomic multi-conversation
   custody with preserved old pins/state, followed by native transport/UI binding.
3. Implement independently accepted new-conversation linkage and truthful readonly
   old-history UI. Peers must explicitly accept changed identity; a server hint
   alone cannot update pins. Automatic trusted-device approval requires a
   separately qualified verifier/management boundary; it remains deferred.
4. Human ceremony, mobile memory/lock behavior, actual CF account gate, isolated
   server-backup restore, production actors/groups/history capacity and approved
   fleet binding remain acceptance gates before production-host cutover. Preserve existing
   services/backups and Telegram fallback. Readonly history recovery does not
   guarantee continuing conversations after complete device loss.

The subsequent [protected intact-peer experiment](https://github.com/jinwon-int/family-messenger/blob/archive-frozen-20260917/archive/experiments/device-keystore/SUCCESSOR-PEER-CUSTODY.md)
qualifies same-database encrypted custody of a fresh signer-only context against
an inactive reservation, preserving the complete old record and pending update.
It introduces an explicitly selected inner format that older drivers reject;
candidate private custody, activation, client/history support and human-use
acceptance remain open. It does not turn this design's library probe into a
complete replacement-device or recovery workflow.

## Primary sources and costs

[lifecycle-evidence.json](https://github.com/jinwon-int/family-messenger/blob/archive-frozen-20260917/archive/experiments/openmls-browser/lifecycle-evidence.json)
records the receipt, source references and pinned versions. RFC 9420 §5.3 calls
BasicCredential a **bare assertion**; §5.3.1 assigns credential validation to the
application's authentication service. §5.3.3 warns that identifiers can be
nonunique across devices. §§12.1.1–12.1.3 and OpenMLS Add/Remove/credential-validation
documentation define library membership operations, not account recovery.

The current OpenMLS removal book prose mentions `KeyPackageRef`, but its code
and pinned 0.9.0 `membership.rs` use `LeafNodeIndex`; follow the actual pinned
API. The book's short return-type prose also omits `GroupInfo`; no code is copied
from those examples. Existing wrapper uses `remove_members(...[LeafNodeIndex])`
and `add_members`, retaining normal path updates; no external sender, custom
signature, WebCrypto cipher/KDF, PSK recovery or unchecked protocol feature.

No dependency, lockfile, Rust source, WASM/JS binding, production bundle or
license changes. Existing OpenMLS browser graph: 8 direct/151 transitive external
crates, 197 across all targets; existing Rust notices including tls_codec MPL-2.0
remain applicable. Browser support is still upstream unsupported/built-only;
the historical core audit excludes crypto/storage providers and this application.
New own test glue only; Python/Playwright/Chromium are existing test dependencies.
WASM memory measurement is maximum per worker at operation boundaries, excludes
JS/browser/aggregate memory, and is a test threshold rather than an allocator cap.
This probe does not run password KDFs or install tooling. Keep the 5 GiB additional
disk / 128 MiB WASM budgets and separately account 256 MiB scrypt scratch for any
later custody proof. Neither this design nor a primitive roundtrip is a production
keystore or complete lifecycle security audit.
