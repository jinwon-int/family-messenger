# Compiled read-only history UI — synthetic activation

The `synthetic_history` build includes the qualified historical viewer, its
one-shot caller and two bundled archive workers at `/history/`. All bytes come
from the Go executable. The test proxy injects generated CF-style assertions and
forwards requests; it does not serve or replace UI/worker/WASM assets. This is
loopback synthetic activation, not human device recovery or Yukson cutover.

## Build and select

Use the pinned OpenMLS output and custody driver from [VAULT-UI.md](VAULT-UI.md),
and the pinned history worker build from
[HISTORY-RECOVERY.md](../experiments/device-keystore/HISTORY-RECOVERY.md).
Build changed inputs in a fresh isolated output/checkout; retain older bundles.

```sh
python3 tools/prepare_mls_assets.py --history --bundle artifacts/mls-remapped-pkg
python3 tools/prepare_mls_assets.py --history --bundle artifacts/mls-remapped-pkg --check
go -C server test -race -tags synthetic_history ./...
go -C server build -tags synthetic_history -trimpath \
  -o ../artifacts/family-dev-history-embedded ./cmd/family-dev
artifacts/family-dev-history-embedded --synthetic-only --synthetic-history-ui \
  --auth-state /absolute/private-synthetic-policy \
  --state /absolute/private-synthetic-chat --listen 127.0.0.1:18920
```

`history_bundle.json` version 5 pins exactly 21 files: the previous 15-file vault
content plus the three history UI files, caller and two archive worker bundles.
The private build-only `historyassets_v5/` directory is independent of `mlsassets/`
and `vaultassets/`. The original version-3 manifest is retained byte-for-byte as
`history_bundle_v3.json`; previous `historyassets/` output and binaries remain
untouched. Version 3 is retired from new runtime activation. Build tags and CLI
selection stay the same, with no fallback to the old output. No test forger, generated identity, private provider or instrumented
worker is embedded. Rust, age and sodium license notices remain included.

Preparation shares the original cooperating build lock and validates exact
version/worker-state/field order, file count, source, route, MIME, length and hash.
Owner/single-link/no-symlink/0700/0600 checks, exclusive creation, fsync and bounded
reads are unchanged. Unknown, partial, corrupt and unsafe output is retained and
denied; there is no overwrite, pruning, repinning or automatic repair. Mixed
`--vault`/`--history` preparation selection is rejected before touching outputs.

The runtime revalidates the immutable embedded manifest and file bytes. Limits
remain 8 KiB manifest, 2 MiB per file and 4 MiB total. Current manifest is 6,315
bytes and content totals 4,025,346 bytes. No runtime static directory, CDN or
Node service is introduced. An untagged binary rejects selection; a missing
prepared bundle fails the tagged build. Invalid selected assets fail before
opening auth policy or chat state. All four UI flags are mutually exclusive,
including a binary built with multiple tags. A build tag alone activates nothing.

Selection requires explicit nonempty signed `--auth-state`, `--synthetic-only`
and `127.0.0.1`. Missing/invalid auth does not fall back to public fixture bearers.
The selected profile also serves the unchanged `/vault/` and `/encrypted/`
synthetic pages; `/encrypted/` retains its unprotected experiment storage semantics.
No old profile, draft or chat/media state is migrated or rewritten.

Every exact static route requires current signed admission. GET, exact path,
no query/encoded aliases, same-origin Host/Origin constraints, no-store/nosniff,
inert notice MIME, worker/WASM-only script allowances and no broad CORS remain.
Unknown resources, including `/history-forge-worker.js`, are not served. Signed
asset admission grants no device enrollment, room or owner execution privilege.

## Caller lifecycle fix (#60)

The previous caller could start work after its cleanup callback closed it, and
caller-owned arguments could change after the initial size check during worker
boot. The current caller rechecks terminal/generation/active state after cleanup,
clones bounded input before boot, and rechecks bounds before posting. Callback
reentry cannot orphan a new request; archive/expected/password mutation cannot
change the admitted operation. The original failure reproductions and byte/inode
inventory of the prior prepared output are retained with the verification record.

Only `history-client.js` changes among the 21 public files. The revised profile
uses version 5 (version 4 belongs to the separate aggregate UI) and its own output
directory. Older binaries retain their original behavior and require an explicit
replacement; this source change does not patch an already running binary. The
retired manifest refers to source commit `25bf0eb`; rebuilding it requires that
historical checkout. The active helper denies version-3 substitution and never
rewrites its output. Default/vault/aggregate manifests, crypto/WASM, archive
format and live data remain unchanged.

## Unchanged recovery boundary

[HISTORY-UI.md](../experiments/device-keystore/HISTORY-UI.md) defines the unchanged
DOM/caller contract. Independent expected public bindings and a generated
32–128 character password are explicit. The file and backing buffer are bounded
before reading/cloning; age default scrypt18 and secretstream FINAL authentication
plus complete frozen native-v4/provider/pin validation precede any history output.
No custom cipher/KDF/wrapping, plaintext fallback or new cryptographic API is added.

Only committed inert text and 8 KiB opaque downloads appear. Export reads a
coherent existing encrypted snapshot without writing a profile. Reader exposes
no sender, native log, enrollment, import, reset, active leaf or outbox recovery.
Missing/corrupt/unknown state is retained and denied. Lock/hidden/identity errors
retire workers and clear views/Blob URLs; late callbacks cannot affect a newer
operation. Prior URL-cap and UTF-8 byte-limit regressions remain intact.

Archive/password possession still permits offline historical reading after server
revocation. Signed UI admission is not deletion of previously possessed history.
The encrypted archive includes full provider state; it is not a history-only key
backup, forward-secret backup or whole-valid-rollback witness. It cannot resume
an old sender. Human replacement/recovery ceremony, mobile resource/lifecycle,
real CF login, server backup/restore and production history/group/actor/fleet
capacity remain acceptance gates before Yukson human use.

## Executable/browser qualification

```sh
python3 -m unittest discover -s tests -p test_mls_assets.py
python3 tests/native_asset_activation_smoke.py --history \
  --binary artifacts/family-dev-history-embedded \
  --plain-binary artifacts/family-dev-history-plain
.venv/bin/python tests/native_encrypted_browser_smoke.py --vault-ui --history-ui \
  --embedded --bundle artifacts/mls-remapped-pkg \
  --binary artifacts/family-dev-history-embedded \
  --policy-binary artifacts/family-policy-mls-fixed
```

The embedded mode verifies all 21 native response hashes and unsigned denial,
then runs the existing vault DOM checks plus historical export/download, source
browser SIGKILL, separate reader, committed text/file integrity, pending exclusion,
source ciphertext preservation, signed actor changes, denial/limits/lock/late
completion, no reader native sends or live profile writes, and native restart.
It never needs the test-only forged archive worker. The separate original
nonembedded full-library negative-fixture proof stays in CI. The CI native DOM
step is a superset of the previous vault step; both older profiles still have
integrity, activation and regression coverage. Native media/API/default tests
and the original nine-file two-browser proof remain unchanged.

No runtime dependency/version changed: Go JWT/SQLite 2 direct/0 transitive, cgo
and libc; OpenMLS 8 direct/151 transitive WASM crates; age/sodium 2 direct/8
transitive runtime instances. Existing inventories/notices retain exact licenses.
Node/esbuild, Rust/wasm-bindgen, Go and Python/Playwright are build/test tools.
The 128 MiB combined WASM and 5 GiB added-disk budgets remain, with separate
256 MiB JS scrypt scratch; memory-heavy probes are serialized. No human data,
credentials, production services, backups or Cloudflare settings change here.

[history-v5-evidence.json](history-v5-evidence.json) records the current caller
fix and version-5 transition: 40 native browser checks with 21 matching asset
hashes, 10 activation checks, 47 preparation tests, six caller tests and 137
Python tests under both umasks. Default and all-four-tag Go race tests and vet
cover the current source. The original version-3
[history-ui-evidence.json](history-ui-evidence.json) remains historical evidence;
its earlier clean verdict predates the two caller findings in issue #60 and does
not qualify version 5. Human/Yukson acceptance remains open.
