#!/usr/bin/env bash
# Assemble the deployable hande web directory (what the relay serves with -hande-dir).
#
#   archive/native-mls/web/hande/build.sh <mls-pkg dir> <out dir>
#
# <mls-pkg dir> is the built wasm bundle (archive/experiments/openmls-browser/build.sh
# output: family_mls_browser_experiment.js, *_bg.wasm, custody.js, bundle-sha256.txt).
# The shared worker/store modules are copied verbatim from
# archive/experiments/openmls-browser/web — one source for the relay-app and hande.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
shared="$here/../../../experiments/openmls-browser/web"
pkg="${1:?mls-pkg dir}"; out="${2:?out dir}"
[ -f "$pkg/family_mls_browser_experiment.js" ] || { echo "not a bundle dir: $pkg" >&2; exit 1; }
rm -rf "$out"; mkdir -p "$out/pkg" "$out/icons"
for f in durable-worker.js session-store.js history-store.js commit-policy.js relay-attachments.js file-v2.js; do
  install -m 0644 "$shared/$f" "$out/$f"
done
for f in index.html styles.css strings.js ui.js app.js main.js room.js device.js relay.js identity.js worker-bridge.js attachment-view.js agent-markdown.js filebox.js keyboard.js timeline-caret.js shortcuts.js room-order.js drafts.js read-seq.js composer-files.js last-sent.js sync-recovery.js preview-loader.js attachments.js agent-consent.js local-room.js file-v2-outbox.js sw.js sw-policy.js manifest.webmanifest; do
  install -m 0644 "$here/$f" "$out/$f"
done
install -m 0644 "$here"/icons/* "$out/icons/"
for f in family_mls_browser_experiment.js family_mls_browser_experiment_bg.wasm custody.js; do
  install -m 0644 "$pkg/$f" "$out/pkg/$f"
done
[ -f "$pkg/custody-notices.txt" ] && install -m 0644 "$pkg/custody-notices.txt" "$out/pkg/"
if [ -f "$pkg/bundle-sha256.txt" ]; then
  install -m 0644 "$pkg/bundle-sha256.txt" "$out/pkg/bundle-sha256.txt"
  (cd "$out/pkg" && sha256sum --quiet -c bundle-sha256.txt) && echo "bundle hashes verified"
fi
# Optional operator config (defaultRoom): never committed, copied if present next to this script.
[ -f "$here/config.json" ] && install -m 0644 "$here/config.json" "$out/config.json"
echo "hande web assembled at $out"
