#!/usr/bin/env bash
# Tuwunel 릴리스 자산을 받아 저장소에 고정한 sha256과 대조하고, deb에서 정적 바이너리를 추출한다.
# 업스트림은 체크섬·서명을 공개하지 않으므로(2026-09-13) tuwunel.pins.json이 무결성 기준이다.
# 불일치·크기 상이·추출 실패는 즉시 삭제 후 exit 1 (fail-closed). 어떤 값도 전송·로그하지 않는다.
#
# 사용: deploy/tuwunel/fetch-tuwunel.sh [--dest DIR] [--pins FILE] [--asset deb|zst] [--offline FILE] [--skip-cpu-check]
#   --dest    출력 디렉터리 (기본: ./tuwunel-dist, 0700)
#   --pins    고정값 파일 (기본: 이 스크립트 옆 tuwunel.pins.json)
#   --asset   deb(기본) | zst. zst는 pins에 sha256이 채워진 경우에만 허용
#   --offline 이미 받아둔 자산 파일을 검증·추출만 한다(네트워크 없음)
#   --skip-cpu-check  x86-64-v3 CPU 플래그 검사와 --version 실행을 건너뛴다(다른 호스트용으로 받을 때)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="./tuwunel-dist"; pins="$here/tuwunel.pins.json"; asset="deb"; offline=""; skip_cpu=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) dest="$2"; shift 2 ;;
    --pins) pins="$2"; shift 2 ;;
    --asset) asset="$2"; shift 2 ;;
    --offline) offline="$2"; shift 2 ;;
    --skip-cpu-check) skip_cpu=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
for tool in python3 sha256sum; do command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 69; }; done

# x86-64-v3 빌드는 AVX2·BMI2·FMA 등이 없는 CPU에서 "Illegal instruction"으로 즉사한다(2026-09-13 다른 호스트에서 실측).
# 다운로드 전에 이 호스트의 CPU 플래그를 확인한다. 검증만 하고 실행하지 않을 때는 --skip-cpu-check.
cpu_check() {
  local need="avx avx2 bmi1 bmi2 f16c fma movbe xsave" miss=""
  [ -r /proc/cpuinfo ] || { echo "warning: /proc/cpuinfo unreadable; skipping CPU check" >&2; return 0; }
  local flags; flags=" $(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2) "
  for f in $need; do case "$flags" in *" $f "*) ;; *) miss="$miss $f";; esac; done
  local lz; lz=$(grep -m1 '^flags' /proc/cpuinfo | grep -oE '\babm\b|\blzcnt\b' | head -1); [ -n "$lz" ] || miss="$miss lzcnt"
  if [ -n "$miss" ]; then
    echo "this CPU lacks x86-64-v3 features required by the pinned build:$miss" >&2
    echo "use a host that supports x86-64-v3, or pin an x86_64-v1/v2 asset in tuwunel.pins.json after cross-verifying its hash" >&2
    return 1
  fi
}
[ -r "$pins" ] || { echo "pins file not readable: $pins" >&2; exit 66; }

read_pin() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d
for k in sys.argv[2].split("."): v=v[k]
print("" if v is None else v)' "$pins" "$1"; }

version="$(read_pin version)"
name="$(read_pin "assets.$asset.name")"
size="$(read_pin "assets.$asset.size")"
sha="$(read_pin "assets.$asset.sha256")"
status="$(read_pin "assets.$asset.status")"
bin_sha="$(read_pin binary.sha256)"
bin_size="$(read_pin binary.size)"
bin_path="$(read_pin binary.path_in_deb)"
[ -n "$sha" ] || { echo "asset '$asset' has no pinned sha256 (status=$status); use --asset deb or update tuwunel.pins.json after cross-verification" >&2; exit 65; }
[ "$status" = "verified" ] || echo "warning: asset '$asset' pin status is '$status'" >&2

if [ -z "$skip_cpu" ]; then cpu_check || exit 78; fi

umask 077
mkdir -p "$dest"; chmod 700 "$dest"
work="$(mktemp -d "$dest/.fetch.XXXXXX")"
cleanup_fail() { rm -rf "$work"; echo "FAILED: nothing installed" >&2; }
trap cleanup_fail ERR

if [ -n "$offline" ]; then
  cp -- "$offline" "$work/$name"
else
  url="https://github.com/matrix-construct/tuwunel/releases/download/$version/$name"
  echo "downloading $name ($version)"
  if command -v curl >/dev/null; then
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 600 -o "$work/$name" "$url"
  else
    wget -q --https-only -O "$work/$name" "$url"
  fi
fi

actual_size="$(stat -c %s "$work/$name")"
[ "$actual_size" = "$size" ] || { echo "size mismatch for $name: expected $size, got $actual_size" >&2; false; }
actual_sha="$(sha256sum "$work/$name" | cut -d' ' -f1)"
[ "$actual_sha" = "$sha" ] || { echo "sha256 mismatch for $name" >&2; false; }
echo "asset ok: $name sha256 verified"

case "$asset" in
  deb)
    command -v dpkg-deb >/dev/null || { echo "missing tool: dpkg-deb (apt: dpkg)" >&2; false; }
    dpkg-deb -x "$work/$name" "$work/root"
    bin="$work/root/$bin_path"
    ;;
  zst)
    command -v zstd >/dev/null || { echo "missing tool: zstd" >&2; false; }
    zstd -d -q -o "$work/tuwunel" "$work/$name"
    bin="$work/tuwunel"
    ;;
esac
[ -f "$bin" ] || { echo "binary not found after extraction" >&2; false; }
actual_bin_size="$(stat -c %s "$bin")"
[ "$actual_bin_size" = "$bin_size" ] || { echo "binary size mismatch: expected $bin_size, got $actual_bin_size" >&2; false; }
actual_bin_sha="$(sha256sum "$bin" | cut -d' ' -f1)"
[ "$actual_bin_sha" = "$bin_sha" ] || { echo "binary sha256 mismatch" >&2; false; }
chmod 755 "$bin"
if command -v ldd >/dev/null && ldd "$bin" >/dev/null 2>&1; then
  echo "warning: binary is dynamically linked; pins say static" >&2
fi

install -m 0755 "$bin" "$dest/tuwunel-$version"
ln -sfn "tuwunel-$version" "$dest/tuwunel"
if [ "$asset" = deb ] && [ -d "$work/root/usr/share/doc" ]; then
  mkdir -p "$dest/doc-$version" && cp -a "$work/root/usr/share/doc/." "$dest/doc-$version/" 2>/dev/null || true
fi
rm -rf "$work"
trap - ERR
echo "installed: $dest/tuwunel -> tuwunel-$version (sha256 $bin_sha)"
if [ -z "$skip_cpu" ]; then "$dest/tuwunel" --version 2>/dev/null || echo "warning: --version failed; check CPU features and libc" >&2; else echo "(--skip-cpu-check: not executing the binary here)"; fi
