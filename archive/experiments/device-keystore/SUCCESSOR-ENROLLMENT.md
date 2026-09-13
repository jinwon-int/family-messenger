# Explicit persistent target enrollment

This synthetic transition grants continuing authority to one previously unused
successor target. It does not add a device to the original global `Devices`
list, restore a predecessor or qualify family production deployment. The first
bounded persistent channel still has a 64-message capacity limit.

Eligibility requires an accepted, unexpired replacement intent, its exact saved
KeyPackage/group, actual paired protected MLS confirmation, and both existing
lease approvals. The old target channel must have zero events; each protected
store must have no target pending message or target send/receive history. A used
or retired target is rejected. Unrelated old source messages and pending
operations remain byte-for-byte retained.

Three distinct commits are required:

1. Each browser seals its fresh persistent enrollment consent and its continuing
   provider under its existing protected store lock before sending any consent.
   Candidate v6 / peer v7 preserve the complete former lease, including its
   provider, and hold a separate active copy of that exact provider. Older
   workers reject these formats. A retirement format cannot be promoted.
2. The server accepts pinned candidate and peer signatures under `Grant.Run ->
   Store.mu`. The first consent closes the old lease routes under the same lock,
   preventing further old target writes. Both signed consents are immutable.
3. An administrator explicitly commits policy version 3 with
   `--activation-policy`, binding the exact paired enrollment record digest.
   This new grant must be committed before the original intent expires. It is
   separate from the earlier lease approval and is never created by a browser
   or by observing a server phase.

The policy field is `activations: [{intent_id, approval_sha256, status}]`.
`approval_sha256` is SHA-256 of canonical JSON for the server's `enrollment`
record. `active` may transition only to `revoked`; bindings and tombstones cannot
be removed or rebound. An activation change cannot carry account, device,
administrator, intent or key changes. The old policy commit modes reject such a
change. Every adjacent durable revision is checked again on journal reload.
Exact previous-outcome reconciliation retains the existing uncertain-write rules.

Consent signs SHA-256 of the JSON array
`["family-successor-enrollment",1,"persistent-unused-target",role,reservation_id,
context_sha256,handshake_sha256,confirmation_sha256,group_id,original_expires_at]`.
It uses the existing isolated signer's outer `family-successor-lease-v1\0`
prefix. Its distinct semantic frame cannot be substituted for lease/retirement
signatures. No Rust feature or legacy compiled asset pin changes.

`enrollment` and `enrolled-channel` are separate routes. Every persistent read
or write requires a current assertion/account/administrator, exact original
revoked predecessor and intact peer/source, a non-retired target, both valid
server consents, and the matching current activation digest. Intent expiry does
not remove that new grant; policy revocation does. Expiry never creates a grant,
allows a new consent, or renews anything. Original target routes stay closed.
Administrator revocation is the supported post-expiry closure in this unit;
a participant retirement ceremony for the new protected format remains future
work. Existing server retirement tombstones always deny enrollment use.

The policy journal and chat database are separate transactions. There is no
claim of a shared atomic commit: either can commit first, and delivery remains
closed until both match under current authority. Similarly, browser CAS and
remote policy are not one transaction. A final bounded read precedes local CAS;
the subsequent server write rechecks current authority. Unknown replies retain
the exact sealed consent/message and never generate a replacement identifier.

The active provider advances only inside encrypted local commits. The complete
former source, original KeyPackage, lease provider and pending operations remain
frozen. Missing private enrollment state cannot be reconstructed from public
consents, even when the administrator has activated their digest. A race that
adds an old target message before the first server consent causes rejection and
retains local state; it does not silently choose another group or scope.

Schema 11 adds mandatory enrollment slots and a separate bounded event log.
Schema-10 upgrades retain a private snapshot. Legacy policy versions and device
validators remain enforced. Tests use generated local accounts/administrator
policy, original successful browser workers, separate fault instrumentation,
actual expiry and server/worker restarts. Global device enrollment/directory,
participant closure, human recovery, files, mobile and operations still need
acceptance before Yukson cutover.
