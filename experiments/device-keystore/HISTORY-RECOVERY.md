# Read-only native history recovery — isolated synthetic boundary

This experiment exports a coherent committed encrypted vault snapshot and reads
its **committed cached history** in a separate disposable worker. It is not an
active device restore, replacement enrollment, human recovery ceremony or Yukson
activation. Current Go assets, native worker, driver, profiles and production
services are unchanged. Use generated data/passwords only.

## Why preserve the existing container

The native vault already authenticates the full provider/pins/outbox/cursor/cache
using the pinned high-level age password capsule and libsodium secretstream APIs.
This unit transports those exact authenticated bytes; it does not introduce a new
cipher, KDF, nonce scheme or key wrapping composition. The existing qualification
and primary sources in [NATIVE-VAULT.md](NATIVE-VAULT.md),
[SESSION-RECORDS.md](SESSION-RECORDS.md) and [PASSWORD-WORKER.md](PASSWORD-WORKER.md)
remain applicable. Password work admits only the library's single scrypt18
recipient before the unchanged default password KDF. The native at-rest AAD and
capsule payload are interpreted exactly, including original database/actor/room,
vault ID, revision and actual provider public signing key.

A canonical UTF-8 JSON file has exactly `format: family-history-v1`, the original
`database`, and the eight existing outer-state fields. Capsule/header/ciphertext
are canonical base64. Maximum file size is 6 MiB, sufficient for the existing
4 MiB+17 ciphertext, 8192-byte capsule and 24-byte header with encoding overhead.
Counts, types, names, versions, fields and canonical serialization are checked
before password work. The snapshot's full encrypted provider is confidential
backup material: compromise of its password/root exposes the backed-up state and
history. Do not claim a history-only key archive, forward secrecy of backups or
hardware-backed key protection.

## Explicit capability separation

`history-export-worker.js` reads one existing version-1 database and exactly one
`device/state` value in a **readonly** transaction. It never creates/upgrades a
profile or writes/imports a state. Missing databases, unknown schema/extra keys
and incomplete creation markers deny. Reading one IDB value gives a coherent
committed snapshot; an async MAC check is outside that transaction. Native traffic
may subsequently advance the original device, so the archive's revision/cursor
is a historical point, not a promise of the latest history. Existing native
writers already limit records; IDB must deserialize a stored value before JS can
inspect its length, so this is not protection against a malicious same-origin
writer forcing an arbitrarily large browser deserialization.

The exporter authenticates and validates the snapshot with the independently
expected identity/group/pins before returning **only encrypted archive bytes**.
It does not include a password or recovery key in the returned file. A failed
validation leaves the original encrypted bytes intact. It does not silently
repair a corrupt profile or update accepted pins.

`history-worker.js` imports no native delivery dispatcher and has no IDB read or
write path. Its sole accepted operation is `read`. It checks the independent
expected database, actor, room, actual group and device pins, authenticates the
complete capsule and secretstream FINAL record, and validates the private native
version-4 record through read-only OpenMLS provider APIs. No leaf is activated as
a sender and no commit/ratchet operation is exposed. A separate versioned parser
is intentional: future live formats must be explicitly qualified rather than
silently interpreted as this archive format.

Only committed cached message frames are returned. Their count/order/IDs/device
and actor bindings must correspond to accepted application receipts and pins.
The original client performed actual MLS authenticated-sender/frame validation
before persisting the cache; the archive MAC protects that committed result.
The reader does not re-decrypt old message ciphertext after forward-secret keys
may have been erased. It never returns the provider, root key, pending frame,
pending request or receipt payloads to the page. A pending local frame is not
accepted delivery, even if an old outbox also appears in the encrypted backup.

There is no live native request, directory trust update, HTTP enrollment, native
IDB import, outbox flush, reset or re-encryption path in the reader. It only loads
its same-origin pinned modules/WASM. Since it is deliberately an offline history
reader, present-day server revocation does not erase already possessed past
history or prevent a holder of the archive/password from reading it. The result
must never be represented as current account/room authorization or executable
fleet input. A valid old complete archive remains readable historical data; it
is not an anti-rollback witness and must not resume an old sender.

## Lifecycle and resources

Both workers are one-shot. A cooperating origin-wide `family-native-vault-kdf`
Web Lock shares the existing KDF admission slot; a 15-second deadline includes
queue/read/decrypt/validation time and is checked after synchronous work. The
caller owns termination, boot/request timeouts and generation guards because a
synchronous KDF cannot process an in-band cancel. Lock/hidden/pagehide/clone error
retires an in-flight worker and clears its transient password reference. No
secret is persisted by the caller. Its consumer must clear any rendered history
through `onLock`; the isolated proof has no product history UI.

Whole capsule/decoded provider/ciphertext validation completes before any history
is released. Reachable key/provider/decoded byte buffers are wiped on completion
where possible. JavaScript strings/object copies and physical OS memory erasure
are not guaranteed. Same-origin hostile code, extensions and OS compromise remain
outside this custody boundary. Existing 128 MiB combined memory and 5 GiB added
disk budgets remain; default scrypt18 approximately 256 MiB JS scratch is separate.
The new file limit does not relax native 1 MiB provider/2 MiB aggregate/32-event
synthetic quotas. No new runtime package/service is introduced.

## Reproduce

Use existing pinned Go/policy binaries, OpenMLS bundle, Node22.22.2/esbuild0.27.2,
locked age0.3.1/libsodium-wrappers0.8.4 and the existing private test environment.
Never overwrite a retained build output; preserve changed old files or use a
fresh isolated checkout before executing bundler output commands.

```sh
node experiments/device-keystore/node_modules/esbuild/bin/esbuild \
  experiments/device-keystore/history-worker.js \
  experiments/device-keystore/history-export-worker.js --bundle --format=esm \
  --platform=browser --target=es2023 --minify '--external:/pkg/*' \
  --outdir=experiments/device-keystore/bundle
.venv/bin/python tests/native_encrypted_browser_smoke.py --vault-ui --history \
  --bundle artifacts/mls-remapped-pkg --binary artifacts/family-dev-vault-plain \
  --policy-binary artifacts/family-policy-mls-fixed
```

The generated-assertion loopback fixture serves the experimental modules; they
are not compiled into the product server in this unit. Actual two native clients
provide the encrypted state and independently pinned keys. Tests cover source
browser SIGKILL, coherent unchanged snapshots, pending-frame exclusion, committed
text/file integrity, wrong password/identity/pins, changed capsule/record/metadata,
truncation/limits, cancelled KDF admission, caller retirement, reader restart and
absence of native traffic/live IDB writes. Continuing the original test device
requires an explicit original-profile retry, never a recovery import.

Human device loss/replacement trust, independent backup factor/location/retention,
mobile resource/lifecycle, actual CF account gate, server backup/restore and
production enrollment/history/group/fleet limits remain separate open gates.
