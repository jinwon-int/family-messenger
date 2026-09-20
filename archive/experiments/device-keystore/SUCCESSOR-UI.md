# Synthetic successor lifecycle UI

The isolated `/successor/` page connects explicit DOM actions to actual protected
enrollment and closure stores. It requires private custody already created by
the preceding ceremony. The synthetic host supplies up to eight public scopes
through `installScopes([{identity,role,database,reservation}])`. This integration
boundary does not provision an identity, discover a directory or grant trust.
The page copies and freezes bounded descriptors; every worker still normalizes
the reservation and verifies protected custody and current server authority.

Neither scope nor action is selected by default. Users choose the target/device,
then participation observation, consent, closure observation or target closure.
Mutations require explicit consent and a vault password. The page clears password
and consent on selection changes, submission, completion, lock and visibility
loss. Credentials are neither saved nor reused. One worker handles each action,
with a 60-second lifetime; obsolete generation replies are ignored. Manual,
cross-tab and page-hide locks terminate the worker but cannot undo an earlier
commit. No automatic retry, polling, scope selection, activation or renewal occurs.

The worker adapter posts only fixed public status labels, never providers,
signatures, outbox entries or decrypted messages. Confirmed local commit precedes
POST and emits a progress event. Both observation actions never POST. An explicit
mutation retry reuses the exact sealed request. Error without confirmed local
commit means the local and remote result are unknown, not that no write happened.
Error after progress preserves the confirmed local-state claim and leaves the
server outcome unknown. Existing opaque failures cannot individually prove
revocation versus password/network/receipt failure; the UI states that authority
or password may have changed and requires explicit observation. It never presents
such a failure as confirmed revocation.

Successful states distinguish locally saved consent, own consent waiting for the
peer, paired consent awaiting administrator approval, current active admission,
local closure and confirmed server closure. Timestamps identify observations.
Unchanged stores preserve complete source, KeyPackage, old/enrolled provider,
pending ciphertext and tombstones. Global Devices enrollment is not implemented.

The paired browser proof uses the existing actual Welcome/confirmation/lease,
enrollment and closure sequence. Eligible lifecycle operations go through real
DOM selection/clicks using original protected store bundles. A subsequent private
observation validates the UI projection without submitting a missing mutation.
A separate instrumented fault bundle proves DOM closure CAS failure produces zero
POST. Coverage includes actual expiry, both roles, lost reply, restart, valid
current-device positive controls and post-closure denial, credential clearing and
absence of private page outputs. Existing proof variants remain separate.

These assets are an isolated synthetic preview and are not added automatically to
the production asset allowlist or default UI. Global device directory integration,
the complete human ceremony, files, mobile and operational acceptance remain
before cutover. No production deployment or traffic is changed.
