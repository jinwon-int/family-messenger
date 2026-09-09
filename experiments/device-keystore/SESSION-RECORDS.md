# Authenticated session records — design for isolated qualification

Status: implemented generated-data library experiment, not a live keystore or human activation.
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

The lock pins wrapper and libsodium0.8.4, matching npm gitHead above. Shipped core
reports1.0.22. The npm advisory snapshot reported zero vulnerabilities and the
repository public advisory listing was empty; neither proves absence of defects.
The [PIA audit](https://www.privateinternetaccess.com/blog/libsodium-audit-results/)
covered1.0.12/1.0.13 and **predates secretstream**, introduced1.0.14. Do not claim
it audited this API, JS wrapper, core1.0.22, password library or our composition.

## Implementation, limitations and reproduction

`session-worker.js` holds the root capsule plaintext and key only in a dedicated
worker. Every command has an exact schema. The synthetic payload is fixed2KiB,
not supplied human text or MLS state. Record IDs are bounded ASCII and revisions
positive safe integers. Ciphertext is exactly2065bytes and the header24bytes;
there is one and only one chunk. Unknown fields, invalid lengths, non-FINAL
authenticated tags, wrong expectations and all errors retire the entire session.
`fixture_tag` creates library-authenticated MESSAGE/PUSH/REKEY examples solely
for negative tests; this opcode is never part of the native product.

`create` and `unlock` require a locked worker. `seal` and `read` require open state.
`status` is metadata-only. Every attempted command counts, including status;
command32 returns its command result with `retired:true` and immediately
wipes the reachable root buffer and terminates. The page recognizes this retirement;
further requests require explicit start/unlock. No durable transaction is implied.
Numeric secretstream state handles stay library-owned: the standard wrapper has
no high-level destruction API here, so no private `_free` or state-memory edits
are used. The command cap and worker termination bound their lifetime/allocation.

WASM instantiation is observed before dynamic wrapper import in this test worker,
and an exported WebAssembly.Memory must match the exact heap the wrapper uses.
The observer restores the original instantiate function after initialization.
`sodium.ready()` alone would not prove WASM use. Startup fails if no matching
WASM instance exists or heap exceeds128MiB. No asm.js fallback acceptance is claimed.
The library manages stream state and headers; the observer does not modify crypto
bytes/behavior. CSP adds only `wasm-unsafe-eval` to self scripts, not unsafe-eval.

Fresh record streams/finality do **not** provide forward secrecy from retained
root-key compromise: anyone with the root can decrypt all saved records made with
it. No cross-record replay or ordering guarantee is claimed. Whole old capsule/
record pairs still authenticate. This unit does not initialize native profiles,
write an IDB vault, implement CAS/outbox handling or qualify SIGKILL/power-loss.
The restart test closes Chromium and opens a fresh process, then supplies the exact
prior capsule/record bytes retained only in the test coordinator. This proves
library reopen, not browser persistence, a backup strategy or human recovery.

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix experiments/device-keystore
node experiments/device-keystore/node_modules/esbuild/bin/esbuild \
  experiments/device-keystore/session-worker.js --bundle --format=esm \
  --platform=browser --target=es2023 --minify \
  --outfile=experiments/device-keystore/bundle/session-worker.js
.venv/bin/python tests/session_record_smoke.py --synthetic-only
```

The exact three-asset loopback-only server uses the PR37 nonblocking safe-file
reader, bounded pinned worker SHA, self-only script/worker CSP, no-store/nosniff,
exact Host/Origin/path checks and generated ephemeral browser contexts. No CDN,
external service, actual CF assertion, family data or credentials are used.
Only body-free verification receipts are uploaded, never root/capsule/password.
Two packages (one direct wrapper, one transitive library) add ISC notices in
`SODIUM-NOTICES.txt`; existing age dependency notices remain. Total runtime package
instances now10 (2direct/8transitive), plus2 installed build instances; the full
all-platform lock has37 external instances. The old `inventory.json` and password
proof remain historical PR36/37 records; `session-inventory.json` records this
candidate. No product Go/Rust/native UI dependency or manifest is changed.

The candidate bundle contains embedded WASM plus JavaScript (581260bytes /205536gzip
in the recorded build); only the wrapper heap measures WASM linear memory, not
aggregate Chromium/JS/password KDF usage. The scrypt default256MiB scratch and
~2s unlock cost remain separate. The build reuses Node22.22.2/esbuild0.27.2 with
scripts disabled. Primary sources and the frozen design were independently reviewed
before code; implementation still requires adversarial/browser verification.

Next join this custody boundary to a new synthetic full-provider record namespace:
whole candidate+pins+exact outbox+cursor protection outside IDB, strict prior-state
CAS before output, cross-tab origin resource/lifecycle admission and crash/lostreply
proof. Preserve existing profiles without reinterpretation. Runtime/device trust,
recovery, actual CF, mobile and backup acceptance still precede Yukson activation.

Initial browser receipt `session-evidence.json` records13 passing groups, 4MiB
WASM heap, and measured root/record timings. This is desktop synthetic evidence,
not a real-phone benchmark or successful persistent native integration.
