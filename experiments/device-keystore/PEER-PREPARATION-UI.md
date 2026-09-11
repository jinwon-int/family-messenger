# Synthetic intact-peer preparation

An explicit `synthetic_peer` build and `--synthetic-peer-ui` select profile9:
`/peer-preparation/` plus fourteen separately pinned assets. The ordinary binary
excludes the payload. All previous manifests and original protected stores and
workers remain unchanged. Signed synthetic authentication, loopback binding,
strict same-origin routes and security headers remain required.

The page accepts one bounded public peer scope file using the previous handoff
schema. It requires an explicitly selected identity and existing aggregate
vault database, action, fresh generated password and consent. The user must
separately enter the SHA-256 of the reservation serialized as UTF-8 JSON with
recursively sorted keys and no insignificant whitespace. Every field is covered;
the candidate public fingerprint is checked locally. This is a requested
comparison, not proof that a real human independently verified the ceremony.
Public files never install identity, credentials, policy or private custody.

The unchanged SuccessorPeerStore and one-shot successor-peer-worker independently
fetch the current signed accepted reservation before unlocking and again before
commit. They operate with create=false in the original encrypted aggregate.
A valid v1 source is preserved in full while the actual library copies its intact
signer to a restricted empty provider in a v2 target. A matching v2 is reconciled
without another encrypted write. Missing, corrupt, different, expired, revoked
or later incompatible state is retained and rejected. No root or key generation,
old validator change, candidate activation or network POST is added.

The single selected action is preparation **or reconciliation of that preparation**;
it is not a read-only status action. Fresh credentials and consent are needed on
every invocation. Only an exact validated committed public receipt enables
export. Providers, private keys and passwords never enter that receipt. The page
retires the worker and clears credentials/output on errors, timeout, lock,
broadcast lock, hide or navigation. Unknown outcomes stay uncertain until the
user explicitly checks the same scope. The uncertainty alert lasts for the page
lifetime; after restart no scope, action or credential is selected automatically.
There is no durable acknowledgment/history UI in this unit.

Actual browser evidence starts from an encrypted native pair with text, an 8KiB
file and pending rekey, plus a real saved candidate package supplied by explicit
separate fixtures. The synthetic administrator installs accepted policy and
reservation outside this page. Normal page/worker bytes come from the compiled
Go server. An explicitly separate abort-only fixture checks local commit failure;
reply loss drops a real committed original-worker response. A separate private
inspection worker only authenticates existing v2, refuses any transition, and
returns the full old source-record digest. It never exports providers or writes
a new state. Its hashes are recorded separately from the native graph.

Both Alice and Bob run as intact peer, including concurrency and browser/server
restart. Alice waits real intent expiry; Bob proves current peer revocation while
the original intent is still unexpired. These are distinct attributed cases.
The fake Worker protocol suite is separate from actual custody evidence.

This prepares original peer v2 only. It does not reopen later peer v3-v8 formats,
connect lifecycle declarations, implement full human acceptance/recovery or
global device enrollment. Files, mobile and operational acceptance remain before
Yukson cutover. Generated accounts/policy only; live Matrix is untouched.
