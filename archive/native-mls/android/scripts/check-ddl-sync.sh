#!/usr/bin/env bash
# #338 B2 — Android `MessageSchema.ddl` 과 iOS `MessageSchema.ddl`(동결 DDL v1)이 글자 그대로 같은지 비교한다.
# 둘 중 하나만 바뀌면 실패 — 스키마는 두 플랫폼이 함께 올린다(schema_version + 마이그레이션). CI native-mls-android.yml android-app job.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
ios="$here/../ios/FamilyMLSCore/Sources/FamilyMLSCore/Store/MessageRecord.swift"
android="$here/app/src/main/kotlin/com/seoyoon_family/hande/core/MessageSchema.kt"

# 양쪽 모두: 여는 `"""` 다음 줄부터 닫는 `"""` 전 줄까지, 줄 앞뒤 공백을 떼고 빈 줄은 버린다.
extract() {
  awk 'f && /^[[:space:]]*"""/ {exit} f {print} /= """[[:space:]]*$/ {f=1}' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'
}

a="$(extract "$ios")"
b="$(extract "$android")"
[ -n "$a" ] || { echo "no DDL found in $ios"; exit 1; }
[ -n "$b" ] || { echo "no DDL found in $android"; exit 1; }
if [ "$a" != "$b" ]; then
  echo "DDL drift between iOS and Android:"
  diff <(echo "$a") <(echo "$b") || true
  exit 1
fi
echo "DDL in sync: $(echo "$a" | wc -l) lines, $(echo "$a" | grep -c 'CREATE TABLE') tables"
