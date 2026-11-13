#!/usr/bin/env bash
# 한데 릴레이 재현 빌드 (#243 2-d, D9): digest 고정 컨테이너(같은 디렉터리의 Dockerfile)에서
# native-mls-relay · native-devices 를 빌드하고 <out-dir>/SHA256SUMS 를 쓴다.
#
#   deploy/native-relay/build/build.sh <out-dir>
#
# - 깨끗한 작업트리에서만 빌드한다(추적 변경·추적 안 된 파일이 있으면 실패). 바이너리 buildinfo 의
#   vcs.revision·vcs.modified=false 가 그대로 커밋 증거가 된다(REAL-DEVICE.md §6).
# - <out-dir> 는 저장소 밖이거나 .gitignore 된 곳(예: artifacts/)이어야 한다 — 두 번째 빌드가
#   첫 산출물을 「수정된 트리」로 보지 않게.
# - 매번 새 컨테이너·빈 GOCACHE 에서 빌드한다. 모듈 캐시만 선택적으로 재사용:
#   NATIVE_RELAY_GOMODCACHE_VOLUME=<docker volume> (go.sum 으로 검증되므로 결과에 영향 없음).
# - 같은 커밋을 두 번 빌드해 SHA256SUMS 가 같아야 한다(CI: native-mls.yml 「Relay reproducibility」).
set -euo pipefail

main_pkg_dir=archive/native-mls/server
ldflags='-buildid='

if [ "${1:-}" = "--in-container" ]; then
  # 컨테이너 안: /src = 저장소(읽기 전용), /out = 산출 디렉터리. 경로가 고정이라 -trimpath 와 함께
  # 바이너리에 호스트 경로가 들어가지 않는다.
  export HOME=/tmp/home GOCACHE=/tmp/go-cache GOMODCACHE="${GOMODCACHE:-/tmp/go-mod}"
  mkdir -p "$HOME"
  cd "/src/$main_pkg_dir"
  go build -trimpath -ldflags="$ldflags" -o /out/native-mls-relay .
  go build -trimpath -ldflags="$ldflags" -o /out/native-devices ./cmd/native-devices
  for b in native-mls-relay native-devices; do
    info="$(go version -m "/out/$b")"
    grep -q $'\tvcs.modified=false$' <<<"$info" || { echo "::error::$b: vcs.modified 가 false 가 아니다" >&2; exit 1; }
  done
  {
    echo "commit $(git -C /src rev-parse HEAD)"
    go version
    dpkg-query -W -f '${Package} ${Version}\n' gcc-14 binutils libc6-dev
  } > /out/BUILDINFO
  (cd /out && sha256sum native-mls-relay native-devices > SHA256SUMS)
  exit 0
fi

out="${1:?usage: $0 <out-dir>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
image="${NATIVE_RELAY_BUILD_IMAGE:-family-messenger/native-relay-build:local}"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
if [ -n "$(ls -A "$out")" ]; then
  echo "error: $out 가 비어 있지 않다 — 빈 디렉터리에 빌드한다" >&2; exit 1
fi
dirty="$(git -C "$repo" status --porcelain)"
if [ -n "$dirty" ]; then
  printf 'error: 작업트리가 깨끗하지 않다 (vcs.modified=true 빌드는 재현 증거가 아니다):\n%s\n' "$dirty" >&2; exit 1
fi

docker build --quiet --tag "$image" "$here" >/dev/null

mounts=(-v "$repo:/src:ro" -v "$out:/out")
# git worktree(.git 이 파일)면 공용 git 디렉터리가 저장소 밖에 있다 — 같은 절대 경로로 읽기 전용
# 마운트해야 컨테이너 안 go 가 vcs 정보를 읽는다(경로는 -trimpath 로 바이너리에 들어가지 않는다).
common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)"
case "$common/" in
  "$repo"/*) ;;
  *) mounts+=(-v "$common:$common:ro") ;;
esac
if [ -n "${NATIVE_RELAY_GOMODCACHE_VOLUME:-}" ]; then
  mounts+=(-v "$NATIVE_RELAY_GOMODCACHE_VOLUME:/gomod" -e GOMODCACHE=/gomod)
fi
# --user: 저장소 소유자와 같은 uid 로 돌려 git 「dubious ownership」 없이 vcs 정보를 읽고,
# 산출물도 호출자 소유로 남긴다.
docker run --rm --user "$(id -u):$(id -g)" "${mounts[@]}" \
  "$image" bash "/src/deploy/native-relay/build/build.sh" --in-container

cat "$out/BUILDINFO"
cat "$out/SHA256SUMS"
