#!/usr/bin/env bash
# Build the family chat web app bundle (web/app/dist) on the deploy host.
# Requires Node >= 22 (esbuild 0.28.2). Run before starting/enabling
# family-chat-web.service; re-run and restart the unit on every update.
set -euo pipefail
cd "$(dirname "$0")/../../web/app"
npm install --no-package-lock --no-audit --no-fund
npm run build
