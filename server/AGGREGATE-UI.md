# Compiled protected two-conversation UI — synthetic only

The independent `synthetic_aggregate` profile embeds the complete native
AggregateStore UI at `/aggregate/`. All 14 actual UI, worker, WASM and notice
files are served by Go after signed admission. No runtime asset directory, CDN,
Node service or new dependency is introduced. This is loopback synthetic
activation; it is not production CF login or Yukson human-use acceptance.

The original 9/15/21-file profiles and prepared outputs remain unchanged. This
profile stands alone and does not serve their `/encrypted/`, `/vault/` or
`/history/` pages. The ordinary development `/` page is unchanged. All four
explicit UI flags are mutually exclusive, including a binary built with all
tags. A tag alone activates no route. Profiles and crypto state are not imported,
reinterpreted or reset. The separate generic PR54 admission experiment is not
loaded; only the complete native AggregateStore path is selected.

## Reproducible build

Use the pinned isolated Rust 1.91.1 / wasm-bindgen 0.2.126 procedure from
[IDENTITY-CONTEXT.md](../experiments/openmls-browser/IDENTITY-CONTEXT.md), with the
optional `identity-context` feature. Its WASM SHA256 is
`94482525c6e2deaa95183e91a86ca83cf46c89af97ca149006abbeaea9bdd13d`.
The older default bundle is not repinned or overwritten. Build in a fresh
checkout/output when sources differ; retain prior prepared bundles and profiles.

After installing the already locked build dependencies as documented for the
custody experiments, reproduce the complete driver using Node 22.22.2/esbuild
0.27.2. The following output must be absent or separately retained before using
the bundler, which itself can overwrite a file; the preparation helper never
replaces an existing output:

```sh
node experiments/device-keystore/node_modules/esbuild/bin/esbuild \
  experiments/device-keystore/aggregate-store.js --bundle --format=esm \
  --platform=browser --target=es2023 --minify \
  '--external:/pkg/*' '--external:/trust-directory.js' \
  --outfile=experiments/device-keystore/bundle/aggregate-store.js
python3 tools/prepare_mls_assets.py --aggregate --bundle artifacts/mls-identity-context-pkg
python3 tools/prepare_mls_assets.py --aggregate --bundle artifacts/mls-identity-context-pkg --check
go -C server test -race -tags synthetic_aggregate ./...
go -C server build -tags synthetic_aggregate -trimpath \
  -o ../artifacts/family-dev-aggregate-embedded ./cmd/family-dev
artifacts/family-dev-aggregate-embedded --synthetic-only --synthetic-aggregate-ui \
  --auth-state /absolute/private-synthetic-policy \
  --state /absolute/private-synthetic-chat --listen 127.0.0.1:18920
```

The original 601,367-byte driver must hash to
`c5c82ef05af684395a645269d7dab00630665b95fde0e00e38d6ac4e51409ef5`.
Never package the generated instrumented driver or a test-forge worker.
`aggregate_bundle.json` version 4 pins every source/route/MIME/size/hash, within
unchanged 2 MiB/file, 4 MiB/total and 8 KiB/manifest bounds. The public bundle is
2,911,818 bytes and its canonical manifest is 4,349 bytes. Runtime checks also
validate the aggregate source allowlist. Prepared `aggregateassets/` is separate
and uses the existing cooperating build lock, owner/private/single-link/no-symlink
checks, exclusive creation and fsync. Unknown, corrupt or partial output is
retained and denied, never automatically repaired, deleted or repinned.

All source inputs are checked before output creation. Missing prepared files
reject a tagged build; missing/invalid selected assets reject startup before
policy/chat state opens. Explicit signed auth-state, synthetic consent and IPv4
loopback binding remain mandatory. There is no fixture-auth fallback. Exact GET
routes, no query/encoded aliases, Host/origin checks, no-store/nosniff and the
existing narrow worker/WASM CSP apply. Notices are inert text at
`/aggregate/licenses/{cargo,rust,age,sodium}.txt`; distribute `server/licenses/`
with the binary as well. Dependency versions/features are unchanged from the
already optional identity-context and custody inventories: Go2 direct/0transitive,
OpenMLS8 direct/151transitive WASM crates, age/sodium2 direct/8transitive runtime
instances. Toolchains and Node/Python remain build/test tools only.

## Behavior and verification

[AGGREGATE-CHAT-UI.md](../experiments/openmls-browser/AGGREGATE-CHAT-UI.md),
[AGGREGATE-VAULT.md](../experiments/device-keystore/AGGREGATE-VAULT.md) and
[PREPARATION.md](PREPARATION.md) retain the exact UI/custody/preparation contracts.
Runtime UI and crypto sources are unchanged by packaging: independent pins,
explicit generated passwords, complete encrypted provider/outbox/history/cursor,
exact sealed CAS, two-device preparation before native bind, actual MLS sender
validation and old-epoch pending control handling. Committed contexts/outboxes
are never silently reset, re-encrypted or repinned. Server declarations do not
prove hostile-client storage and are not a distributed lease.

```sh
python3 -m unittest discover -s tests -p test_mls_assets.py
python3 tests/native_asset_activation_smoke.py --aggregate \
  --binary artifacts/family-dev-aggregate-embedded --plain-binary artifacts/family-dev-trust
.venv/bin/python tests/native_encrypted_browser_smoke.py --aggregate-ui --embedded \
  --bundle artifacts/mls-identity-context-pkg \
  --binary artifacts/family-dev-aggregate-embedded --policy-binary artifacts/family-policy-trust
```

The isolated test proxy only injects generated signed assertions and forwards
requests in embedded mode. It never serves replacement UI/library bytes. Every
native asset is requested with and without admission and checked against its
independent source hash. Two actual browser profiles run the existing complete
UI suite plus native restart in both primary and secondary conversations. This
covers text/8KiB files, protected preparation, lost replies/SIGKILL/exact retries,
source pending preservation, room selection, identity/revocation, encrypted IDB,
corruption, lock/sibling/late callbacks and download cleanup. Boundary fixtures
remain separate from library proof. CI uses the embedded version of the same
aggregate DOM suite; the isolated `--aggregate-ui` mode remains runnable.

The browser WASM budget remains 128 MiB; age default scrypt18 uses separate
256 MiB JS scratch. No password work-factor, 2-context/32-receipt/capacity,
256-operation/512-revision or record-size limits are raised here. Aggregate
historical recovery, device lifecycle, mobile performance, actual CF gate,
server-backup restoration, production capacity and fleet binding remain open.
No human credentials, keys, data or production service changes belong to this
unit. Yukson deployment authorization persists through those acceptance steps.
