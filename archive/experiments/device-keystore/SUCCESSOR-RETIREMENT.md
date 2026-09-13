# Permanent synthetic successor channel retirement

Either current participant may permanently close the target-only lease after
both protected confirmations and both lease approvals. This is a lifecycle
transition, not permanent candidate enrollment. It adds no device, changes no
policy entry and never erases a key, old source, pending operation or message.

The worker requires the actual existing protected lease record, pinned signer,
exact group/provider, original KeyPackage and locally complete MLS confirmation.
It seals a terminal record before a retirement POST. Candidate v5 / peer v6
are rejected by the older exchange/confirmation/lease workers, so an unknown
POST cannot make the local sender usable again. A blocked full-channel outbox
remains byte-for-byte retained with all the previous lease data. There is no
undo or reset operation. A second current participant may independently close
the same channel; the first server record remains the immutable winner.

The signed request is `{role, signature}`. It uses the existing isolated lease
signer with the distinct digest frame `family-successor-retirement`, version 1,
role, reservation ID, context/handshake/confirmation hashes, exact group and
original intent expiry. The outer signing prefix remains
`family-successor-lease-v1\0`; the different digest frame separates the meanings.
A lease approval cannot be reused as a retirement or vice versa. Default and
identity-context WASM bundles, all original asset pins and the existing
successor-lease feature remain unchanged.

The server requires the current signed assertion, enrolled candidate account,
current intent administrator, exact revoked predecessor and active intact peer.
It checks these inside `Grant.Run -> Store.mu`. The retirement POST additionally
requires an unexpired accepted intent and verifies the request against the pinned
role key. A single database update records the winner before replying. Under the
same store lock, all lease/channel GET and POST requests reject a committed
retirement, including exact message and approval retries. Missing or corrupted
retirement metadata fails closed. Source/target reservations and public protocol
records remain retained; no ordinary delivery or target admission is enabled.

`GET /v1/mls/successors/{intent}/retirement` is a distinct read-only observation.
It includes the completed public handshake, confirmation, lease and optional
terminal receipt, with a 224 KiB client bound. It can observe an expired intent
but still requires current accounts, administrator, device bindings and assertion.
`SuccessorRetirementHistory` is deliberately not used for any write or delivery.
An expired worker never sends a retirement POST. A locally pending retirement
can be inspected and remains terminal even when the server never accepted it.
A saved terminal receipt cannot regress to an empty or different public receipt.

`observe` seals a verified server retirement only into a pre-existing, validated
private lease record; public metadata cannot reconstruct missing private custody.
It may do so after intent expiry. It cannot create a new retirement without a
server receipt. Local CAS failure, timeout, abort, response corruption or authority
revocation preserves all previously committed bytes. Network authority and a
browser transaction are not one atomic operation: fresh bounded reads precede
CAS, while any subsequent server action uses its current authority guard again.

Schema 10 adds one nullable terminal slot per existing reservation. Schema-9
upgrades retain an owner-only SQLite snapshot. Tests separately cover migration
of a paired lease with messages, the actual schema-9 executable's snapshot/restore
and refusal of schema 10, local CAS failures, both first-winner roles, dropped
POSTs, lost replies, worker/server restart, expired observation, malformed and
rolled-back receipts, and current-policy revocation. Successful operations use
original workers; fault and preservation observations use separate test bundles.

Permanent enrollment still needs an explicit policy/journal contract for replacing
an actor's first device while retaining its tombstone, new scoped participant
consent, and actual durable message authority. Lease expiry is never promoted to
that authority. Human recovery, files, mobile and operational acceptance remain
before Yukson cutover. This unit uses only generated synthetic loopback fixtures.
