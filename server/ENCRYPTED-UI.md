# Compiled encrypted UI — synthetic only

An explicit build includes the own chat page, durable version-4 worker, generated
OpenMLS WASM/glue and license notices in the native Go executable. The Go server
serves the bytes itself at `/encrypted/`; no runtime directory, Node service,
CDN, frontend framework or new module is required. This completes isolated asset
packaging, **not human-use E2EE or a deployed CF account gate**. Family keys/data,
Yukson production services and existing profiles are unchanged.

## Pinned build

Use the verified Rust 1.91.1 toolchain with the wasm32-unknown-unknown target,
wasm-bindgen 0.2.126, the existing Cargo.lock and Go toolchain. From the repository
root, with absolute `CARGO_HOME` and an isolated `CARGO_TARGET_DIR` configured:

```sh
export RUSTFLAGS="--cfg getrandom_backend=\"wasm_js\" --remap-path-prefix=$CARGO_HOME=/cargo --remap-path-prefix=$PWD=/workspace"
cargo build --offline --locked --release --target wasm32-unknown-unknown \
  --manifest-path experiments/openmls-browser/Cargo.toml
wasm-bindgen "$CARGO_TARGET_DIR/wasm32-unknown-unknown/release/family_mls_browser_experiment.wasm" \
  --target web --out-dir artifacts/mls-browser-pkg
python3 tools/prepare_mls_assets.py --bundle artifacts/mls-browser-pkg
python3 tools/prepare_mls_assets.py --bundle artifacts/mls-browser-pkg --check
go -C server test -race -tags synthetic_mls ./...
go -C server build -tags synthetic_mls -trimpath -o ../artifacts/family-dev-embedded ./cmd/family-dev
```

Offline assumes the verified locked dependency cache already exists. CI fetches
locked packages and applies the same path normalization. Without normalization,
Rust panic source paths change the WASM bytes across checkout/cache paths. The
committed `internal/chat/mls_bundle.json` pins exactly nine flat source/output
files, routes, MIME types, lengths and SHA-256 hashes. A source or compiler change
requires an intentional reviewed new manifest; the helper never updates pins.
This detects accidental/mismatched build inputs, not compromise of the source,
compiler or code-serving origin.

The build-only stdlib Python helper holds a private exclusive build lock while
reading pins, verifying source files and creating the ignored `mlsassets/` output.
Inputs must be owned, regular, single-link, not group/other-writable, and have no
symlinked path. Output is 0700/0600 with exclusive creation and fsync. Repeated
preparation accepts only the exact existing private output. Unknown files,
interrupted partial output, corrupted bytes and unsafe links/modes are **retained
and denied**, never overwritten, repaired or deleted. An operator can preserve a
failed/old output directory as an artifact and build in a fresh checkout. The
lock coordinates cooperating builders; same-UID/root interference with the build
workspace is outside this boundary. There is no asset-directory CLI option.

The normal untagged build needs no prepared files. Selecting encrypted UI on that
binary fails before opening chat state. The tagged binary verifies its compiled
manifest, exact file list, MIME, size limits (2 MiB/file, 4 MiB total) and hashes
at selected startup, before policy/chat opening. Missing prepared files also fail
the tagged Go build. Runtime never reloads assets from disk.

## Activation and admission

```sh
artifacts/family-dev-embedded --synthetic-only --synthetic-mls-ui \
  --auth-state /absolute/private-synthetic-policy \
  --state /absolute/private-synthetic-chat --listen 127.0.0.1:18920
```

The selected auth state must already be valid under [AUTH.md](AUTH.md). Omitting
it, selecting an empty/invalid state, omitting synthetic acknowledgement or using
a non-loopback listen address fails closed without fixture fallback. Merely
building tagged assets does not enable them. The legacy root page and routes
remain available with their original semantics; `/encrypted/` is distinct.

All nine encrypted routes require current signed native admission. Only exact
GET paths with no query/encoded path are served. Unknown paths do not get an SPA
fallback. Same-origin/loopback Host checks remain; no CORS or identity-header
bypass is added. Responses use no-store, nosniff, explicit MIME, frame denial and
no-referrer. CSP adds only same-origin worker/script/WASM permissions required by
the existing worker; no general unsafe-eval, inline code or arbitrary asset root.
License documents are served as inert text, including Rust's HTML notice source.
Public code writes do not hold the authority lock; revocation cannot recall code
already admitted, while every later data request rechecks signed authorization.

The browser's existing `/v1/session`, expected-actor, independently accepted
fingerprints and worker pin/room checks remain in force. CF admission alone does
not enroll a decrypting device or confer owner execution authority. The UI still
supports text and **8 KiB opaque files only**, not full photo/video UX. Synthetic
keys in browser storage remain unprotected at rest. Additional/replacement
devices, recovery, actual CF account login, mobile lifecycle, backup acceptance
and human-use rollout remain outstanding.

## Evidence and dependencies

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --ui --embedded \
  --bundle artifacts/mls-browser-pkg --binary artifacts/family-dev-embedded \
  --policy-binary artifacts/family-policy-trust
python3 tests/native_asset_activation_smoke.py --binary artifacts/family-dev-embedded \
  --plain-binary artifacts/family-dev-trust
python3 -m unittest discover -s tests -p test_mls_assets.py -v
```

The loopback test proxy only injects generated assertions and forwards requests;
it never supplies UI assets in embedded mode. Actual upstream UI/worker/WASM
response hashes must match the manifest sources. Two disposable browser profiles
exercise the DOM, independent pins, native encrypted text/file delivery,
interruption/exact retry, tamper/identity/revocation handling and native-process
restart with unchanged keys/history. Verification JSON contains no private keys,
JWTs, plaintext or profile copies. `encrypted-ui-evidence.json` records exact
local artifacts and resource measurements. Existing experiment-only proof modes
remain separate; a primitive/browser roundtrip is not production E2EE acceptance.

No dependency versions or feature selections changed. Go: 2 direct, 0 transitive
external modules, cgo/libc; ship `server/licenses/` with binaries. WASM target:
8 direct and 151 transitive external crates (197 external across all targets),
with the existing provider/maintenance qualifications in NATIVE-E2EE.md. The
bundle includes Cargo THIRD-PARTY-NOTICES and the verified Rust 1.91.1 standard
library copyright inventory (SHA-256
`3aa41caccecaeddad6fcf2f36ce14146ab7baae57064b05b12ecc6b52d5e917f`).
Python/Rust/wasm-bindgen/Go are build tools; Playwright is test-only. At runtime,
the Go binary/libc and browser execute the own JS worker and pinned WASM.
