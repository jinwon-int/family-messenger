#!/usr/bin/env bash
# Build the family chat web app bundle (web/app/dist) on the deploy host.
# Requires Node ^22.22.2 || ^24.15.0 || >=26 (see web/app/package.json).
# Run before starting/enabling
# family-chat-web.service; re-run and restart the unit on every update.
set -euo pipefail
cd "$(dirname "$0")/../../web/app"
# 잠금 파일(package-lock.json)이 커밋돼 있으므로 CI와 같은 npm ci로 재현 가능하게 설치한다.
npm ci --no-audit --no-fund
npm run build
