#!/usr/bin/env bash
# JVM(Linux) 왕복 — #366 3b · #338 스파이크 A 2차. Kotlin 바인딩 + android/host 어댑터 + 테스트 `main` 을 kotlinc 로 묶어 JNA 로
# 호스트 cdylib(`libfamily_mls_ios_ffi.so`, dev 빌드)을 불러 돌린다. Gradle·Android SDK 불필요.
#
# 입력(환경변수):
#   KOTLINC       kotlinc 실행 파일(기본 PATH 의 kotlinc)
#   JNA_JAR       jna-<ver>.jar
#   BINDINGS_DIR  uniffi-bindgen --language kotlin 산출 디렉터리(*.kt)
#   FFI_LIB_DIR   libfamily_mls_ios_ffi.so 가 있는 디렉터리(ios-ffi/target/debug)
# 성공 신호: 마지막 줄 `ROUNDTRIP PASS`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
android="$(cd "$here/.." && pwd)"
: "${JNA_JAR:?}" "${BINDINGS_DIR:?}" "${FFI_LIB_DIR:?}"
KOTLINC="${KOTLINC:-kotlinc}"
work="${ROUNDTRIP_WORK:-$(mktemp -d)}"
test -f "$FFI_LIB_DIR/libfamily_mls_ios_ffi.so" || { echo "missing $FFI_LIB_DIR/libfamily_mls_ios_ffi.so" >&2; exit 66; }

mapfile -t sources < <(find "$BINDINGS_DIR" "$android/host/src" -name '*.kt' | sort)
echo "kotlinc: ${#sources[@]} files → $work/roundtrip.jar"
"$KOTLINC" -cp "$JNA_JAR" "${sources[@]}" -include-runtime -d "$work/roundtrip.jar" 2> >(grep -v '^warning:' >&2 || true)

java -Djna.library.path="$FFI_LIB_DIR" -cp "$work/roundtrip.jar:$JNA_JAR" com.seoyoon_family.hande.host.RoomRoundtripKt
