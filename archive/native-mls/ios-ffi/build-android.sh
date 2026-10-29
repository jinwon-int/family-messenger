#!/usr/bin/env bash
# Linux(또는 macOS) — Android 3 ABI .so + Kotlin 바인딩 (#338 스파이크 A, 네 번째 호스트).
# 전제: rustup 에 Android std 타겟 3개, cargo-ndk(=4.1.2), ANDROID_NDK_HOME(없으면 ANDROID_NDK_LATEST_HOME → ANDROID_NDK_ROOT).
# 출력: out/android/jniLibs/<abi>/libfamily_mls_ios_ffi.so, out/android/kotlin/**/*.kt, out/android/jnilibs-sha256.txt, out/android/build-report.txt
# 16 KB 페이지(#584): 64비트 .so 를 -z max-page-size=16384 로 링크하고 LOAD 정렬을 검증한다(실패 = exit 69).
# 사용: archive/native-mls/ios-ffi/build-android.sh [--out DIR] [--platform API]   (기본 API 26 = #338 minSdk 제안)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out/android"; platform=26
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
toolchain="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$here/rust-toolchain.toml")"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_ROOT:-}}}"
[ -n "$ANDROID_NDK_HOME" ] && [ -d "$ANDROID_NDK_HOME" ] || { echo "ANDROID_NDK_HOME not set / not a directory" >&2; exit 65; }
cd "$here"
rm -rf "$out"; mkdir -p "$out"

# 1) Android ABI 3개 — release(opt-level s, lto, strip). cargo-ndk 가 링커·sysroot 를 NDK 에서 고른다.
#    16 KB 페이지(#584 Play: targetSdk 35+ 앱은 64비트 .so 의 LOAD 세그먼트가 16 KB 정렬이어야 한다). NDK r28+ 는 기본 정렬이고 cargo-ndk 4.1.2 는
#    NDK ≤ 27 일 때만 같은 플래그를 더한다(src/cargo.rs) — 어느 NDK 로 빌드해도 같은 결과가 나오도록 여기서도 명시한다(cargo-ndk 는 링커 래퍼로 자기 플래그를
#    따로 넘기므로 RUSTFLAGS 와 충돌하지 않는다). 아래 3) 이 실제 정렬을 검증한다.
RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384" \
  cargo "+$toolchain" ndk --platform "$platform" -t arm64-v8a -t armeabi-v7a -t x86_64 -o "$out/jniLibs" \
  build --locked --release --lib

# 2) Kotlin 바인딩 — 빌드 호스트 dev cdylib 에서 생성(라이브러리 모드). release 는 strip=true 라 uniffi 메타데이터가
#    없어 Linux 에서 bindgen 이 실패한다(native-mls-ios.yml relay-smoke 와 같은 이유로 dev 빌드를 쓴다).
cargo "+$toolchain" build --locked --features cli
host_lib=""
for cand in target/debug/libfamily_mls_ios_ffi.so target/debug/libfamily_mls_ios_ffi.dylib; do
  [ -f "$cand" ] && { host_lib="$cand"; break; }
done
[ -n "$host_lib" ] || { echo "host cdylib not found under target/debug" >&2; exit 66; }
target/debug/uniffi-bindgen generate --library "$host_lib" --language kotlin --out-dir "$out/kotlin"

# 3) 무결성 목록 + 크기 보고 (#243 2-d 릴리스 무결성 규칙 승계) + 16 KB 페이지 정렬 검증(#584 — 64비트 ABI 의 모든 LOAD 세그먼트 Align ≥ 0x4000)
( cd "$out" && find jniLibs -type f -print0 | sort -z | xargs -0 sha256sum > jnilibs-sha256.txt )
readelf_bin="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-readelf 2>/dev/null | head -1)"
[ -n "$readelf_bin" ] || readelf_bin="$(command -v readelf || true)"
[ -n "$readelf_bin" ] || { echo "no llvm-readelf/readelf to verify 16 KB page alignment" >&2; exit 67; }
align_report=""
for abi in arm64-v8a x86_64; do
  f="$out/jniLibs/$abi/libfamily_mls_ios_ffi.so"
  min=""
  while read -r a; do
    [ -n "$a" ] || continue
    if [ -z "$min" ] || [ $((a)) -lt $((min)) ]; then min="$a"; fi
  done < <("$readelf_bin" -lW "$f" | awk '$1=="LOAD"{print $NF}')
  [ -n "$min" ] || { echo "$abi: no LOAD segment found" >&2; exit 68; }
  [ $((min)) -ge 16384 ] || { echo "$abi: LOAD align $min < 16384 — not 16 KB page-size compliant" >&2; exit 69; }
  align_report="$align_report $abi $min"
done
total=0
{
  for abi in arm64-v8a armeabi-v7a x86_64; do
    f="$out/jniLibs/$abi/libfamily_mls_ios_ffi.so"; b=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")
    total=$((total + b)); echo "$abi .so bytes: $b"
  done
  echo "total .so bytes: $total"
  echo "kotlin files: $(find "$out/kotlin" -name '*.kt' | wc -l | tr -d ' ')"
  echo "jniLibs sha256 → $out/jnilibs-sha256.txt ($(wc -l < "$out/jnilibs-sha256.txt") files)"
  echo "16 KB page alignment: ok (min LOAD align:$align_report)"
} | tee "$out/build-report.txt"
