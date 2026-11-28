#!/usr/bin/env bash
# 서서 밖 릴레이 감시 정지 드릴 (family-messenger#897 수용 기준, #426 후속).
#
# 감시 노드(권장: 육손)에서 실행한다. 펜스 TXT로 활성 릴레이 호스트를 정하고, 그 호스트의
# 유닛 하나만 HOLD초 멈췄다가 다시 켠 뒤, 감시 노드 Matrix 브리지가 오너 방으로 보낸 알림의
# 시각으로 판정한다. 대상 호스트를 고정하지 않으므로 #753 같은 전환 뒤에도 그대로 쓸 수 있다
# (11-14 드릴은 이전 활성 호스트에 고정돼 PREFLIGHT_FAILED_NO_CHANGE로 끝났다).
#
#   --mode edge   공개 경로만 멈춘다: 활성 호스트의 터널 유닛(--units 의 host=unit). 기대 code relay_edge
#   --mode relay  릴레이 자체를 멈춘다: native-relay. 기대 code relay_down
#   --preflight   사전 점검만(읽기 전용, 변경 없음)
#
# 주의: 서서의 터널은 cloudflared.service 하나가 서서의 모든 공개 호스트(위키·파일보관함 등)를
# 맡는다. 서서가 활성일 때 edge 드릴은 그 호스트들도 HOLD초 동안 끊는다. 실행 승인에 이 범위를
# 함께 적는다. 사전 점검이 하나라도 실패하면 아무것도 바꾸지 않는다(EXIT 10).
#
# 판정(오너가 받은 시각 = 브리지가 보낸 뒤 sent/로 옮긴 시각):
#   정지 후 180초 안에 기대 code 알림, 재개 후 180초 안에 relay_recovered, 같은 사건의 알림이
#   그 사이 1건씩. 「6시간 안 재알림 0」은 이 스크립트 밖에서 6시간 뒤 같은 sent/를 다시 센다.
set -uo pipefail

MODE=edge; PREFLIGHT=0; HOLD=300; SAFETY_PAD=30; OBSERVE=240; WINDOW="0330-0530"
FENCE=_native-relay-active.seoyoon-family.com
EVENT=relay-offhost-alert
STATE=/var/lib/family-messenger-watchdog/relay-offhost-state.json
TIMER=family-messenger-relay-offhost-watchdog.timer
SENT="${HOME:-/root}/.claude/state/telegram-spool/sent"
UNITS="seoseo=cloudflared.service,soonwook=cloudflared-relay-standby.service"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=15"
OUT=""

usage() { sed -n '2,20p' "$0"; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --preflight) PREFLIGHT=1; shift ;;
    --hold) HOLD="$2"; shift 2 ;;
    --units) UNITS="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --sent-dir) SENT="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --fence-record) FENCE="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
case "$MODE" in edge) EXPECT=relay_edge ;; relay) EXPECT=relay_down ;; *) echo "--mode edge|relay" >&2; exit 2 ;; esac
OUT="${OUT:-/root/.claude/state/checks/relay-offhost-drill-$(date +%Y%m%d)}"
mkdir -p "$OUT"; RES="$OUT/result.txt"
say() { echo "$(date '+%F %T') $*" | tee -a "$OUT/drill.log"; }
fail_pre() { say "PREFLIGHT FAIL: $*"; echo "드릴 미실행 — 사전 점검 실패: $*. 변경 없음" > "$RES"; echo "RESULT=PREFLIGHT_FAILED_NO_CHANGE"; exit 10; }

say "=== relay off-host drill mode=$MODE preflight=$PREFLIGHT hold=${HOLD}s"

# ---- 사전 점검 (읽기 전용) ----
ACTIVE="$(PYTHONPATH="$REPO/scripts" python3 -B -c "import native_relay_fence as f, sys; print(f.active_host(sys.argv[1]))" "$FENCE" 2>/dev/null)" \
  || fail_pre "펜스 $FENCE 를 읽지 못함"
say "active relay host (fence): $ACTIVE"
if [ "$MODE" = edge ]; then
  UNIT="$(tr ',' '\n' <<<"$UNITS" | awk -F= -v h="$ACTIVE" '$1==h{print $2}')"
  [ -n "$UNIT" ] || fail_pre "--units 에 활성 호스트 $ACTIVE 의 터널 유닛이 없음"
else
  UNIT=native-relay.service
fi
say "target: $ACTIVE $UNIT (expect $EXPECT)"
[ "$(systemctl is-active "$TIMER")" = active ] || fail_pre "감시 타이머 $TIMER 비활성"
wd="$(python3 -B -c "
import json,sys
d=json.load(open(sys.argv[1]))
f=d.get('fence') or {}
bad=[]
if d.get('state')!='up': bad.append('state=%s' % d.get('state'))
if d.get('open_keys'): bad.append('open_keys=%d' % len(d['open_keys']))
if d.get('oob_pending'): bad.append('oob_pending')
if (f.get('host'), f.get('source')) != (sys.argv[2], 'live'): bad.append('fence=%s/%s' % (f.get('host'), f.get('source')))
print('ok' if not bad else ' '.join(bad))" "$STATE" "$ACTIVE" 2>&1 | tail -1)"
say "watcher state: $wd"
[ "$wd" = ok ] || fail_pre "감시 상태가 정상(up·열린 키 0·대기 사본 없음·펜스 live=$ACTIVE)이 아님: $wd"
[ "$(systemctl is-active ccc-matrix-bridge.service)" = active ] || fail_pre "ccc-matrix-bridge 비활성"
systemctl show -p Environment --value ccc-matrix-bridge.service | tr ' ' '\n' \
  | grep -qE "^CCC_PUSH_FLEET_RELAY_DIRECT_EVENTS=(.*,)?$EVENT(,.*)?$" \
  || fail_pre "Matrix 브리지 CCC_PUSH_FLEET_RELAY_DIRECT_EVENTS 에 $EVENT 가 없음(알림이 서서 릴레이로 감)"
[ -d "$SENT" ] || fail_pre "브리지 sent 폴더 없음: $SENT"
remote="$(timeout 40 $SSH "$ACTIVE" "systemctl is-active $UNIT native-relay.service | tr '\n' ' '; curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:18921/v2/health" 2>&1 | tail -1)"
say "$ACTIVE: $remote"
[ "$remote" = "active active 200" ] || fail_pre "$ACTIVE 의 $UNIT·native-relay·health 가 정상이 아님: $remote"
say "PREFLIGHT OK"
if [ "$PREFLIGHT" = 1 ]; then echo "RESULT=PREFLIGHT_OK_NO_CHANGE"; exit 0; fi

hm=$(date +%H%M)
if [ "$hm" \< "${WINDOW%-*}" ] || [ "$hm" \> "${WINDOW#*-}" ]; then
  say "outside the drill window ($WINDOW)"; echo "드릴 미실행 — 승인된 시간대 밖. 변경 없음" > "$RES"; echo "RESULT=OUTSIDE_WINDOW_NO_CHANGE"; exit 11
fi

# ---- 실행 ----
TAG=$(date +%H%M%S)
# 1) 안전장치를 먼저: 대상 호스트 스스로 HOLD+여유 초 뒤 유닛을 시작한다(감시 노드와 끊겨도 돌아온다).
timeout 40 $SSH "$ACTIVE" "systemd-run --quiet --collect --unit relay-offhost-drill-restore-$TAG --on-active=$((HOLD + SAFETY_PAD)) systemctl start $UNIT" \
  || { say "could not arm the safety timer"; echo "드릴 미실행 — 안전 타이머 예약 실패. 변경 없음" > "$RES"; echo "RESULT=SAFETY_NOT_ARMED_NO_CHANGE"; exit 12; }
armed="$(timeout 40 $SSH "$ACTIVE" "systemctl is-active relay-offhost-drill-restore-$TAG.timer" 2>&1 | tail -1)"
[ "$armed" = active ] || { echo "드릴 미실행 — 안전 타이머 확인 실패($armed). 변경 없음" > "$RES"; echo "RESULT=SAFETY_NOT_ARMED_NO_CHANGE"; exit 12; }
say "safety timer armed on $ACTIVE (+$((HOLD + SAFETY_PAD))s)"
# 2) 정지 → 3) 유지 → 4) 재개 (실패해도 안전 타이머가 여유 초 뒤 시작한다)
T_STOP=$(date +%s); timeout 40 $SSH "$ACTIVE" "systemctl stop $UNIT"; say "stop rc=$? at $T_STOP"
sleep "$HOLD"
timeout 40 $SSH "$ACTIVE" "systemctl start $UNIT"; rc=$?; T_START=$(date +%s); say "start rc=$rc at $T_START"
# 5) 관찰: 복구 판정(3분)과 브리지 전송이 끝날 때까지
sleep "$OBSERVE"
final="$(timeout 40 $SSH "$ACTIVE" "systemctl is-active $UNIT native-relay.service | tr '\n' ' '" 2>&1 | tail -1)"
say "final $ACTIVE: $final"

# 6) 판정: sent/ 에 옮겨진 이 이벤트의 레코드(본문은 출력하지 않는다)
python3 -B - "$SENT" "$EVENT" "$EXPECT" "$T_STOP" "$T_START" "$final" "$RES" <<'PY'
import json, os, sys
sent, event, expect, t_stop, t_start, final, res = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6], sys.argv[7]
rows = []
for name in os.listdir(sent):
    path = os.path.join(sent, name)
    try:
        mtime = os.path.getmtime(path)
        if mtime < t_stop:
            continue
        rec = json.load(open(path, encoding='utf-8'))
    except (OSError, ValueError):
        continue
    if rec.get('event') == event:
        rows.append((mtime, rec.get('code')))
rows.sort()
down = [m for m, c in rows if c == expect]
up = [m for m, c in rows if c == 'relay_recovered' and m >= t_start]
checks = {
    'down_alert_within_180s': bool(down) and down[0] - t_stop <= 180,
    'recovered_within_180s': bool(up) and up[0] - t_start <= 180,
    'one_alert_each': len(down) == 1 and len(up) == 1,
    'units_back': final.split() == ['active', 'active'],
}
ok = all(checks.values())
lines = ['드릴 %s — %s' % ('PASS' if ok else 'FAIL', ', '.join('%s=%s' % kv for kv in checks.items())),
         'down_delay_s=%s recovered_delay_s=%s records=%d' % (
             int(down[0] - t_stop) if down else None, int(up[0] - t_start) if up else None, len(rows)),
         '6시간 안 재알림 0은 %s 이후 같은 sent/ 를 다시 세어 확인' % (t_start + 6 * 3600)]
open(res, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print('\n'.join(lines))
print('RESULT=' + ('PASS' if ok else 'FAIL'))
sys.exit(0 if ok else 1)
PY
