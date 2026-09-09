# Private public-device succession intents

This implements the **candidate/decision/retirement portion** of
[DEVICE-LIFECYCLE.md](../docs/DEVICE-LIFECYCLE.md), in synthetic signed mode only.
It does not activate a replacement device, create a new conversation, restore an
active MLS leaf, prove a human recovery ceremony or deploy CF/Yukson.

## Selected version and management boundary

Version-1 policies retain their exact old encoding. A version-2 policy has a
required `successors` object containing explicit `administrators` and `intents`.
Version 1 with that object, version 2 without it, unknown versions, duplicate or
case-folded fields and JSON null are rejected. Existing private directory,
single-link files, owner/mode checks, bounded strict parsing, append-only checksum
history, flock, file/directory fsync and unknown/pending-file retention apply.
Older binaries cannot read the new version; retain the old binary and original
v1 history for inspection, not for silently restarting on a v2 policy.

Use a new private immutable proposal and the explicit CLI selection:

```sh
family-policy --synthetic-only --auth-state /private/generated-auth \
  --successor-policy --input /private/generated-proposals/policy.json \
  --expected-revision 2
```

The flag is valid only with `--input`. Ordinary `Commit`/CLI input cannot change
successor state. Ordinary key refresh and other existing maintenance may preserve
an unchanged successor object. Version 2 is permanent once selected; it cannot
be downgraded or stripped from history. Issuer/audience cannot change after its
selection. There is no new HTTP management endpoint, role header, public URL,
network key acquisition or authentication fallback.

The policy writer is the existing trusted local management process. An enrolled
subject/actor pair listed as a device administrator may be **recorded** as the
out-of-band confirmer. This is separate from the `owner` flag: the proof uses
non-owner Bob as administrator, while owner Alice is not automatically eligible.
The flag and `out-of-band-fingerprint` marker attest only to an explicit local
management declaration. The CLI does not authenticate the purported confirmer
or prove physical fingerprint comparison. Production still requires the
independently authenticated ceremony specified by the design. CF assertion,
archive/password possession and a claimed MLS owner label cannot invoke this
management API or add decrypting membership.

## Records and transition rules

First establish the administrator list in an intent-free v2 revision. A subsequent
revision may create a `candidate` intent for an existing active device. Administrators
must already be listed and enrolled in both prior and proposed policy; a new
administrator cannot approve itself in the same change.
After establishment the administrator list may be empty to deny all new approvals.
Emergency management can revoke all devices and clear people/administrators in
one revision, while retaining every intent and tombstone. No minimum administrator
requirement may prevent account revocation. A later re-enrollment still cannot
resurrect old devices or approve a candidate in the same administrator-setup step.

An intent contains immutable ID/action (`replace`), actor/subject, predecessor
ID/key/revision, unique candidate ID/key/fingerprint, package SHA-256 reference,
previous room/group and intended new room, selected administrator, acceptance
method, base policy revision and creation/expiry times. Keys are canonical
32-byte lowercase hex; fingerprint is SHA-256 of the raw public key. The package
reference is a canonical 32-byte digest, **not Go verification of an actual MLS
KeyPackage or proof of private-key possession**. Room/group references are
management intent data, not a room membership check or authorization to create
that room. Public-library verification and actual native room binding remain
required before a later activation.

Only these status changes are implemented:

| Transition | Durable effect |
|---|---|
| New candidate | Reserves new ID/key and one predecessor slot; no device or room admission |
| Candidate → accepted | Same policy revision changes predecessor active/1 → revoked/2 and records decision time/revision. Candidate remains outside `devices` |
| Candidate → cancelled | Records terminal cancellation; releases only the predecessor slot for a separate fresh intent |
| Exact latest accepted write retried | Returns the existing revision/hash without another write or renewed authorization |

Every intent, including cancellations, retains its ID/key forever within this
bounded store. No deletion, mutation of public bindings, resurrection, reuse or
second live intent for one predecessor. Acceptance requires a still-active exact
predecessor, current selected administrator and no concurrent people/owner or
administrator-list modification in that same revision. Account revocation or
administrator removal while a candidate is pending prevents later acceptance.
Cancellation is a trusted management denial action and may occur after expiry.

Candidates must be created within the preceding 60 seconds; expiry is at most
900 seconds after creation. Acceptance checks the actual current wall clock
**under the policy lock**, not only a caller-supplied past decision time.
Decision time must be within the preceding 60 seconds and acceptance before
expiry. An old completed decision remains readable after expiry. Historical
validation checks its immutable timestamps/adjacent revisions without comparing
them to today's clock. Clock rollback and replacement of a whole valid policy
prefix remain outside this local store's freshness guarantees; no independent
monotonic witness is claimed.

There are at most 8 administrators and 16 retained intents. Existing policy caps
remain 64 revisions and 64 KiB per file, and original device cap/uniqueness stays
32 devices with one device per actor including tombstones. No pruning or reset
is implemented. The new mechanism records a predecessor/terminal-candidate link,
not a multi-generation chain of activated devices. Extending that chain requires
a separate reviewed activation version; the current candidate cannot enter
`devices` even after acceptance.

## Atomicity, retries and live admission

The store reads the entire retained history under its lock, validates every
adjacent device and successor transition, then applies exact revision CAS and
fresh-time checks before writing. Intent acceptance and retirement occupy one
existing policy record and durability sequence. If writing is uncertain, retain
all evidence; do not reactivate the predecessor or retry a changed proposal.
Live refresh may skip intermediate revisions only after the store has validated
all of them. Terminal intent immutability is also checked on direct trusted
`Authority.Replace` calls; a constructor's in-memory Config is trusted input,
not proof of prior durable authorization.

`CommitSuccessor` reconciles only the immediately preceding **identical full
canonical policy**, with latest revision equal to expected+1. A conflict, older
outcome, changed metadata or subsequent management change is denied. Inspect
current revision/hash and retained intent explicitly; do not automatically choose
a new expected revision or re-encrypt an operation. Ordinary legacy Commit keeps
its original conflict behavior.

Disk retirement becomes visible to the serving authority on its next successful
reload (the existing poll interval is one second, not a hard instantaneous
cross-process barrier). After reload all earlier grants are invalid, and any
operation using either pin of the old MLS room is denied. An already admitted
bounded operation may complete under existing grant semantics. A selected bad
policy suspends the authority and cannot fall back to an earlier version/fixture.
This implementation does not claim immediate synchronous HTTP revocation at the
instant the separate CLI returns.

`Grant.DeviceBindings` contains only original devices/tombstones. Candidate keys
are never supplied to `activePin`, directory responses or room creation. Both
participants' exact active room pins remain mandatory; a non-revoked peer cannot
keep using an old room whose other device was retired. Legacy text/media account
access is unaffected by *device-only* retirement and remains subject to account/
room policy. No chat schema or content is rewritten.

## Evidence and remaining work

Run the generated process proof:

```sh
python3 tests/native_policy_smoke.py --successor \
  --binary artifacts/family-dev-successor \
  --policy-binary artifacts/family-policy-successor
```

The proof spawns only its own signed loopback server and actual management CLI
processes, with disposable RSA account assertions and declared public device
fixtures. It verifies mode/administrator/expiry denial, exact two-writer retry,
conflicting decisions, old/candidate room denial, actual server SIGKILL/restart,
unchanged original policy/chat/media and unsafe-v2 startup/reload denial. It does
not run MLS crypto or represent the public fixture bytes as real private devices.
Go tests additionally cover malformed/versioned policy, immutable binding changes,
semantic history tampering with recomputed hashes, lock-time expiration, skipped
reload and injected pre/post-rename uncertainty. Injected errors are not claimed
as a real power-loss or mid-fsync process kill.

No dependencies, crypto, frontend assets or runtime services are added. Existing
Go JWT/SQLite modules, licenses, cgo/libc and resource limits remain. Next: qualify
an intact enrolled signing key in a new encrypted group context, then native
bootstrap/Welcome/ack and explicit peer acceptance. Human ceremony, mobile,
actual CF gate, isolated backup restore, production capacity and fleet acceptance
remain before Yukson cutover. Existing services/data/backups/Telegram and all 12
original-node runtime credentials stay in place.
