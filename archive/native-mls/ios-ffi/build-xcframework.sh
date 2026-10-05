#!/usr/bin/env bash
# macOS 전용. iOS 기기·시뮬레이터 staticlib 2개 + 호스트 cdylib(바인딩 메타데이터) → FamilyMLS.xcframework + Swift 바인딩.
# 출력: out/FamilyMLS.xcframework, out/swift/FamilyMLS.swift, out/xcframework-sha256.txt (#243 2-d 릴리스 무결성 규칙).
# 사용: archive/native-mls/ios-ffi/build-xcframework.sh [--out DIR]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out"
[ "${1:-}" = "--out" ] && out="$2"
toolchain="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$here/rust-toolchain.toml")"
cd "$here"

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  cargo "+$toolchain" build --locked --release --lib --target "$target"
done
# 바인딩은 빌드 호스트 cdylib 에서 생성한다(라이브러리 모드). staticlib 와 같은 소스·같은 uniffi 핀.
cargo "+$toolchain" build --locked --release --lib
cargo "+$toolchain" run --locked --release --features cli --bin uniffi-bindgen -- \
  generate --library target/release/libfamily_mls_ios_ffi.dylib --language swift --out-dir "$out/swift"

rm -rf "$out/FamilyMLS.xcframework" "$out/headers"
mkdir -p "$out/headers"
cp "$out/swift/FamilyMLSFFI.h" "$out/headers/"
# uniffi 는 <ffi_module>.modulemap 을 내놓는다; xcframework 헤더 디렉터리는 module.modulemap 을 기대한다.
cp "$out/swift/FamilyMLSFFI.modulemap" "$out/headers/module.modulemap"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libfamily_mls_ios_ffi.a -headers "$out/headers" \
  -library target/aarch64-apple-ios-sim/release/libfamily_mls_ios_ffi.a -headers "$out/headers" \
  -output "$out/FamilyMLS.xcframework"

( cd "$out" && find FamilyMLS.xcframework -type f -print0 | sort -z | xargs -0 shasum -a 256 > xcframework-sha256.txt )
{
  echo "device staticlib bytes: $(stat -f %z target/aarch64-apple-ios/release/libfamily_mls_ios_ffi.a)"
  echo "sim staticlib bytes:    $(stat -f %z target/aarch64-apple-ios-sim/release/libfamily_mls_ios_ffi.a)"
  echo "xcframework files sha256 → $out/xcframework-sha256.txt ($(wc -l < "$out/xcframework-sha256.txt") files)"
} | tee "$out/build-report.txt"
