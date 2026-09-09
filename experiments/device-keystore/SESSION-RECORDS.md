# Authenticated session records — design for isolated qualification

Status: proposed generated-data experiment, not a live keystore or human activation.
Native OpenMLS provider state, transport, policy and all existing profiles remain
unchanged. This unit qualifies library invocation and custody; active-state CAS,
full provider binding, mobile recovery and external rollback witness follow later.

## Chosen boundary to test

Use pinned `age-encryption` 0.3.1 for one standard password-encrypted root capsule
and candidate `libsodium-wrappers` / `libsodium` 0.8.4 for authenticated records.
This is application composition of two maintained high-level container APIs, not
a new cipher, KDF, nonce scheme or manual file-key wrapping algorithm. It needs
independent design and implementation review. Do not describe it as an audited
keystore simply because its components have prior security work.

Inside a dedicated worker, use `crypto_secretstream_xchacha20poly1305_keygen()`
for a 32-byte root record key, and library randomness for a nonsecret vault ID.
Store the version, vault ID and key only as a bounded application payload inside
an ordinary age password file at unchanged default scrypt logN18. The page sees
only the encrypted capsule and the public vault ID. On reopen, the PR37 library
parser policy admits only one default-work password recipient before full age
file decryption. Parse/validate the complete capsule only after authentication;
compare its vault ID to the explicitly expected fixture ID. No raw key or decoded
capsule leaves the worker. This expected fixture ID is not a human trust ceremony.

Keep the root key in the unlocked worker for bounded operations. For each full
record, start a **new** library secretstream with `init_push(key)`, include fixed
canonical application metadata `["family-session-record",1,vaultID,recordID,revision]`
as library additional authenticated data, and push exactly one bounded payload
with `TAG_FINAL`. Store/return exactly the library header and ciphertext alongside
bounded public metadata. The library owns header/nonce generation and the complete
authentication tag. No persistent stream is resumed after a crash, no counter is
restored, and no custom nonce/tag/key derivation is used.

To read, obtain expected metadata from the caller (future integration must bind it
to trusted state), validate bounds, and call library `init_pull`/`pull` with the
root key, header, ciphertext and the same canonical metadata. Require successful
pull, `TAG_FINAL`, the exact bounded plaintext length/content for this fixture,
and no extra chunks/bytes before returning only a boolean to the test page.
Any error retires the session, not just that one mutable stream. A valid partial
stream tagged MESSAGE must not be accepted as a whole saved record. No plaintext
or key is returned to page diagnostics.

A symmetric record key is required for state authenticity. Public-recipient
file encryption alone is insufficient because anyone who knows the recipient can
create new valid state. This design does not use recipient encryption for records.
Capsule/record replacement with an older **complete valid** pair remains possible:
authentication is not a monotonic witness. A successful reopen is not permission
to replay old ratchets/outbox as a live device.

## Lifecycle and limits to prove

One worker per page, bounded 32 commands, 8 KiB dummy record, bounded capsule and
metadata. No network, real family data or actual MLS state. Commands require the
right locked/open phase and one in-flight operation. Page-owned generation guards
and worker termination handle lock/hidden/restart/error; a message cannot interrupt
synchronous KDF. Cooperative tab lock broadcasts are not protection from malicious
same-origin code or an origin-wide resource semaphore. Same-origin/OS compromise
can access secrets while unlocked. Wiping buffers where the API permits is best
effort, not a JavaScript/OS physical-zeroization guarantee.

Initial capsule creation and unlock may use 256 MiB KDF scratch. Measure record
latency without another KDF, library startup and WASM memory independently; keep
128 MiB WASM and 5 GiB additional disk bounds. No silent reduced password factor,
large install or mixed-up browser RSS/worker measurement. CSP must remain narrow:
self workers/scripts and WASM compilation only if required, no unsafe-eval, broad
CORS or external CDN. Confirm actual WASM use, no quiet weaker fallback.

Future persistence must atomically retain the whole provider, independently
accepted pins, exact outbox, receive cursor and control state as one authenticated
candidate. All asynchronous crypto happens outside IDB, followed by strict exact
prior-state/revision CAS. Commit before any plaintext/ciphertext release; abort
and stale candidates retire without rollback, automatic reset or re-encryption.
This feasibility unit has no implementation of that transaction or migration.
Additional/replacement devices remain denied, owner execution is separate, and
family rooms never implicitly include agents.

## Evidence sources and qualification still required

- Official secretstream documentation describes high-level authenticated streams,
  additional data, library nonce management and final-tag handling:
  https://doc.libsodium.org/secret-key_cryptography/secretstream
- libsodium.js 0.8.4 release (2026-04-19), npm gitHead
  `2830fcf2ce8cefd3fdc7e1efc9fc1cee1d2d95b7`; public README demonstrates these APIs:
  https://github.com/jedisct1/libsodium.js/tree/2830fcf2ce8cefd3fdc7e1efc9fc1cee1d2d95b7
- Official libsodium introduction links historical audit work and supports JS/WASM:
  https://doc.libsodium.org/

Resolve exact package lock/SRI/license notices and shipped core version, check
security notices, bundle/browser/CSP behavior and measured resource cost before
claiming a runnable candidate. Historical core audit is not an audit of this JS
wrapper, newer core release, password library or application composition. Retain
concrete failure evidence and narrow the result if a safe supported API is absent.
