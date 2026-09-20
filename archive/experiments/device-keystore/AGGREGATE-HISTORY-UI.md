# Explicit two-conversation historical viewer — synthetic UI

This separate `/aggregate-history/` page joins the qualified complete aggregate
reader/export workers to a minimal historical DOM view. It is served by the
loopback generated-assertion test fixture, not compiled into the Go executable.
The actual signed native API admits the current actor. No human accounts,
passwords, archives, actual Cloudflare settings or production services are used.
The single-room history UI, profile5 and retained profile3, existing9/15/14 asset
bundles, old prepared files and browser databases are unchanged.

## Independent identity and coherent read-only history

The user supplies independently accepted `database`, `identity`, `primary_room`,
both ordered `rooms` (room/group/pins), and the immutable `fork` intent. The input
is bounded to4KiB UTF8 with an explicit acceptance checkbox. This generated-data
JSON is a development input, not a human device ceremony. It is never filled
from archive metadata or a directory. Both bound contexts with different group
IDs are required; a partial/single-room aggregate denies. No reset, repin,
missing-key generation, sender restoration or active state import is available.

Existing age0.3.1 default scrypt18 and sodium secretstream FINAL authenticate the
complete aggregate. The full native validators match both providers, the same
actual enrolled signer, pins, groups, receipts, cursors and fork intent before
returning either room. The page then constructs both room sections off-DOM and
publishes only a complete validated result. Each room has at most32 accepted
cached messages; pending frames are never delivered history. Room labels and
text are inert nodes; files are explicit8KiB maximum generic binary downloads.
Duplicate checks use sender device plus message ID, matching the native log;
different devices may legitimately use the same message ID.
No live composer, task/AI execution, enrollment, resending, native transport or
IDB import/write path is exposed by the reader UI.

The export button authenticates an existing coherent encrypted aggregate via the
qualified readonly exporter. No missing database is created or repaired. Its
ciphertext and exact pending bytes remain unchanged. The resulting6MiB maximum
archive contains a protected full provider; it is not a history-only key backup,
forward-secret backup or rollback witness. Old archives can show an earlier
coherent history but cannot resume an active sender. Possessed archive/password
pairs can read past history offline despite later server/device revocation.

## Present UI admission and lifecycle

Before and after opening/exporting, before downloads and every15seconds while
visible, the page checks signed `/v1/session` with its expected actor. Body and
header must agree; no fixture bearer, role/email fallback or raw JWT in page
JavaScript/storage/URLs. Bounded4KiB responses/five-second requests, no-store,
redirect denial and generation/abort checks remain. This is current account UI
admission, not deletion of previously possessed archives or current room/device
execution authority. Device revocation does not corrupt past history. Current
account removal denies UI access on the next admission; it is not instantaneous.

Generated passwords32..128characters are cleared from input at operation start,
then local references are released after the one-shot caller takes its bounded
owned clone. File.size must be1..6MiB before arrayBuffer; view and full backing
are bounded before cloning. Password/provider/root are never returned by a worker
or persisted by the page. Immutable strings and caller/browser-owned copies
cannot be physically erased. Existing shared `family-native-vault-kdf`, default
work factor and caller10sboot/30srequest/worker15s deadlines are unchanged.

Lock/hide/pagehide/identity/archive/expected changes and cooperating sibling
`family-aggregate-ui-lock-v1` notifications abort requests, retire workers and
clear all history, download URLs, buffers and transient inputs. A five-minute
view expires without auto-reopen. Late file, KDF, session and worker callbacks
cannot repopulate a newer view. At most one download admission and two live Blob
URLs are allowed, with one-second expiry and complete retirement cleanup.
Forms stay disabled after success until explicit lock; no automatic password
reuse or acceptance survives reload. No browser storage is used by this page.

## Runnable isolated proof and native packaging

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --aggregate-history-ui \
  --bundle artifacts/identity-context-build-smmbyhm5/candidate \
  --binary artifacts/family-dev --policy-binary artifacts/family-policy
```

Two generated native clients establish two real OpenMLS groups and exchange text,
8KiB files and epoch control traffic through the API. The separate DOM flow
exports both signed actors, SIGKILLs the source browser and opens a fresh reader.
It checks room labels/text/files, both pending exclusions, exact source ciphertext,
zero native sends/live writes, wrong password/pins/target group/fork/tamper,
truncation/size/UTF8 admission, signed actor change and durable account revocation,
lock/sibling/hide/late completion/Blob cleanup, empty reader IDB/storage and390px
layout including a maximum-length room label. Native preparation uses the existing separately hashed test instrumentation;
reader/UI/workers retain their original bytes; six actual fixture response hashes
match their source pins. No forged worker is served by this
UI proof. The separate unchanged full-library aggregate history suite retains
its authenticated invalid-state fixtures and26 checks. A viewport check is not
mobile resource or human recovery acceptance.

The separate [native profile 6](../../server/AGGREGATE-HISTORY-UI.md) now
packages the original viewer through Go with the optional identity-context WASM.
This document and its original evidence describe the isolated fixture proof;
the native proof uses a forwarding-only assertion proxy and its own receipts.
Old profiles/output and cryptographic protocols remain unchanged. OpenMLS
8 direct/151 transitive WASM crates and age/sodium 2 direct/8 transitive runtime
instances remain. Keep 128 MiB combined WASM/5 GiB added disk and separate
256 MiB JS scrypt scratch budgets; memory-heavy tests run serially.
Human lifecycle/recovery/mobile/CF/backup/capacity/fleet acceptance and Yukson
cutover remain open.

## Review evidence

[aggregate-history-ui-evidence.json](aggregate-history-ui-evidence.json) records
28 actual browser checks and six matching original fixture response hashes.
Independent review reproduced two defects before the final runtime: a medium
error treating message IDs as globally unique across senders, and a low overflow
of a maximum-length room label. Native two-sender same-ID messages now both
render, and a64-character label fits390px. Fifteen separate minimal-DOM/admission
probes exercise invalid second-room results, inert text and stale callbacks;
these are UI boundary tests, distinct from the actual cryptographic archive run.
The independent original worker/archive suite also passes all26 checks; it
remains separate and unchanged. Both reported findings are fixed, with no
remaining reproduced issue in the bounded synthetic review. Python137
passes under both022/077umasks. The Go/API binaries are clean builds; Go, Rust,
archive/custody source and old asset manifests did not change in this unit.
