The PR27 memory-only proof below is preserved as historical evidence. The current
bundle also includes the [staged IndexedDB adapter](PERSISTENCE.md); its current
dependency counts, source hashes and persistence proof are documented separately.

# Disposable OpenMLS browser experiment

**Synthetic-only, memory-only library proof. Not the family messenger's E2EE
implementation or approved production crypto stack.** No native server, database,
CF account, bot runtime, human key or service configuration is touched. All crypto
state is lost when the worker/browser closes. No ciphertext is sent over a network;
the Python fixture coordinates serialized protocol bytes between isolated workers
in two real Chromium browser contexts. Only static test assets use loopback HTTP.

The wrapper uses public OpenMLS APIs, the mandatory RFC 9420
X25519/AES128GCM/SHA256/Ed25519 suite and RustCrypto provider. Text and a generated
1 KiB opaque byte array are MLS application messages, not a new file cipher. No
upstream application code, custom nonce/KDF/ratchet or protocol draft is used.
BasicCredential labels are **synthetic identifiers, not account authentication or
verified device trust**. An in-memory group accepts one invite only; the synthetic
coordinator accepts that commit before forwarding Welcome. The returned add-commit
is not distributed to a pre-existing group: this wrapper intentionally supports
only initial two-member creation and removal, not adding third/fourth devices.

## Runnable proof

Requirements: verified isolated Rust 1.91.1 + `wasm32-unknown-unknown`, exact
wasm-bindgen CLI 0.2.126, Python with requirements-native-test.txt and Chromium.
No npm, bundler, wasm-pack or new Go dependency. Rust/its standard library are
MIT OR Apache-2.0 except separately attributed components; the verified distribution
ships COPYRIGHT-library.html and its licenses. The toolchain receipt identifies
that standard-library notice (outside the Cargo application graph). Keep the
distribution notices with any later redistributed compiled bundle; this CI uploads
only proof JSON, not a binary distribution. Refer to
[toolchain-evidence.json](toolchain-evidence.json) for official component hashes
and verified release asset hashes. Paths below are operator-selected *new* test
locations; never point at production state. Rustup verifies the official component
checksums; the local run used the separately downloaded and checksum-verified
standalone distribution. The CI workflow uses a private Rustup/Cargo location.

```sh
# Use the verified compiler's bin directory, leaving global tools unchanged.
export PATH="$MLS_TOOLCHAIN/bin:$PATH"
export CARGO_HOME="$MLS_CARGO_CACHE"
export CARGO_TARGET_DIR="$MLS_BUILD_OUTPUT"
export RUSTFLAGS='--cfg getrandom_backend="wasm_js"'
cargo build --locked --release --target wasm32-unknown-unknown \
  --manifest-path experiments/openmls-browser/Cargo.toml
"$MLS_WASM_BINDGEN" "$CARGO_TARGET_DIR/wasm32-unknown-unknown/release/family_mls_browser_experiment.wasm" \
  --target web --out-dir "$MLS_NEW_BUNDLE"
.venv/bin/python tests/native_mls_browser_smoke.py --bundle "$MLS_NEW_BUNDLE"
```

Test evidence is retained under `artifacts/native-mls-browser-*/verification.json`;
no private keys or message bodies are recorded. The driver binds only 127.0.0.1,
checks Host/Origin and serves an exact static allowlist. It cannot target an
existing chat server. Its page explicitly says synthetic; no login or credential
route exists. CSP permits only local scripts/workers/fetch and the narrow
`wasm-unsafe-eval` needed for compilation, with no general `unsafe-eval` or CORS.

Nine assertion groups cover two-way text, opaque bytes, a tampered ciphertext and damaged Welcome followed by permanent device retirement, ciphertext replay, wrong groups in both directions,
nonmember Welcome rejection, an existing-group Welcome refusal, malformed/oversized
input, and removal. The removed device cannot decrypt a new-epoch message even
before receiving the removal commit; after applying it the device cannot send.
The existing-group Welcome test is a wrapper guard, **not proof of durable
KeyPackage consumption or post-restart Welcome replay protection**.

## Dependencies, licenses and security evidence

Cargo.lock pins **197 external packages across all targets**, not the earlier
upstream 485-package workspace. Target-filtered cargo metadata resolves **159
external packages: 6 direct, 153 transitive**, including build/procedural-macro
requirements. This is a dependency graph, not an assertion that all their code is
reachable in the optimized WASM. Direct imports are OpenMLS 0.9.0, RustCrypto
provider 0.6.0, BasicCredential 0.6.0, tls_codec 0.5.0, wasm-bindgen 0.2.126 and
getrandom 0.2.17 for the older entropy bridge. The newer getrandom also needs the
explicit wasm_js backend flag. No unsafe/custom entropy fallback is installed.

[dependencies.json](dependencies.json) records exact versions, checksums, enabled
features, directness and license expressions. `THIRD-PARTY-NOTICES.txt` retains
packaged notices and, when a published crate omitted its workspace license file,
notices from the exact `.cargo_vcs_info.json` upstream revision. MIT/Apache variants,
BSD, Unicode, Unlicense alternatives and **MPL-2.0 (tls_codec/derive)** are included.
No third-party source is modified; exact registry source packages and checksums
remain identified for license/source obligations. This is not a blanket approval
of later binary distribution or other library/provider feature sets.

The provider pulls additional HPKE/libcrux/ML-DSA algorithms and experimental HPKE
features despite choosing only the mandatory suite. They have not been pruned by
inventing a provider or asserted audited. The full lockfile was checked offline
with verified cargo-audit 0.22.2 against the pinned RustSec snapshot in
[toolchain-evidence.json](toolchain-evidence.json): **zero reported vulnerabilities,
one unmaintained advisory RUSTSEC-2026-0173 for proc-macro-error2 2.0.1**. The latter
is absent from the resolved WASM graph; the all-target lock still retains it.
This observation is not a full audit, nor proof of future safety. Recheck
advisories, licenses and feature graph on every dependency change. Runtime native
Go dependencies remain two direct, zero transitive. Rust/compiler/CLI tools are
build-only; Python/Playwright/Chromium are test-only; browser runtime adds own glue,
WASM, workers and browser-provided secure randomness/time.

## Measured scope and remaining gates

See [browser-evidence.json](browser-evidence.json) for exact asset hashes, sizes,
wire overhead, engine and successful checks. This local observation is not a
benchmark distribution or mobile qualification. The test records WASM memory's
allocated linear-memory high-water at operation boundaries (WASM memory does not
shrink); **it excludes JS objects, copies, browser/worker overhead and OS RSS**.
Multiple fresh workers remain alive during the proof; the recorded maximum is
**per worker, not aggregate client/browser memory**. Its 128 MiB check is an observation/experiment failure threshold, not a hard allocator
sandbox. Startup measurement covers `init()` WASM fetch/compile/instantiate after
JS module imports, not full page cold start. Separate cold/warm population and
whole-browser peak memory remain unmeasured. Toolchain/downloads/cache/build use
less than the provisional 5 GiB budget in the recorded local run.

This success qualifies the chosen library/provider for a small foreground
Chromium experiment only. Upstream still labels WASM/Android/iOS unsupported,
built-only targets. SRLabs reviewed core/traits/basic credentials, excluding
crypto/storage providers and example applications; our wrapper has not received
an independent cryptographic audit. Pending: Firefox/Safari/real Android, multiple
devices, trusted enrollment and credential/room binding, bounded control delivery,
transactional crypto state/outbox/cursor, crash/rollback and key recovery, encrypted
large-file format, real CF admission and approved AI-work-room integration.

Incoming wire input is bounded before parsing (64 KiB); plaintext input is bounded
to 16 KiB. Workers have a 10-second harness deadline and are discarded on timeout.
These bounds do not constitute a hardened arbitrary-user API. Library errors can
mutate in-memory state: every failed operation permanently retires this Device,
including malformed/oversized input and duplicate operations. This conservative
policy permits denial of service in the disposable fixture and is not a production
recovery strategy. All exported operations then reject, and fresh tests use new
workers/keys/groups. Retirement blocks use; it does not claim secure erasure of
the provider's memory. There is no automatic reinitialization or recovery.
Do not reuse this memory provider as a durable device, export its secrets to
sessionStorage or silently reconstruct a lost device. The staged transaction/
retirement contract in [NATIVE-E2EE.md](../../docs/NATIVE-E2EE.md) is the next gate,
including old-epoch pending sends when membership changes. Existing synthetic
plaintext data and native pending IDs are untouched; no downgrade or migration.

## Independent-review finding and regression

The independent reviewer reproduced two state-consumption failures on the initial
wrapper: after rejecting an altered ciphertext, OpenMLS could no longer decrypt
its unchanged original; after rejecting a damaged Welcome addressed to the device,
OpenMLS could no longer join with its unchanged original. The first path consumes
sender-ratchet state before AEAD validation; the second consumes the matching
KeyPackage before later Welcome validation. No plaintext disclosure was observed.
A subsequent *new generation* successfully decrypting does not establish safe
retry of the rejected generation. The initial `tamper_then_valid` proof is therefore
superseded by the permanent-retirement regression, not accepted as recovery proof.

The final wrapper retires the entire disposable Device on every error, across
all operations, and cannot continue using uncertain state. Negative cases use
separate fresh groups. Tests explicitly cover altered-then-original ciphertext,
damaged-then-original Welcome, and every API refusing a retired device. The next
provider-transaction unit must stage **all** memory/group/key-package changes,
not only its persistent writes, and prove discard-on-rejection, exact-byte retries,
crash boundaries and replay state. Do not restore just the serialized group while
leaving provider writes/consumed KeyPackages behind. Until that passes, this
experiment is not a persistent receive/retry implementation.
