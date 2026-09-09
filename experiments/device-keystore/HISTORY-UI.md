# Explicit historical viewer — synthetic UI

`history.html`, `history.css` and `history-ui.js` join the previously qualified
read-only archive workers to a separate DOM entry at `/history/`. This unit is
served by the loopback generated-assertion fixture, **not yet compiled into Go**.
No human accounts/passwords/archives, Cloudflare settings or production services
are used. Original chat pages, their prepared nine/fifteen-file bundles, draft
namespaces and private browser profiles are unchanged.

## What opening a file means

The user supplies the original `database`, `identity`, `room`, `group_id` and
two independently accepted public `pins` as a bounded 4 KiB JSON object, plus an
explicit acceptance checkbox. This is a developer-facing generated-data input,
not the eventual human device ceremony. It is neither filled from an archive nor
downloaded from the server directory. The existing worker validates the complete
schema, real provider key/group and normalized independent pins. No automatic
repinning, missing-key regeneration, profile import or reset is available.

This UI verifies `/v1/session` before starting and after completing worker work,
and before each download. It requires signed mode and the exact independently
expected actor in both the response body and `X-Family-Actor` header. It sends the
same expected-actor header; a changed signed principal is rejected by the actual
native API. Responses are limited to 4 KiB/five seconds, redirects denied, with
no-store and no token/email/header-role fallback. No raw assertion enters page
JavaScript, storage or URLs. A five-minute view lifetime and sequential 15-second
session checks clear the view on failure. This does not claim instantaneous
revocation or authorization for a subsequent live room message.

Possession of an archive and its password permits historical reading through the
offline worker even after current server access is revoked. The extra signed UI
admission is a present account check, **not cryptographic deletion of previously
possessed history**. It grants neither current room membership, device enrollment
nor owner/fleet execution authority. Historical output cannot execute a task,
create a sender or resume the encrypted outbox. There is no native log endpoint,
transport dispatcher, IDB import or write call in this UI/reader path.

## Inputs, output and lifecycle

Generated password input remains 32–128 characters and is cleared immediately
when an operation starts. The UI drops its file reference after reading, and its
argument reference after handing ownership to the one-shot caller. That caller
drops the argument after posting or retirement. Immutable JavaScript strings,
browser internals and caller-owned copies cannot be physically erased by this
code. No password, provider, root or decrypted state is saved in page storage.

`File.size` must be 1..6 MiB before `arrayBuffer()`. The existing caller also bounds
both the typed-array view and its complete backing allocation before cloning.
Async file reads, session requests and worker replies are generation checked.
The unchanged reader authenticates the entire age capsule and secretstream FINAL
record, checks the complete frozen native-v4 state and only then returns committed
history. A pending frame is not a delivered message.

Only inert text nodes and explicit application/octet-stream downloads are rendered.
There are at most 32 messages of at most 8 KiB each. No archive filename becomes an
output path; generated archive/file names are fixed or bounded validated message
IDs. HTML/SVG/media execution and automatic downloads are absent. At most one
download admission runs at a time; Blob URLs expire after one second and are all
revoked on retirement. The original archive remains encrypted when downloaded.

Lock, hidden view, pagehide, signed failure or a cooperating sibling's existing
`family-vault-ui-lock-v1` notification retires the worker, aborts session requests,
clears rendered history/encrypted download buffers/Blob URLs and transient inputs.
Old callbacks and timers cannot publish into a newer operation. Forms remain
disabled after success until explicit lock, so changing identity/room/archive
requires a new independently acknowledged operation. There is no automatic
password reuse or reopening after reload.

The export button invokes only the existing read-only exporter. It authenticates
a coherent existing committed snapshot before offering its encrypted download.
Missing or invalid profiles deny without creating/upgrading/importing a database.
Export can be historical if a separate live client subsequently advances. The
archive still contains a protected full provider and outbox; it is not a
history-only key format, forward-secret backup or anti-rollback witness.

## Reproduce and next packaging boundary

Use the unchanged pinned history workers and OpenMLS bundle built as described
in [HISTORY-RECOVERY.md](HISTORY-RECOVERY.md), then:

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --vault-ui --history-ui \
  --bundle artifacts/mls-remapped-pkg --binary artifacts/family-dev-vault-plain \
  --policy-binary artifacts/family-policy-mls-fixed
```

This mode preserves the existing vault UI and library recovery checks and adds
actual DOM export/reader controls. Two original browsers create encrypted text
and opaque files, leave a never-accepted pending frame, export unchanged bytes,
and SIGKILL the owned original browser. A separate reader context checks text/file
integrity, no pending output, password/pin/room/tamper denial, signed actor change,
denied download, bounded file admission, lock/late completion, sibling cleanup,
reload, absence of live native sends/IDB imports and 390px layout. Public fixture
assertions are injected only by a local test proxy. This is not real CF login or
mobile acceptance. The fixture records source/served asset hashes.

No dependency, crypto primitive, KDF parameter, native state schema or product
runtime has changed. Existing age/sodium (2 direct/8 transitive runtime instances),
OpenMLS (8 direct/151 transitive WASM crates), licenses, separate 256 MiB JS scrypt
scratch and 128 MiB combined WASM/5 GiB added-disk limits remain applicable.

The next bundle must add a new immutable Go asset profile/output/version and an
explicit signed synthetic selection, preserving the existing nine/fifteen-file
profiles. Pin all three UI files, the caller and both workers plus existing WASM
and license notices; remeasure manifest/file/total limits. Actual Go-served-byte
proof must use a forwarding-only assertion fixture. Do not use this experimental
static proxy as a production server or silently replace prior prepared output.
Human replacement/recovery ceremony, mobile, real CF, server backup/restore and
production actor/group/history capacity remain prerequisites for Yukson cutover.
