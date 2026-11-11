# deploy/native-relay — 한데 릴레이 운영 패키지 (#440)

독자 E2EE 트랙(「한데」)의 서버 측은 `native-relay`(Go 단일 프로세스 + SQLite + 정책 체인) 하나다.
이 디렉터리는 그 릴레이의 **오프호스트 스냅샷(0단계)** 유닛이다. 절차·복원·드릴은
[`docs/NATIVE-RELAY-OPERATIONS.md`](../../docs/NATIVE-RELAY-OPERATIONS.md).

| 파일 | 용도 |
|---|---|
| `native-relay-snapshot.service` / `.timer` | 릴레이 호스트에서 5분마다(오너 결정 D1) 온라인 스냅샷 → 로컬 보관 + 수신 호스트 2곳으로 rsync. 경로·대상은 `/etc/native-relay/snapshot.env` (`scripts/native_relay_snapshot.py`) |
| `snapshot.env.example` | 환경 파일 모양(실제 호스트명·키 경로는 호스트에만) |
| `native-relay-snapshot-prune.service` / `.timer` | 수신 호스트 쪽 보존 정리 — **매시**, 보낸 쪽과 같은 규칙(6 h 전량 + 하루 1개 30일) |
| `30-fence.conf.example` / `fence.env.example` | **1단계 펜스** — 양쪽 릴레이 유닛 drop-in. DNS TXT `_native-relay-active.<도메인>`이 자기 이름일 때만 기동(`scripts/native_relay_fence.py`, DoH, fail-closed). 스냅샷 유닛도 `SNAPSHOT_FENCE_ARGS`로 같은 게이트 |
| `native-relay-repoint` | **1단계 ⑤ 재지정 훅**(봇 호스트 `/usr/local/sbin/`, Termux `$PREFIX/bin/`). `<http://tailnet:port>`을 env 파일의 `NATIVE_RELAY_URL` **한 줄만** 바꾸고(다른 줄·권한 유지 — 릴레이 호스트의 `relay.env`는 릴레이 Access 설정이기도 하다, #699) 봇들을 하나씩 재시작 → 새 PID의 `steward_ready` 확인(`relay_unreachable`이면 실패). 노드별 설정 `/etc/native-relay/repoint.conf`(선택, `repoint.conf.example`): env 파일 경로·여러 유닛(서서 알림 봇·곽가 번개장터 봇)·runit(Termux, svlogd 로그) — 없으면 v1과 같이 `relay.env` + `native-relay-bot.service`. 전환 스크립트 `--client-hook`(반복 가능)로 노드마다 한 줄 |
| `native-relay-swap` | **릴레이 바이너리 교체 정본**(릴레이 호스트, root). `native-relay-swap <staged-binary> <sha256>` — 스테이징 sha256 일치 확인 → `<bin>.old-<sha16>` 백업 → 같은 디렉터리 임시 파일 + `mv`(실행 중 파일에 `cp` 금지: ETXTBSY) → 재시작 → `/v2/health` 200·`"ok":true`(기본 60 s; `/healthz`는 없는 경로) → 실패 시 같은 방식으로 롤백(exit 6, 롤백도 실패 7). 2026-11-03 #659 배포의 이중 재시작 재발 방지 |
| `native-relay-standby.service.example` | 대기 호스트 릴레이 유닛(APNs 없음, 대기일 때 disabled — 활성이 되면 전환 스크립트 enable 단계가 켜고, 옛 호스트는 「계획 이전」 6단계에서 disable) |
| `cloudflared-relay-standby.service.example` | 대기 호스트 **별도** 터널(같은 토큰 복제본 금지), ingress 사전 구성 |
| `native-relay-fence-watch.service` / `.timer` | **펜스 정지 측** — 1분마다 TXT를 읽어 다른 호스트가 활성이면 이 호스트 릴레이를 stop(exit 1만; 못 읽으면 그대로 둠). 시작 측 drop-in과 함께 설치해야 펜스가 완성 |
| `cutover.args.example` | `scripts/native_relay_cutover.py @파일` 인자 파일 — 판정(tailnet AND 엣지, 리다이렉트 불인정) → `--confirm` 토큰(계획 전체에 결합) → 복원 → TXT 펜스(연속 3회 확인) → **재프로브** → start → CNAME → 엣지 확인 → 재지정 훅 |

복원·드릴은 유닛이 아니라 운영자가 승인 하에 `scripts/native_relay_restore.py`로 실행한다(릴레이 유닛이 active면 거부).
전환은 대기 호스트에서 `scripts/native_relay_cutover.py`를 두 번 실행한다 — 한 번은 계획과 확인 토큰, 한 번은 `--confirm`(반자동, 오너 결정 B).

코드 경로 = 릴레이 호스트의 체크아웃 `/opt/family-messenger`(2026-11-08 실측: 서서·순욱). 홈서버 노드의
`/opt/family-messenger-tuwunel` 은 릴레이 호스트에 없다 — 이전 템플릿이 그 경로를 가리켜, 설치된 호스트는
스냅샷 유닛에 drop-in `10-checkout-path.conf` 를 두거나 펜스 유닛을 손으로 고쳐 돌렸다(#426 후속). 그 drop-in 은
이제 템플릿과 같은 값이라 남겨도 무해하다. 체크아웃 위치가 다르면 설치 시 `ExecStart`/`ExecStartPre` 줄만 고친다.

이 디렉터리는 코드·문서만이다. 실제 설치(서서 타이머, 수신 호스트 계정·키)는 머지 후 별도 승인으로 진행하며,
여기에 실제 호스트명·키·터널 ID를 쓰지 않는다. APNs `.p8`은 스냅샷에 포함되지 않는다(#440-A).
