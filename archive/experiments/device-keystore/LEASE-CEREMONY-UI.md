# Synthetic lease/channel ceremony UI

After the protected confirmation ceremony, `/lease-ceremony/` opens the same
stores with explicit actor, role, database, accepted request, independently
supplied canonical request digest, action (`activate` / `sync` / `send`), fresh
password and consent. Public files are untrusted scope hints. Authentication and
the exact current reservation/handshake/confirmation remain enforced by the
original lease workers. No new keys, automatic scope selection, retry, renewal,
global device enrollment or schema 13 are added.

This page is served by the loopback generated-assertion test fixture, not compiled
into the Go executable and not added to default CI (`verify` / `native` / `web`).
The ordinary binary still has no `/v1/mls/*` payload. Tracking: [issue #173](https://github.com/jinwon-int/family-messenger/issues/173).

The original lease worker opens `create:false`, commits its private transition
before a POST and reconciles the immutable pending slot. Full preceding
source/provider/package/pending bytes remain retained. An unknown response never
authorizes recreation or a new message identifier. Lock/timeout/visibility
retirement clears page credentials without erasing committed custody. The
uncertainty alert lasts for this page lifetime.

The public worker result has exact fields `committed, role, received, phase,
channel_full, outbox_status`. The page lists received synthetic texts in
`#received-list`. `#public-result` and the export file omit those texts.

| Action / result | What is locally known | UI state |
| --- | --- | --- |
| activate / awaiting-pair | Own lease approval saved; peer approval absent | awaiting-pair |
| activate / leased | Both approvals retained; channel may send | leased |
| sync or send / empty outbox | Channel state confirmed; no pending send | synchronized |
| send / pending | Exact ciphertext saved; server receipt unknown | outbox-pending |
| sync or send / blocked-capacity | 64-slot log full; sealed pending retained | channel-full |

Login assertion lifetime in the lease-ceremony fixture is 1800s so that an intent
expiry check (900s server cap, unchanged) is not masked by a login 401. That is a
test-token split, not a server-limit change. The discarded #16 assertion patch is
not applied to the product.

Human creation/recovery, global device enrollment, files, mobile and operational
acceptance remain. Synthetic accounts/policy only; live Matrix is untouched.
