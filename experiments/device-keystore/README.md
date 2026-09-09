# Generated-data passkey/file-encryption feasibility

This is a separate library probe supporting [the custody decision](../../docs/DEVICE-KEY-CUSTODY.md).
It is not part of the native UI bundle, a keystore adapter or human E2EE acceptance.
No existing MLS state, real account/passkey or production service is used. The
page handles only a constant generated 2 KiB payload. It deliberately runs typage
in Window to measure the API that a worker-only integration cannot call directly.

## Reproduce

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix experiments/device-keystore
node experiments/device-keystore/node_modules/esbuild/bin/esbuild \
  experiments/device-keystore/probe.js --bundle --format=esm --platform=browser \
  --target=es2023 --minify --outfile=experiments/device-keystore/bundle/probe.js
.venv/bin/python tests/device_keystore_smoke.py --synthetic-only
```

Use the existing Python Playwright 1.62.0/Chromium test environment and Node
22.22.2/npm10.9.7. npm's lockfile verifies package integrity; lifecycle scripts
are disabled. The local esbuild package uses its locked Linux optional binary.
`inventory.json` records all resolved package instances, licenses/SRI and measured
bundle size. No global install, CDN or application runtime Node service is added.
Regenerating the ignored bundle does not update the compiled messenger manifest.

The test owns an ephemeral IPv4 loopback HTTP server with exact localhost Host
and a three-file route allowlist. CSP allows only self scripts/workers and has no
unsafe-eval. Bytes are loaded from fixed build/source paths; no user-supplied
static root. Two independent browser contexts have generated PRF-capable CDP
virtual authenticators; a third has PRF disabled. Browser contexts and the server
close after the run. These are software simulators, not real hardware or account
prompts, and are never attached to a human profile.

Nine assertions cover real library PRF encryption/decryption, different ciphertext
for the same bytes, wrong credential, tamper/truncation with original recovery,
encrypted-byte/credential-hint persistence across page reload, unrelated RP ID,
no-PRF denial and two explicit limitations: valid old ciphertext still decrypts;
WebAuthn credentials API is absent in a secure worker. This is not an MLS cursor,
actor/device/room binding, outbox, restore or authentication test. `probe.saved()`
is only a dummy fixture write, not a safe generic storage/migration interface.
Bounds apply before supplied byte parsing. It creates no custom KDF, cipher,
wrapping format or messaging protocol; all file crypto uses the library APIs.

The fixture's IndexedDB contains only a version, the library's credential hint
and encrypted dummy bytes. It never obtains/export CDP credential private keys.
Verification output records only booleans, versions, asset hashes and timing.
Unknown/corrupt fixture records are not a production recovery UX. No native
messenger database, existing browser profile, file archive or backup is rewritten.

## Retained negative lifecycle observation

`--uv-recovery-probe` additionally forces virtual user verification to fail, then
re-enables it and tries to reopen the same stored file. It currently fails locally
at reopen with `NotAllowedError` (artifact `device-keystore-nsgghwh0`). The cause is
not fully established. Independent raw WebAuthn PRF and non-PRF requests also
fail afterward, narrowing the observation to browser/virtual-authenticator request
state rather than demonstrated file-decryption damage. This diagnostic remains runnable and its failure is **not**
converted to a success/fallback; CI's nine-assertion feasibility run does not claim
UV-failure recovery qualification. It is separate from the known-good direct
PRF/file API probe, and must be resolved along with actual device lock/recovery
acceptance before a human vault is approved.

## Cost and maintenance limits

The experiment adds **one direct runtime candidate package plus seven transitive
package instances** (six unique package names total, including typage; two Noble
versions are duplicated). Two Linux build instances are installed for esbuild;
the full lock contains 35 external instances, including other-platform binaries.
The generated page/library bundle is 149,445 bytes / 54,327 gzip bytes in the
recorded build, without an extra WASM module. Installed node_modules is about
17 MiB. No production Go/Rust/UI dependencies changed.

`THIRD-PARTY-NOTICES.txt` includes the eight runtime instance licenses. Post-quantum support is in both the resolved dependency graph and the bundle
(19 source modules / 55,339 contributing bytes); it was not removed by bundling.
No post-quantum mode is selected by this probe. A zero npm advisory report is not an independent
audit or guarantee about the exact versions. The bounded research did not establish
a full typage WebAuthn audit. The distributed WebAuthn APIs are explicitly
marked `@experimental`; they are not selected as a stable live keystore API. Browser heap/startup timing here is not a real-phone
memory/latency benchmark. Physical key protection, browser/OS/provider backups,
passkey sync, user gestures and cancellation require separate acceptance.

The separate [worker-only password archive probe](PASSWORD-WORKER.md) qualifies another invocation boundary with the same locked dependencies. It does not repair or relabel the negative virtual WebAuthn UV probe.
