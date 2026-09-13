# Synthetic saved-package Welcome/ack screen

Profile11 and the separate `synthetic_welcome` build require explicit
`--synthetic-welcome-ui`, signed synthetic auth state and loopback binding.
Its closed 31-asset graph includes the unchanged preceding custody screen and
original protected workers. `/welcome-ceremony/` adds an explicit exchange
action; users select identity, role, existing vault, request and independently
obtained request digest, then provide fresh credentials and consent each time.
No fields, action or credentials are carried across pages automatically.

The combined manifest needs more than 8 KiB, so only profile11 has a 12 KiB
manifest ceiling. All older profiles keep their 8 KiB limit and identical pins.
The 2 MiB per-file and 4 MiB whole-bundle limits remain unchanged. Default
binaries exclude this graph, and arbitrary files/directories are never served.

The original exchange worker reopens create=false and advances candidate v1 to
v2 or peer v2 to v3. It authenticates the saved provider and accepted reservation,
uses the exact saved KeyPackage, and seals each provider transition together
with its outgoing request before POST. It sends at most one immutable slot per
explicit invocation. Reconciliation may POST the exact saved request and is
not read-only. Lost replies cannot justify generating another package or group.
Old preparation/declaration entry points reject later formats; users reopen
exchange state here. No original validator or protected store is modified.

The page validates the public result's exact keys, role, revision, phase and
group shape. It distinguishes saved-but-not-yet-confirmed requests, waiting for
the other participant, and a complete inactive transcript. The candidate's
joined private state is committed before its empty ack; the peer's observation
of that ack does not prove the candidate's durable private possession. Neither
result means paired cryptographic confirmation, device admission or activation.
Generation checks, worker retirement, bounded time/memory, lock/broadcast/hide
and fresh credentials follow the preceding caller. Uncertain outcomes stay
unknown; the warning lasts for the page lifetime, not across browser restart.

Actual own-server proof first prepares and declares through the preceding DOM,
then drives exchange through this DOM in both actor assignments. Explicit old
native-pair, candidate creation and synthetic administrator fixtures remain.
Normal protocol writes use compiled original workers/stores. Separate fixtures
inject aborts and inspect authenticated records using disposable library
transitions; their hashes are distinct from the actual 31-asset graph. The
proof retains the full old source/provider/pending, original candidate package
and legacy ciphertext, including failures, concurrent callers and restarts.
Real expiry and unexpired peer revocation are separate scenarios. Fake Worker
caller tests are separate from actual private-custody and cryptographic proof.

Human creation/acceptance/recovery, subsequent paired cryptographic confirmation
UI, global directory/device enrollment, files/mobile and operational acceptance
remain. Synthetic data only; no production traffic or Matrix cutover.
