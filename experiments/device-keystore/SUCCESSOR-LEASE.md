# Synthetic successor channel lease

This is an explicit short-lived, target-scoped native channel, following the
protected Welcome and two MLS confirmations. It is not permanent enrollment.
The accepted replacement intent remains the authority: its original expiry
(maximum fifteen minutes after proposal), enrolled actors, administrator,
revoked predecessor tombstone, active intact peer and immutable source/target
bindings are checked on every request under `Grant.Run -> Store.mu`. Expiry or
revocation stops the next operation and retains all protected and server data.
There is no extension or implicit renewal.

Both protected workers must have committed `peer_verified=true`, both complete
confirmation records and no pending confirmation. In particular, a public
`peer_proof` cannot substitute for the candidate's local receive commit. The
worker saves a domain-separated Ed25519 approval inside its existing encrypted
store before publishing it. The approval binds role, reservation, complete
context/Welcome/confirmation hashes, exact group and original expiry. The
signature uses the existing pinned MLS signer; it neither exports a private
key nor creates a new group. The low-level isolated WASM helper signs only the
lease domain and checks the saved fixed-pair group. Protected state validation
and commit-before-release are the responsibility of the dedicated worker.

The server verifies both pinned signatures before opening the channel. These
are each device's explicit approval of the bounded channel, including its
claim of completed local confirmation. The server cannot itself inspect the
MLS group or prove IndexedDB durability; the paired browser test establishes
that the provided workers obey that contract. An empty ack, ciphertext phase,
or Cloudflare account header alone cannot grant the lease.

`/v1/mls/successors/{intent}/lease` has two immutable approval slots, either
order. First POST is 201, exact retry is 200. A channel requires both slots.
`/v1/mls/successors/{intent}/channel` GET/POST stores at most 64 application
ciphertexts, 4096 bytes each, with contiguous sequence numbers and immutable
(device, client_id) retries. It accepts no MLS membership or rekey controls.
The target reservation and ordinary native/legacy routes retain their existing
invariants and remain inaccessible through that target. Device policy and
its journal retain their original format and all tombstones. This avoids a
cross-database policy/admission transaction: one chat database commit controls
an immutable approval or message, while the current authority guard controls
its use. Already admitted bounded operations can finish while revocation waits
for their guard; this is not a lease across an HTTP request and a browser CAS.

Candidate v4 / peer aggregate v5 add protected lease metadata. Existing strict
confirmation validation is reused through a stripped view, including saved
provider, group, pins and exact KeyPackage. Full old source and pending bytes
remain retained. Each application encrypt/decrypt transition is staged, then
saved with the pending request or received plaintext before POST or display.
Unknown POST outcomes preserve the exact pending ciphertext and ID. Reopening
uses create=false; a complete public own approval cannot reconstruct missing
private lease state. The worker supports activate/send/sync and at most 256
UTF-8 plaintext bytes per message. It rejects changed plaintext under a used ID,
conflicting pending sends, stale receipts and malformed responses. A fresh send
against an observed full log is rejected before encryption. If the peer fills
the last slot after a local send was sealed, sync retains that exact pending
request and sender state, returns `outbox_status=blocked-capacity`, and keeps
received messages readable without repeatedly posting an impossible request.
`channel_full` is null during activate, which does not inspect channel history. Separate
workers own immutable arguments before any await, with bounded HTTP deadlines,
redirect rejection, fresh authority checks and expiry-aware IndexedDB CAS.

Schema 9 adds mandatory approval rows and a separate bounded ciphertext log.
Schema-8 upgrades first preserve a 0600 snapshot. Tests run the actual pinned
schema-8 executable, complete confirmations before upgrading, check its refusal
to open schema 9, and restore the snapshot into a separate generated directory.
Original successful bundles are tested separately from fault-injection bundles.
The browser proof covers real bidirectional MLS messages using saved ratchets,
local commit failure, lost replies, restart, expiry, revocation and preservation.

Permanent activation, subsequent replacements, key lifecycle, user-facing
recovery, file/mobile and operational acceptance remain necessary before a
Yukson deployment. No production policy, traffic, database or service is changed.
