# 한데 릴레이 재현 빌드 툴체인 (#243 2-d, D9) — 쓰는 법은 같은 디렉터리의 build.sh.
#
# Go 측은 go.mod 의 go 1.27.1 로 이미 재현되지만, cgo(mattn/go-sqlite3) 네이티브 코드는
# 빌드 호스트의 gcc·binutils·libc 에 따라 바이트가 달라진다(2026-10-13 독립 재빌드 불일치).
# 그래서 이미지 전체를 digest 로 고정한다: golang 공식 이미지가 자기 레이어에서 apt 로 깐
# gcc·libc6-dev·binutils 가 이 digest 에 함께 묶이므로 apt 재설치(미러에서 옛 버전이 사라지면
# 깨지는 버전 핀)보다 정확한 고정이다. 아래 RUN 은 그 버전을 적어 둔 기록이자, digest 를 바꿀 때
# 버전 기록도 같이 고치도록 강제하는 fail-closed 검사다.
#
# digest = golang:1.27.1 (1.27.1-trixie) 다중 아키텍처 인덱스; 플랫폼은 linux/amd64 로 고정.
# 갱신: docker buildx imagetools inspect golang:<go.mod 버전> → Digest 줄로 교체 + 버전 기록 갱신.
FROM --platform=linux/amd64 golang:1.27.1@sha256:162be5298a40ed317005c8339c6de4d10d3eef336d66dc8e9259b03ab9d3a6d2

RUN set -eu; \
    check() { v="$(dpkg-query -W -f '${Version}' "$1")"; [ "$v" = "$2" ] || { echo "toolchain drift: $1 $v != $2" >&2; exit 1; }; }; \
    check gcc-14 14.2.0-19; \
    check binutils 2.44-3; \
    check libc6-dev 2.41-12+deb13u4; \
    go version | grep -qx 'go version go1.27.1 linux/amd64'

# GOTOOLCHAIN=local: go.mod 의 toolchain 줄이 바뀌어도 다른 Go 를 내려받지 않고 이 이미지의 Go 만 쓴다.
ENV CGO_ENABLED=1 \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=readonly
