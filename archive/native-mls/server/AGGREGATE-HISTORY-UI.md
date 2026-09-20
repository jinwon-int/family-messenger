# Compiled two-conversation history and chat — synthetic only

Profile 6 embeds the read-only `/aggregate-history/` viewer alongside the
complete `/aggregate/` chat. All 20 public files come from the Go executable;
a proxy is only needed in tests to inject generated signed assertions. There is
no runtime asset directory, CDN, Node service or added dependency. This remains
loopback synthetic activation, not actual CF login, human recovery or Yukson
production deployment.

The new `synthetic_aggregate_history` tag, `--synthetic-aggregate-history-ui` flag,
`aggregate_history_bundle.json` and private `aggregatehistoryassets/` output are
separate from the prior 9/15/21-v3/21-v5/14-file profiles. Those manifests,
prepared outputs, original WASM and browser state remain unchanged. All five UI
flags are mutually exclusive even in a binary built with all tags. A tag alone
activates nothing. No old profile or state is imported, reset or reinterpreted.

## Build and admission

Use the existing locked Node 22.22.2/esbuild 0.27.2 tooling, pinned optional
identity-context WASM from [AGGREGATE-UI.md](AGGREGATE-UI.md), and original complete
aggregate driver. Build into absent outputs in a fresh checkout, or retain
previous output separately before invoking esbuild (which can overwrite files).
The preparation helper itself never overwrites existing files.

```sh
node experiments/device-keystore/node_modules/esbuild/bin/esbuild \
  experiments/device-keystore/aggregate-history-worker.js \
  experiments/device-keystore/aggregate-history-export-worker.js \
  --bundle --format=esm --platform=browser --target=es2023 --minify \
  '--external:/pkg/*' '--external:/trust-directory.js' \
  --outdir=experiments/device-keystore/bundle
python3 tools/prepare_mls_assets.py --aggregate-history --bundle PATH_TO_IDENTITY_CONTEXT_BUNDLE
python3 tools/prepare_mls_assets.py --aggregate-history --bundle PATH_TO_IDENTITY_CONTEXT_BUNDLE --check
go -C server test -race -tags synthetic_aggregate_history ./...
go -C server build -tags synthetic_aggregate_history -trimpath \
  -o ../artifacts/family-dev-aggregate-history ./cmd/family-dev
artifacts/family-dev-aggregate-history --synthetic-only --synthetic-aggregate-history-ui \
  --auth-state /absolute/private-synthetic-policy \
  --state /absolute/private-synthetic-chat --listen 127.0.0.1:18920
```

The 6,305-byte canonical manifest pins exactly 20 files / 4,062,333 public bytes,
within unchanged 8 KiB manifest, 2 MiB/file and 4 MiB total ceilings. Its first
14 entries match the prior aggregate manifest; six viewer/caller/worker files
are additive. Original history worker hashes are checked against the existing
aggregate history inventory. The native API additionally validates exact source,
route, MIME, count, size, hash and version. Neither test instrumentation nor a
forged archive worker is compiled. The old single-room pages are absent here.

Build preparation retains owner/private/single-link/no-symlink checks, the shared
lock, exclusive output creation and fsync. Missing, unknown, partial, unsafe or
corrupt output is retained and denied without repinning or automatic repair.
Missing prepared files fail a tagged build. Missing or invalid selected assets
fail startup before opening policy/chat state. Explicit signed `--auth-state`,
`--synthetic-only` and IPv4 loopback remain mandatory; no fixture auth fallback.

Every asset requires signed admission. Exact GET routes, no encoded/query aliases,
Host/origin checks, no-store/nosniff, inert notices and narrow same-origin
worker/WASM CSP remain unchanged. Static code admission grants no room, device
or AI execution privilege. Rust/Cargo/age/sodium notices are included; distribute
`server/licenses/` alongside the executable for Go dependencies.

## Recovery boundary and evidence

[AGGREGATE-HISTORY-UI.md](../../experiments/device-keystore/AGGREGATE-HISTORY-UI.md)
and its library contracts remain authoritative for the unchanged viewer. Both
rooms, actual provider identity, independently expected pins/groups/fork and
complete FINAL authentication must validate before any history is rendered.
Only accepted text and 8 KiB inert file downloads appear; no composer, sender
restore, enrollment, reset or outbox import is available. Export reads an existing
coherent encrypted aggregate without changing it. Missing/corrupt state denies.

Possessed archives and passwords continue to read historical data after server
revocation. Signed UI admission does not erase old keys or provide a rollback
witness. The encrypted archive contains full providers, not history-only keys.
Source pending outboxes stay pending and cannot be delivered by the viewer.
Current account checks, shared sibling lock/KDF gate, one-shot lifecycle, input
bounds, two Blob URLs, five-minute view and late-callback guards are unchanged.

```sh
python3 -m unittest discover -s tests -p test_mls_assets.py
python3 tests/native_asset_activation_smoke.py --aggregate-history \
  --binary artifacts/family-dev-aggregate-history --plain-binary artifacts/family-dev-current-plain
.venv/bin/python tests/native_encrypted_browser_smoke.py --aggregate-ui --embedded \
  --aggregate-history-embedded --bundle PATH_TO_IDENTITY_CONTEXT_BUNDLE \
  --binary artifacts/family-dev-aggregate-history --policy-binary artifacts/family-policy
```

The native proof creates both conversations through original Go-served chat UI,
then exports both actors through the native history DOM. It checks source browser
SIGKILL/server restart, exact encrypted state preservation, two pending exclusions,
text and 8 KiB file integrity, separate reader with no IDB import or native sends,
wrong password/bindings/swapped archive/tamper/truncation, bounded input,
lock/sibling/hide/late-file completion, account/device changes and revocation.
All 20 native routes are requested unsigned and signed, and their actual response
hashes match independent source pins. Test-only page/proxy failures exercise
transport boundaries; no replacement module or forger is served. The original
isolated history UI and full-library negative fixtures remain separate CI steps,
including same-ID/different-sender and epoch-control regressions.

The [packaging evidence](../../../docs/evidence/server/aggregate-history-ui-evidence.json) records an independent
45-check native browser pass using a clean `be1410b` executable and all 20 matching
original/native hashes. Author activation checks pass 14 cases; Python passes
149 tests under both 022 and 077. Independent default/all-tag race suites each
pass 109 top-level groups and 154 subtests, plus vet, 100 rejected manifest
mutations and all 31 nonempty flag combinations. All 80 prior prepared files
retain their inode, bytes and hash. The reviewed startup-label defect was fixed
in `911c79f` and reverse-tested against the old binary.

Failed attempts are retained rather than counted as passes. An author fixture
tried editing a locked form and then masked its error in chat-only diagnostics;
`be1410b` fixes those test paths. The first independent attempt timed out on an
unchanged pre-history pending marker after 14 checks. Its cause remains
unconfirmed; an unchanged rerun passed all 45 checks without extending the
deadline. The successful receipt does not establish that this fixture can never
be intermittent. CI still has to qualify the final submitted head.

The first PR CI attempt found a separate deterministic test regression: two
default-mode turn fixtures reassigned the command-line `args` variable to a
dictionary. The new startup-label check then failed at the later server restart.
`fc0aa68` names both dictionaries `turn_args`, preserving configuration across
restart. Runtime and asset bytes are unchanged; the evidence retains both failed
CI runs, an independent old-head reproduction, and passing fixed default (15)
and control (24) browser checks. This failure is distinct
from the intermittent preparation marker above.

No Go, Rust, age or sodium dependency versions change. Existing inventories
remain: Go 2 direct/0 transitive; OpenMLS 8 direct/151 transitive WASM crates;
age/sodium 2 direct/8 transitive instances. Go/cgo/libc are runtime requirements;
Node/esbuild, Rust/wasm-bindgen and Python/Playwright are build/test tooling.
The 128 MiB WASM and 5 GiB additional-disk budgets remain, with separate 256 MiB
JS scrypt scratch. Human/mobile resource qualification, device lifecycle, actual
CF account gate, backups, production capacity and fleet binding still precede
Yukson human use. This unit changes no human data, keys, CF settings or services.
