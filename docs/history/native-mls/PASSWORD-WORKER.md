# Worker-only password archive feasibility

> **이력 문서** — [#177](https://github.com/jinwon-int/family-messenger/issues/177) M2b-3c(2026-09-26)에서 설명 대상 코드가 삭제되어 `archive/experiments/device-keystore/PASSWORD-WORKER.md`에서 옮겨 왔다. 본문의 경로·명령·증거 해시는 삭제 전 기준이며, 코드는 태그 [`archive-frozen-20260917`](https://github.com/jinwon-int/family-messenger/tree/archive-frozen-20260917/archive)과 삭제 커밋의 부모에서 볼 수 있다.

Status: **isolated generated-data proof, not a live keystore selection**. The
existing synthetic messenger still stores its MLS provider snapshots unprotected
at rest. This experiment does not load those snapshots or alter any native
profile, actor policy, CF setting, deployment or recovery backup.

## Result and decision

The pinned `age-encryption` 0.3.1 public password APIs work inside a dedicated
Chromium module worker. File encryption and complete authenticated decryption
stay inside that worker; only encrypted bytes, success/denial and timing cross
back to the page. The dummy plaintext is 2 KiB of public constant bytes, not an
MLS signer/provider or a human key. The test generates a random password in
Python memory and passes it transiently through the page. No password is written
to IndexedDB, URLs, logs or verification receipts.

This removes the Window-only WebAuthn invocation obstacle for **password archives**.
It does not supply a live unlock session: every operation uses a fresh worker and
pays the default scrypt cost. The first measured browser run took 2,201 ms to
create and 2,024 ms to open a 2 KiB container. Default logN=18 uses roughly 256 MiB
of KDF scratch. The observed aggregate descendant RSS peak was 1,004,836 KiB;
that includes Chromium processes and Playwright's Node driver, counts shared pages
repeatedly, and is **not worker heap, PSS, or a physical-phone measurement**.
Measurements vary with the host and garbage collection. No WASM was added; the
existing 128 MiB WASM budget must not be used to hide this separate JS/KDF cost.

Do not select this per-file password path for each MLS state transaction. Even
small payloads pay the KDF overhead. A once-per-unlock archive plus a separately
qualified standard recipient/session mechanism needs its own design and proof;
we have not composed a custom KDF/cipher/key-wrap or implemented such a vault.
Mobile memory/background acceptance remains open. The page permits one candidate
at a time but **does not enforce an origin-wide KDF semaphore**; the test serializes
memory-heavy operations and proves cooperative cross-tab lock cancellation, not
arbitrary many-tab resource isolation. These limitations block human activation,
not further reviewed development.

## Resource admission through library contracts

The upstream password decryptor accepts work factors through logN=20 (roughly
1 GiB scratch). A byte-size limit or operation timer alone cannot bound that
synchronous allocation. `password-worker.js` therefore first snapshots at most
8 KiB and asks the **same pinned library parser** to inspect the container:

- The inspection `Decrypter` has exactly one public `Identity` callback and no
  password identity. It never unwraps or returns a file key.
- Its parsed stanza policy requires exactly one `scrypt` stanza, exactly three
  arguments, the exact string `18`, and a 32-byte wrapped-key body. A private
  sentinel thrown by that callback is the only successful inspection result;
  other parse errors and unexpected success deny the operation.
- A separate `Decrypter` receives the same private byte snapshot and the password
  only after inspection. The library performs salt validation, header MAC and
  complete payload authentication. Inspection is not a signature/integrity check.

There is no independent age parser, alternate cipher or custom identity unwrap.
This relies on the pinned public `Identity.unwrapFileKey` callback being reached
only after library stanza parsing and propagating its exception. Upgrading the
library requires revalidating that behavior; public `decryptHeader` is not used
to expose a file key. Tests deny 20/19/17/018/999/+18/Unicode work strings,
multiple stanzas, other recipient types, malformed headers and oversized input
before entering the password decryptor. The `kdf-start` signal marks the call
boundary immediately before the password library operation, not a CPU profiler.
Rejected resource headers never reach that boundary. Correct-factor tampering
and wrong passwords do reach it and must fail complete authentication.

See pinned upstream [public API](https://github.com/FiloSottile/typage/blob/38b8b10cb22409de0eaa8a617a01f16dc2e3f9f4/lib/index.ts)
and [password recipients](https://github.com/FiloSottile/typage/blob/38b8b10cb22409de0eaa8a617a01f16dc2e3f9f4/lib/recipients.ts).
No new upstream audit or stable WebAuthn guarantee is implied.

## Lifecycle and persistence scope

Every worker is one-shot; malformed input/failure retires it. The page holds a
single active generation, bounds operation duration to 20 seconds and terminates
the worker on lock, page hide, visibility loss or a cooperating tab's lock
broadcast. Generation checks discard stale replies. A message sent to a busy
synchronous worker is not reliable cancellation; ownership must terminate it.
Termination does not promise physical JavaScript/string/memory zeroization or
protection from malicious same-origin code, a compromised OS, extensions or
DevTools. No executable code isolation from the origin is claimed.

A new disposable `family-password-container-synthetic-v1` IndexedDB fixture stores
one immutable `{version:1,ciphertext}` archive with strict transaction completion.
Read/check/add occurs in one transaction; later replacement is refused, preserving
the original. It is not an active-state CAS implementation, migration, ratchet
backup or recovery UX. No async crypto/network waits occur in that transaction.
The proof closes and restarts the actual persistent Chromium context at the same
loopback origin and verifies identical ciphertext plus successful unlock; this
is a clean browser restart, not a browser SIGKILL/power-loss acceptance claim.
It also terminates a worker during KDF and proves denied completion and retained
archive, including a second tab's lock. A complete older valid ciphertext still
opens: age does not supply an external monotonic rollback witness.

Additional/replacement devices remain denied. Human recovery must distinguish
read-only historical archives from new device enrollment and continuing a group;
never restore old ratchets/outbox as an active sender. CF account admission,
independently accepted device pins and owner execution authority remain separate.

## Reproduce and inventory

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix experiments/device-keystore
node experiments/device-keystore/node_modules/esbuild/bin/esbuild \
  experiments/device-keystore/password-worker.js --bundle --format=esm \
  --platform=browser --target=es2023 --minify \
  --outfile=experiments/device-keystore/bundle/password-worker.js
.venv/bin/python tests/password_worker_smoke.py --synthetic-only
```

The exact three-asset loopback test server supplies a restrictive self-only
script/worker CSP, no unsafe-eval/CORS, exact Host/Origin/path checks, nosniff and
no-store. Fixed files are bounded, owner/mode/single-link checked and opened without
following symlinks, with nonblocking open so a FIFO cannot hang before the regular-file check; the bundled worker SHA must match `password-inventory.json`.
Owned temporary artifacts/profiles are retained privately; there is no archive
pruning or deletion of unknown user files. Do not upload the retained browser
profile as CI evidence; the workflow uploads only body-free `verification.json`.

No packages were added: reuse the PR36 lockfile and all eight runtime-instance
notices in `THIRD-PARTY-NOTICES.txt` (one direct + seven transitive runtime package
instances, two installed build instances). The additional worker bundle is
143,708 bytes / 52,521 gzip bytes, SHA in `password-inventory.json`. Node/esbuild
are build/test tools, not messenger runtime services. Playwright/Chromium are
unchanged. The bundle still includes code from the dependency graph; no claim of
removing the resolved PQ dependencies is made. This is not a full-stack security
audit. Browser memory and lock limitations must accompany the roundtrip result.

Next qualify a maintained high-level authenticated record/session API for per-record
protection after a bounded worker-only unlock, without exporting private material
or assembling custom wrapping. Public-recipient encryption alone does not authenticate
state authorship; knowing a recipient permits creating another valid ciphertext.
A recipient roundtrip cannot substitute for that separate requirement. If suitable, stage full provider/pins/exact outbox/
cursor together outside IDB and atomically compare the prior encrypted record
before commit. Lost reply must reconcile exact bytes; stale candidates retire,
never roll back/re-encrypt. An archive-only roundtrip must not substitute for that
review or mobile, backup/restore, enrollment and Yukson acceptance.
