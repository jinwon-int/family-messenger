# deploy/native-relay — 한데 릴레이 운영 패키지 (#440)

독자 E2EE 트랙(「한데」)의 서버 측은 `native-relay`(Go 단일 프로세스 + SQLite + 정책 체인) 하나다.
이 디렉터리는 그 릴레이의 **오프호스트 스냅샷(0단계)** 유닛이다. 절차·복원·드릴은
[`docs/NATIVE-RELAY-OPERATIONS.md`](../../docs/NATIVE-RELAY-OPERATIONS.md).

| 파일 | 용도 |
|---|---|
| `native-relay-snapshot.service` / `.timer` | 릴레이 호스트에서 5분마다(오너 결정 D1) 온라인 스냅샷 → 로컬 보관 + 수신 호스트 2곳으로 rsync. 경로·대상은 `/etc/native-relay/snapshot.env` (`scripts/native_relay_snapshot.py`) |
| `snapshot.env.example` | 환경 파일 모양(실제 호스트명·키 경로는 호스트에만) |
| `native-relay-snapshot-prune.service` / `.timer` | 수신 호스트 쪽 보존 정리(48 h 전량 + 하루 1개 30일) |
| `30-fence.conf.example` / `fence.env.example` | **1단계 펜스** — 양쪽 릴레이 유닛 drop-in. DNS TXT `_native-relay-active.<도메인>`이 자기 이름일 때만 기동(`scripts/native_relay_fence.py`, DoH, fail-closed). 스냅샷 유닛도 `SNAPSHOT_FENCE_ARGS`로 같은 게이트 |
| `native-relay-repoint` | **1단계 ⑤ 재지정 훅**(봇 호스트, 예: 공명 `/usr/local/sbin/`). `<http://tailnet:port>`을 `/etc/native-relay/relay.env`의 `NATIVE_RELAY_URL`에 쓰고 `native-relay-bot` 재시작 → 새 PID의 `steward_ready` 확인. 쓰기 전 `<url>/v2/health` 200 필수, https·같은 URL 거부(`--force`는 설치 검증용), `--check`는 읽기 전용. 봇 유닛은 `EnvironmentFile=/etc/native-relay/relay.env` + `ExecStart=… ${NATIVE_RELAY_URL} …`로 바꿔 둔다 |
| `native-relay-standby.service.example` | 대기 호스트 릴레이 유닛(APNs 없음, 평시 disabled) |
| `cloudflared-relay-standby.service.example` | 대기 호스트 **별도** 터널(같은 토큰 복제본 금지), ingress 사전 구성 |
| `native-relay-fence-watch.service` / `.timer` | **펜스 정지 측** — 1분마다 TXT를 읽어 다른 호스트가 활성이면 이 호스트 릴레이를 stop(exit 1만; 못 읽으면 그대로 둠). 시작 측 drop-in과 함께 설치해야 펜스가 완성 |
| `cutover.args.example` | `scripts/native_relay_cutover.py @파일` 인자 파일 — 판정(tailnet AND 엣지, 리다이렉트 불인정) → `--confirm` 토큰(계획 전체에 결합) → 복원 → TXT 펜스(연속 3회 확인) → **재프로브** → start → CNAME → 엣지 확인 → 재지정 훅 |

복원·드릴은 유닛이 아니라 운영자가 승인 하에 `scripts/native_relay_restore.py`로 실행한다(릴레이 유닛이 active면 거부).
전환은 대기 호스트에서 `scripts/native_relay_cutover.py`를 두 번 실행한다 — 한 번은 계획과 확인 토큰, 한 번은 `--confirm`(반자동, 오너 결정 B).

이 디렉터리는 코드·문서만이다. 실제 설치(서서 타이머, 수신 호스트 계정·키)는 머지 후 별도 승인으로 진행하며,
여기에 실제 호스트명·키·터널 ID를 쓰지 않는다. APNs `.p8`은 스냅샷에 포함되지 않는다(#440-A).
