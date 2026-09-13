# Paired protected custody declarations (synthetic only)

Two separate worker entries, `candidate-custody-worker.js` and
`peer-custody-worker.js`, accept the one-shot `declare` command. They reopen the
respective protected store with `create:false`. The candidate uses the original
accepted KeyPackage/provider; the peer preserves its entire old room, including
pending requests, while committing an isolated signer-only target. Only after
`CandidateStore.operate` or `SuccessorPeerStore.prepare` completes its strict
IndexedDB transaction does the worker POST a declaration. Existing workers and
protected record formats are unchanged.

The command has exactly `identity`, `database`, `password`, and `intent`.
`intent` has exactly `accepted:true` and a reservation. The reservation validator
copies every field into its canonical order; the new worker recursively freezes
this owned copy before any await. Later operations use this copy throughout.
No page-supplied declaration ID, new key generation, active-device fallback, or
pending-message replay is available through these entries.

## Stable public retry identity

There is no new persisted ID field. Instead, the worker authenticates the exact
immutable reservation in the complete sealed local record on every reopen, then
computes:

```
context_sha256 = lowercase_hex(SHA256(UTF8(JSON.stringify(normalized_context))))
declaration_id = lowercase_hex(SHA256(UTF8(JSON.stringify([
  "family-successor-custody-declaration", 1, role, reservation_id,
  context_sha256, normalized_context[role].device_id
]))))
```

The normalized context order is the existing `successor-peer-state.js`
`reservation` validator's order, matching the server's reservation context.
Names and hashes are ASCII; integers are safe JSON integers; encoding has no
whitespace or trailing newline. The independent Python browser fixture computes
the same value from the actual server reservation. The Node transport proof also
checks the versioned encoding against Node's SHA-256 implementation.

This replaces the earlier proposal to add an explicitly persisted random ID.
The derivation depends only on fields already authenticated and atomically
committed by both stores, so an unknown POST outcome cannot produce a fresh ID
on retry. It proves public retry consistency; it is **not** a secret, signature,
private-key possession proof, human fingerprint ceremony, or activation grant.
An occupied role slot with a different ID fails closed; this worker cannot
replace a prior declaration or convert a manually declared slot.

## Responses and failures

POST is followed by a fresh GET to the same reservation's custody endpoint.
Both requests use same-origin credentials, `no-store`, redirects disabled, the
exact actor/device headers, a five-second response deadline and a 4 KiB body
limit. POST is bounded to 1 KiB. A response must have the correct signed actor
header, status 200 (or 201 for POST), exact fields, matching reservation/context,
canonical unique role slots, matching devices, and this worker's exact own ID.
GET cannot lose or replace any POST-observed slot. Liveness and expiry are
checked after every fetch/body wait. Each server request independently rechecks
current admission; results describe that request's observation, not a perpetual
guarantee against subsequent revocation.

Successful output distinguishes `own_declared:true` from readiness phase
`custody-pending` or `pair-declared-inactive`. Neither phase enables traffic.
On abort, malformed response, timeout, stale authority, or revocation, the worker
returns a generic failure and closes. It retains committed local custody and
never automatically retries an uncertain POST. A new explicit invocation
reauthenticates the same committed state and uses the same declaration ID.

## Evidence and remaining boundary

`tests/native_custody_checks.py` runs two persistent Chromium profiles through
real generated OpenMLS traffic, encrypted candidate proposal creation, accepted
reservation, and both protected stores. It covers both role orders, concurrent
roles/same-role tabs, lost replies and browser/server restart, transaction aborts
with zero POST, exact package/source/pending continuity, bounded malformed
receipts, lock/deadline, expiry, current revocation and continued delivery denial.
Instrumentation exposes only generated source digests and injected failures;
original and served bundle hashes are recorded separately. Existing original
candidate/peer suites remain separate compatibility checks.

`tests/custody_transport_checks.mjs` executes the actual transport with injected
fetch/body expiry, close and abort boundaries, readiness regression, and lost
reply retry. CI reuses the exact preceding MLS job's built WASM and binaries for
a separate bounded paired proof job, avoiding a second cryptographic build.

These workers are fixture-served experimental assets. No compiled product route,
Welcome/ack using the stored candidate package, new-group creation, activation,
human recovery flow, real file/mobile acceptance, or Yukson cutover is included.
Production remains on its existing Matrix deployment.
