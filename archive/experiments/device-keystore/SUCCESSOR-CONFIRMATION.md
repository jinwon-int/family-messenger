# Protected peer confirmation before activation

A completed Welcome exchange has an empty server ack. That ack does not show
that its sender loaded the accepted package's private provider. This explicit
synthetic confirmation step sends two MLS application messages using the
already committed group and verifies the actual remote MLS member on receipt.
It does not create a group, enroll a device or grant native delivery.

The candidate encrypts a fixed confirmation frame. The peer decrypts it with
`staged_trusted_apply(..., "decrypt_peer", ...)`, checking the independently
pinned candidate credential/signing key. Only after matching the entire frame
does it encrypt a response. The candidate similarly verifies the actual peer
and exact response frame. Both frames bind a domain and version, role,
reservation, normalized context hash, complete Welcome transcript hash and group.
The peer frame additionally binds the exact candidate ciphertext record hash.
No user-supplied application payload or general send command is exposed.

Each sender/receiver provider transition and pending request commit together in
the existing protected database's strict compare-and-swap transaction. A POST
happens only after that commit. Unknown delivery retries the same ciphertext;
a server receipt never reconstructs a missing private sender transition. A
received ciphertext is not consumed again after its verified result commits.
The candidate record is explicitly version 3; the peer aggregate is version 4.
The complete Welcome transcript, accepted package, peer source record and old
pending operation are retained. Old exchange entry points reject these formats.
The exchange validator is reused without changing its validation rules; its
shared helpers are exported for the new explicitly selected store.

One-shot worker result `peer_verified` is true only after protected local
commit of actual authenticated MLS decryption and frame comparison. The peer
may have verified the candidate before the server accepts its reply; the
candidate may still need to finalize its receive transition. Neither local
status alone grants server admission or proves that the other browser finished
its final transaction. The server cannot decrypt these records: its terminal
`confirmations-recorded-inactive` phase is an opaque transcript, not proof of
private possession. A later activation contract must explicitly account for
those distinct local/server states, current policy, and revocation.

`/v1/mls/successors/{intent}/confirmation` GET/POST requires the original
completed handshake and current accepted successor context. It retains two
ordered immutable slots, `candidate_proof` then `peer_proof`, each with 1–4096
ciphertext bytes and the same request fields as the existing handshake. Exact
retry is 200, first commit 201, conflicting replacement/order 409. The total
canonical transcript is capped at 16 KiB. The original handshake and custody
response bytes are unchanged. Every request and each final local CAS rechecks
current authorization; this is not an atomic lease across server and browser.

Schema 8 adds a mandatory confirmation row for every reservation. A schema-7
upgrade retains an owner-only `v7-before-successor-confirmation-*.sqlite`
snapshot before the transaction. Missing or corrupt confirmation rows fail
closed without resetting the row. The old schema-7 executable refuses the
upgraded file, and can open a separately restored snapshot. Production state
and services are never migration fixtures.

Validation uses real protected browser stores in both replacement directions,
original successful worker/store bundles, separately hashed fault-injection
bundles, real server processes and pinned schema-7 migration/rollback binaries.
It checks wrong-context valid MLS messages, invalid ciphertext/reflection,
commit aborts with zero sends, duplicate tabs, lost replies, exact ciphertext
retry, restart, preserved source/pending/legacy bytes, and private ratchet
continuity after confirmation. Lock, expiry and revocation retain committed
state. Full native activation, lifecycle and product/human/mobile/file acceptance
remain separate work before a Yukson cutover.
