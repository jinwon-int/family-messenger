#!/usr/bin/env bash
# Reproducible WASM bundle build for the native E2EE track (#177 M0).
#
# Pins (must match toolchain-evidence.json):
#   rustc/cargo 1.91.1 with target wasm32-unknown-unknown
#   wasm-bindgen CLI 0.2.126
#   esbuild 0.27.2 from node_modules (run `npm ci --ignore-scripts` here first;
#   package-lock.json pins age-encryption 0.3.1 + libsodium-wrappers 0.8.4)
#
# Usage:
#   MLS_WASM_BINDGEN=/path/to/wasm-bindgen ./build.sh [out-dir]
# Optional: RUSTUP_TOOLCHAIN (default 1.91.1), CARGO_TARGET_DIR.
# Output: <out-dir>/family_mls_browser_experiment.js + _bg.wasm, <out-dir>/custody.js
# (custody bundle, #177 M2b-3) and their sha256.
# Never installs anything; fails closed on any version mismatch.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-$here/pkg}"
toolchain="${RUSTUP_TOOLCHAIN:-1.91.1}"
bindgen="${MLS_WASM_BINDGEN:?set MLS_WASM_BINDGEN to the pinned wasm-bindgen 0.2.126 binary}"

expect() { # expect <label> <actual> <required>
  if [ "$2" != "$3" ]; then echo "build.sh: $1 is '$2', required '$3'" >&2; exit 2; fi
}
rustc_version="$(rustc "+$toolchain" --version | awk '{print $2}')"
expect rustc "$rustc_version" "1.91.1"
bindgen_version="$("$bindgen" --version | awk '{print $2}')"
expect wasm-bindgen "$bindgen_version" "0.2.126"
esbuild="$here/node_modules/.bin/esbuild"
[ -x "$esbuild" ] || { echo "build.sh: run 'npm ci --ignore-scripts' in $here first" >&2; exit 2; }
expect esbuild "$("$esbuild" --version)" "0.27.2"
# node_modules must be exactly the lock (versions + integrity), not a stale install.
node -e '
const [lock, installed] = process.argv.slice(1).map(f => JSON.parse(require("fs").readFileSync(f, "utf8")).packages);
const pick = p => Object.entries(p).filter(([k]) => k).map(([k, v]) => [k, v.version, v.integrity]);
const want = new Map(pick(lock).map(x => [x[0], x])), have = pick(installed);
const bad = have.filter(x => JSON.stringify(want.get(x[0])) !== JSON.stringify(x));
const missing = [...want.keys()].filter(k => !want.get(k)[0].includes("/@esbuild/") && !installed[k]);
if (bad.length || missing.length) { console.error("build.sh: node_modules differs from package-lock.json:", bad.map(x => x[0]), missing); process.exit(2); }
' "$here/package-lock.json" "$here/node_modules/.package-lock.json"
rustup "+$toolchain" target list --installed | grep -qx wasm32-unknown-unknown \
  || { echo "build.sh: wasm32-unknown-unknown target missing for $toolchain" >&2; exit 2; }

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$here/target}"
export RUSTFLAGS='--cfg getrandom_backend="wasm_js"'
cargo "+$toolchain" build --locked --release --target wasm32-unknown-unknown \
  --manifest-path "$here/Cargo.toml"

rm -rf "$out"; mkdir -p "$out"
"$bindgen" "$CARGO_TARGET_DIR/wasm32-unknown-unknown/release/family_mls_browser_experiment.wasm" \
  --target web --out-dir "$out"
# Only the two runtime assets are served; drop the TypeScript declarations.
rm -f "$out"/*.d.ts

# Custody: one ES module (age + libsodium, WASM inlined by libsodium) for the workers.
# Run from $here with relative paths: esbuild embeds module paths relative to the
# working directory, so this keeps the output independent of the caller's cwd.
(cd "$here" && "$esbuild" custody/custody.js --bundle --format=esm --platform=browser --target=es2022 \
  --legal-comments=eof --log-level=warning --outfile="$out/custody.js")
cp "$here/custody/THIRD-PARTY-NOTICES.txt" "$out/custody-notices.txt"

echo "bundle: $out"
for f in family_mls_browser_experiment.js family_mls_browser_experiment_bg.wasm custody.js; do
  printf '%s  %s  %s bytes\n' "$(sha256sum "$out/$f" | cut -d' ' -f1)" "$f" "$(stat -c %s "$out/$f")"
done
