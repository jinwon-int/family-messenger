# deploy/native-relay — 한데 릴레이 운영 패키지 (#440)

독자 E2EE 트랙(「한데」)의 서버 측은 `native-relay`(Go 단일 프로세스 + SQLite + 정책 체인) 하나다.
이 디렉터리는 그 릴레이의 **오프호스트 스냅샷(0단계)** 유닛이다. 절차·복원·드릴은
[`docs/NATIVE-RELAY-OPERATIONS.md`](../../docs/NATIVE-RELAY-OPERATIONS.md).

| 파일 | 용도 |
|---|---|
| `native-relay-snapshot.service` / `.timer` | 릴레이 호스트에서 15분마다 온라인 스냅샷 → 로컬 보관 + 수신 호스트 2곳으로 rsync. 경로·대상은 `/etc/native-relay/snapshot.env` (`scripts/native_relay_snapshot.py`) |
| `snapshot.env.example` | 환경 파일 모양(실제 호스트명·키 경로는 호스트에만) |
| `native-relay-snapshot-prune.service` / `.timer` | 수신 호스트 쪽 보존 정리(48 h 전량 + 하루 1개 30일) |

복원·드릴은 유닛이 아니라 운영자가 승인 하에 `scripts/native_relay_restore.py`로 실행한다(릴레이 유닛이 active면 거부).

이 디렉터리는 코드·문서만이다. 실제 설치(서서 타이머, 수신 호스트 계정·키)는 머지 후 별도 승인으로 진행하며,
여기에 실제 호스트명·키·터널 ID를 쓰지 않는다. APNs `.p8`은 스냅샷에 포함되지 않는다(#440-A).
