# Synthetic candidate preparation page

An explicit `synthetic_candidate` build plus `--synthetic-candidate-ui` serves
`/candidate-preparation/` and fifteen separately pinned assets. The signed
synthetic auth-state selection and loopback restriction remain mandatory. The
ordinary binary excludes the payload. All prior manifest bytes remain unchanged.

The page runs the original one-shot candidate worker and original CandidateStore.
Users select an expected Alice/Bob identity, an explicit candidate-only database
name, and create/reopen/bind. Creation releases the public key and exact package
only after encrypted commit. Reopen and bind always use create=false; missing,
corrupt, already-bound generic proposals and incompatible later store versions
fail closed while retaining state. This is the initial candidate format, not a
reader/migration for candidatev2-v7 or a lifecycle status page.

Bind imports exactly one bounded (32 KiB) candidate public scope using the prior
handoff schema. The selected identity and database must match. All reservation
fields are displayed. Users separately enter the SHA-256 of UTF-8 JSON of the
reservation with recursively sorted object keys and no insignificant whitespace.
This digest covers every field; key fingerprint consistency is checked locally.
Fresh consent and credentials are required for every operation. The page never
sets identity or trust from the file, and the unchanged worker independently
checks current signed reservation, exact saved key/package and protected state.
The entered digest/consent records a requested comparison, not evidence that an
actual human out-of-band ceremony happened. Policy installation remains an
explicit external synthetic administrator step, absent from this page.

No secret root, signer/provider state or native transport API is exposed. The
public download contains only the strictly validated committed public result,
identity and database locator. The caller clears passwords after clone and on
failure, timeout, lock, broadcast lock, hide or navigation; it retires the worker
and suppresses late responses. Only validated result hashes may enable export.
Successful local binding does not imply server custody declaration, membership,
Welcome exchange, global enrollment or message admission. This page makes no POST.

Before each worker operation the caller writes the fixed number `1` under
an identity/database-specific key in a separate public IndexedDB attempts store
using a strict-durability transaction. It never clears this public
marker: a previously attempted name cannot use create again. The public store is bounded to 128 names; missing/malformed schema or storage failure
blocks worker launch. A marker is not proof of custody and cannot repair a lost
or rolled-back encrypted database; reopen can still fail. Concurrent attempts
remain serialized and rejected by the unchanged protected store locks/CAS.
The marker may conservatively freeze an unused name after pre-commit failure.
A deliberate new name is a different proposal, never a recovery operation.
The alert for interrupted work persists for the page lifetime; after restart,
explicitly selecting the same scope shows its permanent attempt marker.

The paired DOM proof starts with an actual old encrypted pair, supplied by the
existing separate fixture, and prepares a new candidate through this page in each
actor role. Normal pages/workers/packages are byte-checked against the own Go
server and manifest. Local abort uses a separately recorded instrumented store;
a lost reply suppresses an actual original worker response after commit. Public
result injection is not used for custody proof. The independent fake-Worker
protocol suite is labeled separately. Expiry is waited in real time. Revoked
peer tombstone retention is checked after expiry; it does not independently
attribute that final rejection to revocation alone. Existing worker/server
revocation suites remain required.

Generated accounts and synthetic passwords only. Full peer preparation and human
recovery ceremony, global device enrollment, files, mobile and operational
acceptance remain before any Yukson cutover. Live Matrix is untouched.
