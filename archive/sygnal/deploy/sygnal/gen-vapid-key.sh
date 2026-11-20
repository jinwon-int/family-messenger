#!/usr/bin/env bash
# VAPID 키쌍 생성 — 웹푸시용.
#
# 무엇을 만드는가
#   <outdir>/vapid_private_key.pem   서버 개인키. sygnal.yaml의 vapid_private_key가 가리킨다.
#   <outdir>/vapid_public_key.pem    공개키(PEM). 보관용.
#   <outdir>/vapid_application_server_key.txt
#                                    웹앱이 PushManager.subscribe({applicationServerKey})에
#                                    넣는 base64url 문자열. 이것만 클라이언트로 나간다.
#
# 비밀 취급
#   - 개인키는 **저장소에 넣지 않는다.** 이 스크립트는 저장소 밖 경로에만 쓴다.
#   - 개인키 파일은 0600으로 만들고, 배포 시 root:<서비스그룹> 0640으로 조정한다
#     (컨테이너가 그룹 권한으로 읽는다 — docs/SYGNAL-DEPLOY.md §3).
#   - 키를 교체하면 **기존 구독이 전부 무효**가 된다. 가족 전원이 알림을 다시 켜야 하므로
#     교체는 계획된 작업으로만 한다(docs/SYGNAL-DEPLOY.md의 키 교체 절차).
#   - 개인키를 로그·이슈·채팅에 붙여넣지 않는다. 노출되면 교체가 유일한 대응이다.
#
# 왜 컨테이너 안에서 도는가
#   vapid CLI는 sygnal 이미지에 이미 들어 있다(py-vapid는 최상위 의존성).
#   호스트에 파이썬 패키지를 설치하지 않으려고 이미지의 CLI를 빌려 쓴다.
#
# 사용법
#   sudo ./gen-vapid-key.sh /etc/sygnal
#
set -euo pipefail
umask 077   # 중간 산출물이 잠깐이라도 넓은 권한으로 존재하지 않게

OUTDIR="${1:-}"
if [[ -z "$OUTDIR" ]]; then
  echo "사용법: $0 <출력 디렉터리>   (예: /etc/sygnal)" >&2
  exit 2
fi

PINS="$(dirname "$0")/sygnal.pins.json"
if [[ ! -f "$PINS" ]]; then
  echo "핀 파일을 찾을 수 없다: $PINS" >&2
  exit 1
fi

# 핀에서 linux/amd64 digest를 읽는다 — 태그가 아니라 digest로 고정한다.
DIGEST="$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    pins = json.load(fh)
print(pins["image"]["platform_digests"]["linux/amd64"])
' "$PINS")"
IMAGE="docker.io/matrixdotorg/sygnal@${DIGEST}"

RUNTIME=""
for candidate in podman docker; do
  if command -v "$candidate" >/dev/null 2>&1; then
    RUNTIME="$candidate"
    break
  fi
done
if [[ -z "$RUNTIME" ]]; then
  echo "podman 또는 docker가 필요하다." >&2
  exit 1
fi

if [[ ! -d "$OUTDIR" ]]; then
  echo "출력 디렉터리가 없다: $OUTDIR" >&2
  exit 1
fi

PRIV="$OUTDIR/vapid_private_key.pem"
PUB="$OUTDIR/vapid_public_key.pem"
APPKEY="$OUTDIR/vapid_application_server_key.txt"

# 기존 키를 조용히 덮어쓰지 않는다 — 덮어쓰면 가족 전원의 구독이 죽는다.
# 컨테이너가 만드는 중간 이름(private_key.pem/public_key.pem)도 함께 검사한다:
# 앞선 실행이 mv 전에 죽어 그 파일이 남아 있으면 --gen이 조용히 덮어쓰기 때문이다.
for existing in "$PRIV" "$PUB" "$APPKEY" "$OUTDIR/private_key.pem" "$OUTDIR/public_key.pem"; do
  if [[ -e "$existing" ]]; then
    echo "이미 존재한다: $existing" >&2
    echo "키 교체는 기존 구독을 전부 무효화한다. 교체하려면 먼저 백업하고 이 파일들을 직접 치운 뒤 다시 실행한다." >&2
    exit 1
  fi
done

echo "이미지: $IMAGE"
echo "출력  : $OUTDIR"

# vapid --gen --applicationServerKey 는 cwd에 private_key.pem / public_key.pem 을 만들고
# Application Server Key 문자열을 stdout에 찍는다. 컨테이너의 /out 에 만들게 한다.
# ⚠ 실패해도 출력을 반드시 보여준다. `OUTPUT="$(...)"`를 그냥 쓰면 비-0 종료 시
#   set -e가 여기서 스크립트를 죽여, 아래 진단 메시지가 영영 실행되지 않는다.
if ! OUTPUT="$("$RUNTIME" run --rm \
  --entrypoint vapid \
  --volume "$OUTDIR:/out:Z" \
  --workdir /out \
  "$IMAGE" --gen --applicationServerKey 2>&1)"; then
  printf '%s\n' "$OUTPUT" >&2
  echo "키 생성 명령이 실패했다(위 출력 참조). 이미지·볼륨 권한을 확인한다." >&2
  exit 1
fi

printf '%s\n' "$OUTPUT"

if [[ ! -f "$OUTDIR/private_key.pem" || ! -f "$OUTDIR/public_key.pem" ]]; then
  echo "명령은 성공했으나 키 파일이 없다. 위 출력을 확인한다." >&2
  exit 1
fi

mv "$OUTDIR/private_key.pem" "$PRIV"
mv "$OUTDIR/public_key.pem" "$PUB"

# stdout에서 Application Server Key를 뽑는다. 출력 형식이 바뀌면 아래 크기 검사에 걸린다.
# 비압축 P-256 점 65바이트 → 패딩 없는 base64url 87자. 라벨로 앵커링해 오탐을 막는다.
printf '%s\n' "$OUTPUT" | sed -n 's/^Application Server Key *= *//p' | head -1 > "$APPKEY" || true
if [[ ! -s "$APPKEY" ]]; then
  rm -f "$APPKEY"
  echo "경고: Application Server Key를 자동 추출하지 못했다." >&2
  echo "      위 출력에서 'Application Server Key = ' 뒤의 문자열을 직접 $APPKEY 에 저장한다." >&2
fi

# ⚠ 컨테이너가 root로 돌아(이미지에 USER 지시자 없음) 산출물이 root 소유일 수 있다.
#   이 스크립트를 비-root로 실행하면 chmod가 EPERM으로 실패하는데, 그대로 두면
#   개인키가 0644로 남고 재실행은 "이미 존재한다" 가드에 걸려 막힌다.
if ! chmod 0600 "$PRIV" 2>/dev/null; then
  echo >&2
  echo "❌ 개인키 권한을 0600으로 바꾸지 못했다: $PRIV" >&2
  ls -l "$PRIV" >&2 || true
  echo "   컨테이너가 root로 만든 파일이라 비-root 사용자는 chmod할 수 없다." >&2
  echo "   root로 다음을 실행해 마무리한다:" >&2
  echo "     chmod 0600 $PRIV && chown <서비스사용자> $OUTDIR/vapid_*" >&2
  echo "   ⚠ 그 전까지 개인키가 넓은 권한으로 남아 있다." >&2
  exit 1
fi
chmod 0644 "$PUB" 2>/dev/null || true
[[ -f "$APPKEY" ]] && { chmod 0644 "$APPKEY" 2>/dev/null || true; }

echo
echo "생성 완료:"
echo "  개인키(비밀)        : $PRIV        → sygnal.yaml 의 vapid_private_key"
echo "  공개키              : $PUB"
[[ -f "$APPKEY" ]] && echo "  Application Server Key: $APPKEY  → 웹앱 config.json"
echo
echo "다음: 소유자를 서비스 사용자로 바꾼다 —  chown sygnal:sygnal $OUTDIR/vapid_*"
echo "      개인키는 저장소·이슈·채팅 어디에도 붙여넣지 않는다."
