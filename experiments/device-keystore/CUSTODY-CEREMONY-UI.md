# Synthetic protected custody declaration page

The `synthetic_custody` build and explicit `--synthetic-custody-ui` flag select
`/custody-ceremony/` and 22 pinned assets (profile10). The ordinary binary has no
payload. Previous profile manifests and original protected workers/stores are
unchanged. Signed synthetic authentication and loopback restriction remain.

Users explicitly select their identity, candidate/peer role, existing vault,
request and action. Every operation requires a fresh generated password and
consent plus the independently obtained sorted-key JSON reservation SHA-256.
Files are bounded public hints using the original handoff schema. They cannot
install identity, policy or keys. A missing vault is never created by this page.

Preparation invokes the original candidate bind or peer prepare worker, both
create=false. Declaration invokes the existing one-shot custody worker, which
owns normalized reservation fields before awaits, validates current authority,
and commits/authenticates the matching protected local state before POST. It
then checks bounded signed POST and GET receipts. Declaration can itself finish
an initial matching preparation, so the separate preparation action is useful
but not a prerequisite inferred from a public page flag. No worker or validator
is changed in this unit.

The display distinguishes a local preparation receipt, one's own declaration,
and both declarations while still inactive. A declaration is not private
possession proof, Welcome/ack continuity or device admission. Confirming a
declaration is an explicit operation that can resend the same immutable ID;
it is not a read-only action. There is no automatic POST, selection, retry,
renewal or activation. A failed/aborted/timed-out operation remains unknown.
Only validated public receipts enable export; private providers and credentials
never appear. Lock, broadcast, hide and navigation retire the caller and clear
credentials/output. The uncertainty alert survives subsequent page actions but
lasts only for that page lifetime. No restart acknowledgement history is added.

The client independently reconstructs the original public reservation wire order
to verify context hashes and its deterministic declaration ID. The human
comparison digest is separately computed over sorted keys. This consistency
check does not turn untrusted files into authority or claim actual human
out-of-band verification.

Real browser proof starts from an encrypted old native pair and an actually
saved candidate package supplied by explicit fixtures. Generated administrator
policy and reservation creation remain external fixtures. Both parties then
prepare through this actual compiled DOM and original workers, and explicitly
declare. Candidate-first, peer-first and concurrent declaration slots are
covered, swapping the actor roles. The candidate-first case waits real expiry;
other cases isolate peer revocation while unexpired. Alice retains a pending
rekey, Bob a real unsent application after verifying leader-only rekey rejection.
A separate private read-only inspector checks the full old source/provider/
pending digest; an abort-only fixture proves zero POST after failed local commit.
Their hashes remain separate from the normal compiled page/worker graph.
The fake Worker protocol suite is also separate from actual custody evidence.

Original candidate v1 and peer v2 only; no later store migration. Full human
creation/acceptance/recovery, Welcome/ack UI, global directory enrollment, files,
mobile and operational acceptance remain before Yukson cutover. Synthetic
accounts/policy only; live Matrix is untouched.
