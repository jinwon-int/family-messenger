# deploy/watchdog — 오프호스트 홈서버 워치독 (#412 A)

홈서버 **밖**의 노드에서 홈서버를 감시하고, 홈서버·Matrix 가 모두 죽어도 살아 있는 경로(그 노드의
ccc push spool → Telegram 브리지)로 오너에게 알린다. 스크립트는 `scripts/homeserver_watchdog.py`
(표준 라이브러리만), 유닛 템플릿은 이 디렉터리.

| 파일 | 용도 |
|---|---|
| `family-messenger-watchdog.service` | 원샷 유닛. 외부·사설망 프로브 → 판정 → spool 알림. root 실행, `StateDirectory=family-messenger-watchdog`(0700) |
| `family-messenger-watchdog.timer` | 1분 주기(`OnBootSec=2min`, `AccuracySec=10s`, `RandomizedDelaySec=10`, `Persistent=false`) |
| `watchdog.env.example` | `/etc/family-messenger/watchdog.env` 예시 — 사설 주소·노드명·추가 인자(호스트별 값, 코드에 박지 않음) |

이 디렉터리는 코드·문서만이다. 실제 도메인의 기본값은 스크립트에만 있고, 사설 주소·터널 ID·토큰은 어디에도 쓰지 않는다.

## 왜 오프호스트인가 (2026-10-18 사건)

호스팅사(netcup)가 보안 커널 업데이트로 홈서버 호스트(육손/vps5)를 하이퍼바이저 수준에서 재부팅했다
(19:28:53 KST 종료 → 19:41 재기동, 12분). 그동안 `matrix.<도메인>` 은 Cloudflare 530, 전 노드
`ccc-matrix-bridge` 는 재시작 루프였지만 **아무도 알림을 받지 못했다**. 기존
`family-messenger-health.timer`(`deploy/tuwunel/`, #395)는 홈서버 호스트 **위에서** 돌고 알림도 그 호스트의
Matrix 브리지로 보내므로, 호스트가 꺼지면 프로브와 알림 경로가 함께 죽는다. Matrix 가 죽은 사건을 Matrix 로
알릴 수도 없다. 그래서 이 워치독은 Telegram+Matrix 듀얼 채널 노드(서서 또는 진군)에서 돌며 홈서버에 아무것도
의존하지 않는다. 기록: Wiki yukson ND-4055 · 런북 DOC-3436 RB-987.

> netcup 점검 메일의 서버 ID 는 노드명과 다르다(예: `v2202604353760454015` = 육손). 메일을 볼 때 이 대응표를
> 참고한다 — 코드에는 넣지 않는다.

## 프로브와 판정

| 프로브 | 방법 | up 조건 |
|---|---|---|
| external | `GET <--homeserver-url>/_matrix/client/versions`, 커스텀 UA, 프록시 없음, `--timeout`(기본 10s) | 2xx **이고** JSON 에 `versions` 키. HTTP 상태(Cloudflare 530 등 5xx 포함)는 항상 기록 |
| host | `<--host>:<--host-port>`(기본 22) 로 TCP connect 만(사설망, 예: Tailscale 주소). ssh/tailscale 실행 없음, 데이터 전송 없음 | 연결 성공 |

| external | host | 판정 | 뜻 |
|---|---|---|---|
| up | up | `up` | 정상 |
| down | up | `edge` | 호스트는 살아 있음 → Cloudflare 터널 / tuwunel 만의 문제 |
| any | down | `host_down` | 호스트 자체 불통(하이퍼바이저 재부팅·전원·네트워크) |

## 디바운스와 상태 파일

- 같은 판정이 `--threshold`(기본 3)회 **연속**이어야 확정 전환. 1분 타이머 × 3 = 다운 감지 ≤3분.
- `--state`(기본 `/var/lib/family-messenger-watchdog/state.json`, 0600): 최근 관측, 확정 상태와 시작 시각
  `since`, 상태별 마지막 알림 시각 `last_alert`, 실패해 재시도할 `pending` 알림. 파일이 없거나 깨져 있으면
  빈 상태로 시작한다(실패하지 않음).
- 첫 설치 후 처음 `up` 이 확정될 때는 조용하다(복구 대상이 없음). 처음부터 `edge`/`host_down` 이 확정되면 알린다.

## 알림 코드와 재알림

`--push-spool <dir>` 에 레코드 1개 = JSON 파일 1개(`health-alert-<code>-<epoch_ms>.json`, 0600, dot-tmp 로 쓰고
rename). 어느 브리지가 spool 을 소비하는지는 노드의 일이며 스크립트는 가정하지 않는다 — 서서에서는
Telegram 브리지가 폴백 채널이다.

```json
{"version": 1, "event": "health-alert", "code": "homeserver_down", "kind": "transition",
 "node": "<node>", "recipient": "owner", "ts": "2026-10-18T10:31:00Z", "status": "host_down",
 "text": "homeserver watchdog [<node>]: HOST DOWN — ...", "dedup": "homeserver-watchdog:homeserver_down:<since>:transition"}
```

| 코드 | 언제 |
|---|---|
| `homeserver_down` | `host_down` 으로 확정 전환(`edge` 에서 악화된 경우 포함) |
| `homeserver_edge` | `edge` 로 확정 전환(`host_down` 에서 호스트만 돌아온 경우 포함) |
| `homeserver_recovered` | 나쁜 상태에서 `up` 으로 확정 전환(이전 상태·지속 시간 포함) |

- 나쁜 상태가 지속되면 같은 코드로 `--realert-hours`(기본 6)마다 재알림(`kind: realert`, `dedup` 에 시각 포함).
  그 사이에는 재알림 없음.
- spool 쓰기가 실패하면 종료 코드 1 + 상태에 `pending` 기록 → 다음 실행에서 같은 상태인 동안만 재시도(`kind: retry`).
- 종료 코드: 실행 자체가 됐으면 홈서버 상태와 무관하게 0. 상태 파일/spool I/O 실패 1, 인자 오류 2.
- `--json` 이면 한 줄 JSON 요약(`state`, `candidate`, `streak`, `external`, `host`, `alert`, `record`), 아니면 한 줄 텍스트.

## 설치 (노드 변경 — **별도 오너 승인 후** 진행, 이 PR 에서는 실행하지 않음)

대상: 서서(seoseo, Telegram 폴백 브리지 보유). 홈서버 노드에는 설치하지 않는다.

```bash
# 1. 코드 체크아웃이 /opt/family-messenger-tuwunel 에 있는지 확인(scripts/homeserver_watchdog.py, scripts/push_spool.py)
# 2. 환경 파일(0600 root): 사설 주소·노드명
install -m 0600 deploy/watchdog/watchdog.env.example /etc/family-messenger/watchdog.env
$EDITOR /etc/family-messenger/watchdog.env           # WATCHDOG_HOST=<홈서버 Tailscale 주소>, WATCHDOG_NODE=seoseo
# 3. 수동 1회 실행으로 판정·spool 경로 확인(알림은 3회 연속 확정 전에는 나가지 않는다)
python3 /opt/family-messenger-tuwunel/scripts/homeserver_watchdog.py --host <Tailscale 주소> --push-node seoseo \
  --state /tmp/watchdog-test.json --json        # --push-spool 없이: 판정만
# 4. 유닛 설치·활성화
install -m 0644 deploy/watchdog/family-messenger-watchdog.service deploy/watchdog/family-messenger-watchdog.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now family-messenger-watchdog.timer
systemctl start family-messenger-watchdog.service && journalctl -u family-messenger-watchdog.service -n 3
```

spool 디렉터리 `/root/.claude/state/telegram-spool` 는 그 노드의 ccc 브리지가 만든다. 없으면 스크립트는 알림을
`failed: ValueError` 로 기록하고 종료 코드 1(journal 에 남음) — 브리지 상태를 먼저 확인한다.

## 수동 드릴 (수용 기준 검증 — 홈서버 유닛 정지는 승인 하에)

| 드릴 | 절차 | 기대 |
|---|---|---|
| 홈서버 다운 | 육손에서 `systemctl stop tuwunel.service`(승인) → 대기 | ≤3분 안에 서서 Telegram 에 `homeserver_edge`(호스트는 살아 있으므로 **edge** 분류). 호스트 전체 재부팅이면 `homeserver_down` |
| 복구 | `systemctl start tuwunel.service` | 3회 연속 up 뒤 `homeserver_recovered`(지속 시간 포함) |
| 터널만 정지 | 육손에서 `systemctl stop family-messenger-tunnel.service`(승인) | ≤3분 안에 `homeserver_edge`; `host` 프로브는 ok 로 기록 |
| 6h 재알림 억제 | 나쁜 상태 유지(또는 상태 파일 `last_alert` 를 조작한 드라이런) | 6h 안에는 두 번째 레코드 없음, 6h 경과 후 `kind: realert` 1건 |

> tuwunel 만 정지하면 호스트(sshd)는 살아 있으므로 판정은 `edge` 다. 사건과 같은 `host_down` 은 호스트 재부팅
> 드릴 또는 `WATCHDOG_HOST` 를 일시적으로 닫힌 포트로 바꾼 드라이런으로 확인한다.

## 범위 메모

- 플랜 B(netcup 점검 메일 `Wartungsarbeiten|Maintenance` → 서버 ID 를 노드명으로 치환해 오너 알림)는 같은 이슈 #412 에서
  추적하지만 **이 PR 에는 없다**.
- 홈서버 이중화·자동 페일오버는 범위 밖(별도 이슈).

---

# 릴레이 워치독 (#426) — native-relay(「한데」)

에이전트 채팅이 한데로 옮겨 가면 v2 릴레이(`native-relay`)가 에이전트 채팅과 가족 채팅의 **공통 SPOF**가 된다.
릴레이가 죽은 사건을 릴레이로 알릴 수는 없다. 그래서 홈서버 워치독과 같은 틀(디바운스·상태 파일·재알림·spool)을
`scripts/relay_watchdog.py` 가 재사용한다(`homeserver_watchdog.advance` 에 `alert_codes` 만 넘김).

| 파일 | 용도 |
|---|---|
| `family-messenger-relay-watchdog.service` | 원샷 유닛. 직결·엣지 프로브 → 판정 → spool 알림. 상태 `/var/lib/family-messenger-watchdog/relay-state.json` |
| `family-messenger-relay-watchdog.timer` | 1분 주기(홈서버 워치독 타이머와 같은 설정) |
| `relay-watchdog.env.example` | `/etc/family-messenger/relay-watchdog.env` 예시 — 직결 URL·엣지 URL·노드명·spool·추가 인자 |

## 프로브와 판정

| 프로브 | 방법 | up 조건 |
|---|---|---|
| direct | `GET <직결 URL>/v2/health`(사설망, 노드 봇이 쓰는 것과 같은 경로) | `200` 이고 JSON `{"ok": true}` |
| edge (`--access-env` 있음, **authed**) | CF Access 서비스 토큰 헤더로 `GET <엣지 URL>/v2/health`, 리다이렉트 따라가지 않음 | 터널 너머 릴레이의 `200 {"ok": true}` — 터널까지 끝까지 확인 |
| edge (없음, **edge-only**) | 같은 요청, 토큰 없음 | `3xx`/`401`/`403`(Access 자체 응답 = 엣지 생존) 또는 `200 {"ok":true}`. `5xx`(530/502 등)·무응답은 down |

> edge-only 모드의 한계: Access 가 오리진보다 먼저 답하므로 **Access 뒤에서 터널만 끊긴 경우는 잡지 못한다**.
> 터널 단절까지 잡으려면 워치독 전용 CF Access 서비스 토큰을 발급해 `--access-env` 로 넘긴다(비밀값 — 별도 승인).

| direct | edge | 판정 | 알림 코드 | 뜻 |
|---|---|---|---|---|
| up | up | `up` | `relay_recovered`(나쁜 상태에서 복귀 시) | 정상 |
| up | down | `edge` | `relay_edge` | 터널/Cloudflare 만 문제 — 노드 봇은 정상, 오너 앱(웹·iOS·Android)은 끊김 |
| down | any | `relay_down` | `relay_down` | 릴레이 프로세스 또는 그 호스트 불통 — 봇·앱 모두 끊김 |

디바운스 3회 × 60s(≤3분), 6h 재알림, spool 실패 시 `pending` 재시도, 첫 `up` 무음은 홈서버 워치독과 같다.
레코드는 `health-alert-relay_<…>-<epoch_ms>.json`, `dedup` 은 `relay-watchdog:<code>:<since>:<transition|epoch>`.

## 어디에 설치하나 — 두 곳 (노드 변경, **별도 오너 승인 후**)

릴레이는 서서(seoseo)에서 돈다. 알림 경로는 릴레이에 의존하지 않아야 하므로 실패 범위가 다른 두 곳에 같은 코드를 둔다.

| 설치 노드 | 잡는 사건 | 알림 경로 |
|---|---|---|
| 서서(릴레이 호스트) | 릴레이 **프로세스**만 죽음, 터널만 끊김 | 서서 Telegram 브리지(오너 결정 ② 폴백 채널) |
| 진군(오프호스트) | 서서 **호스트 전체** 불통(이때는 서서 Telegram 도 죽는다) | 진군 Matrix 브리지 — 홈서버는 육손이라 릴레이·서서와 독립 |

두 곳 모두 `RELAY_WATCHDOG_SPOOL` 은 그 노드 ccc 브리지가 소비하는 push spool 이다.

```bash
# 1. 코드 체크아웃(/opt/family-messenger-tuwunel)에 scripts/relay_watchdog.py · homeserver_watchdog.py · push_spool.py 확인
install -m 0600 deploy/watchdog/relay-watchdog.env.example /etc/family-messenger/relay-watchdog.env
$EDITOR /etc/family-messenger/relay-watchdog.env      # 직결 URL·엣지 URL·노드명·spool
# 2. 수동 1회(--push-spool 없이 판정만)
python3 /opt/family-messenger-tuwunel/scripts/relay_watchdog.py --direct-url <직결> --edge-url <엣지> \
  --state /tmp/relay-watchdog-test.json --json
# 3. 유닛 설치·활성화
install -m 0644 deploy/watchdog/family-messenger-relay-watchdog.{service,timer} /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now family-messenger-relay-watchdog.timer
```

## 수동 드릴 (#426 수용 기준 — 릴레이 정지는 승인 하에)

| 드릴 | 절차 | 기대 |
|---|---|---|
| 릴레이 다운 | 서서 `systemctl stop native-relay.service`(승인 — 한데 전체 정지) | ≤3분 안에 서서 Telegram·진군 Matrix 에 `relay_down` |
| 복구 | `systemctl start native-relay.service` | 3회 연속 up 뒤 `relay_recovered`(지속 시간 포함) |
| 터널만 정지 | 서서 cloudflared 의 한데 ingress 정지(승인) | authed 모드: ≤3분 `relay_edge`. edge-only 모드: 감지 못함(위 한계) |
| 6h 재알림 억제 | 나쁜 상태 유지 또는 상태 파일 `last_alert` 조작 드라이런 | 6h 안 두 번째 레코드 없음, 경과 후 `kind: realert` 1건 |

## 범위 메모

- #426 의 "봇 측 신호(`halted`/403/`history_gap` → health 파일)"는 이 PR 에 없다 — native-bot(Rust) 변경이라 후속 PR.
- 릴레이 폴백 전환(#440 warm standby)과는 독립: 이 워치독은 지금 지정된 릴레이 주소만 본다. 전환 후에는 env 의
  직결 URL 을 새 주 릴레이로 바꾼다(전환 런북에 포함).
