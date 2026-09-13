# Compiled custody UI — generated data only

The explicit `synthetic_vault` build embeds the password-unlocked encrypted
storage UI at `/vault/`, the worker, pinned OpenMLS and age/libsodium code, and
all license notices. The native server supplies every byte. There is no runtime
asset directory, Node service, CDN or new dependency. This is isolated synthetic
activation, not a deployed CF gate or human-use recovery acceptance.

## Build and select

First reproduce the pinned OpenMLS bundle using [ENCRYPTED-UI.md](ENCRYPTED-UI.md).
Use the existing locked Node 22.22.2/esbuild 0.27.2 build for the custody driver:

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix experiments/device-keystore
node experiments/device-keystore/node_modules/esbuild/bin/esbuild \
  experiments/device-keystore/native-vault-store.js --bundle --format=esm \
  --platform=browser --target=es2023 --minify \
  --outfile=experiments/device-keystore/bundle/native-vault-store.js
python3 tools/prepare_mls_assets.py --vault --bundle artifacts/mls-browser-pkg
python3 tools/prepare_mls_assets.py --vault --bundle artifacts/mls-browser-pkg --check
go -C server test -race -tags synthetic_vault ./...
go -C server build -tags synthetic_vault -trimpath \
  -o ../artifacts/family-dev-vault-embedded ./cmd/family-dev
artifacts/family-dev-vault-embedded --synthetic-only --synthetic-vault-ui \
  --auth-state /absolute/private-synthetic-policy \
  --state /absolute/private-synthetic-chat --listen 127.0.0.1:18920
```

Use a fresh isolated checkout/output for changed build inputs; retain old prepared
bundles. The source bundler command writes its selected output, so do not use it
to replace an older retained artifact. The preparation helper itself never
replaces or deletes existing output.

`internal/chat/vault_bundle.json` version 2 pins exactly 15 files, their source,
route, MIME, size and SHA-256. The original nine-file version-1 manifest,
`mlsassets/` output and `synthetic_mls` tag remain independent. The new private
`vaultassets/` output shares the cooperating build lock, verifies all inputs
before creation, and enforces the same owner/single-link/no-symlink/0700/0600,
exclusive-create and fsync rules. Unknown, incomplete, corrupt or unsafe output
is retained and denied. No automatic repinning, overwrite or repair is provided.
The runtime revalidates canonical manifest, exact file count, MIME and hashes,
within the unchanged 2 MiB/file, 4 MiB/total and 8 KiB/manifest limits.

An untagged binary rejects selection; absent prepared files fail the tagged
build. Missing/invalid selected assets fail before opening policy or chat state.
Missing/empty/invalid auth, non-loopback binding and missing synthetic consent
also fail closed. The two UI flags are mutually exclusive, including in a binary
built with both tags. A tag alone does not activate a route.

The selected vault bundle also includes the original `/encrypted/` page and
shared modules, with their original **unprotected synthetic storage** semantics.
The legacy `/` page remains unchanged. `/vault/` alone selects encrypted storage;
there is no automatic transition or import between profiles or draft namespaces.
Every selected static route requires a current signed principal; GET, exact path,
no query/encoded aliases, same-origin Host checks, no-store/nosniff, inert notice
MIME and narrow existing worker/WASM CSP remain. No fixture-auth fallback is
added. A signed account does not automatically enroll or trust a decrypting
device, or acquire owner execution authority.

## Custody and remaining gates

[VAULT-UI.md](../experiments/openmls-browser/VAULT-UI.md) and
[NATIVE-VAULT.md](../experiments/device-keystore/NATIVE-VAULT.md) define the
unchanged worker contract. Explicit generated 32–128 character password input
is transient. Lock, hidden view, actor/room changes and errors retire workers,
clear protected views/Blob URLs and lock cooperating sibling tabs. Missing,
corrupt, mismatched or locked state does not regenerate keys or repin devices.

The worker commits the whole encrypted provider, independently accepted pins,
exact-byte outbox, cached results and ordered native cursor before output. No
crypto/network wait occurs inside IDB transactions. Password capsule work remains
age default scrypt logN18 (256 MiB JS scratch), once per unlock; secretstream
protects records, with no new custom cipher/KDF. Native CAS/ack, actual MLS sender
validation and stale/uncertain outbox retirement remain unchanged. Text and
8 KiB opaque downloads are tested; full photo/video UX is still outstanding.

Same-origin malicious code, device replacement, human recovery, valid whole-state
rollback witnesses, mobile resource/lifecycle acceptance, actual CF account gate
and backup/restore acceptance remain open before Yukson human-use cutover.
Current production services, keys, data and backups are untouched.

## Verification and inventory

```sh
python3 -m unittest discover -s tests -p test_mls_assets.py
python3 tests/native_asset_activation_smoke.py --vault \
  --binary artifacts/family-dev-vault-embedded --plain-binary artifacts/family-dev-trust
.venv/bin/python tests/native_encrypted_browser_smoke.py --vault-ui --embedded \
  --bundle artifacts/mls-browser-pkg --binary artifacts/family-dev-vault-embedded \
  --policy-binary artifacts/family-policy-trust
```

The forwarding-only loopback fixture injects generated CF-style assertions.
All 15 actual native routes are checked for unauthorized denial and exact bytes.
Two disposable browser contexts exercise the DOM, pins, lock/unlock, text/file,
encrypted IDB, real browser SIGKILL and exact retry, native restart, corrupt state,
identity/revocation and sibling/late-callback cleanup. It never serves replacement
UI code in embedded mode. Original source and actual response hashes are recorded.

No dependency versions or features changed: Go 2 direct/0 transitive external
modules (JWT/SQLite, MIT; cgo/libc); OpenMLS browser target 8 direct/151 transitive
external crates, 197 all-target; custody age/sodium 2 direct/8 transitive runtime
instances, esbuild 2 installed build instances. Node/Python/Rust/Go/wasm-bindgen
are build/test tools, not new runtime services. Existing inventories in
`experiments/device-keystore/` and OpenMLS notices retain exact licenses and
provider/audit qualifications. Age and sodium notices are embedded at
`/vault/licenses/age.txt` and `/vault/licenses/sodium.txt`; Rust/Cargo notices
remain at `/encrypted/licenses/`. Distribute Go `server/licenses/` with binaries.

Local receipt [vault-ui-evidence.json](../docs/evidence/server/vault-ui-evidence.json) records 26 browser
checks, 15 native asset hashes and eight executable selection failures. Asset
preparation has 23 tests; tagged Go race (umask 022), normal (077), vet and the
full Python suite pass. The embedded public bundle is 2,883,280 bytes within
the unchanged 4 MiB limit; no new toolchain installation was needed.

Independent review reproduced a low preparation/runtime mismatch for reordered
JSON fields. Preparation now uses the same fixed top-level and entry ordering as
the Go parser; both profiles reject reordered input before creating output. The
reviewer also ran all 26 DOM checks with an independently built binary containing
both tags, eight vault-only activation denials, and both-tag chat race tests.
