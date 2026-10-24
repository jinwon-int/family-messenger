# Steward — 에이전트가 방을 만들고 사람·에이전트를 넣는 모드 (#372 P2)

오너가 채팅으로 "방 만들고 정인 넣어줘"라고 지시하면 운영 노드(육손)가 공명의 봇에 명령을
넣고, **봇 프로세스 하나**가 MLS 상태를 움직인다. 기기(서명키·정책 체인 등록)는 하나,
방은 여러 개. 새 방의 기본 모드는 `silent`(동기화만, 답 없음 — 오너 결정 D3).

## 파일 배치 (`--rooms-dir <dir>`)

| 경로 | 뜻 |
|---|---|
| `--identity-file <path>` | `Device::export_identity` 봉투(서명키만, 그룹 없음). 0600. 한 번 만들면 바꾸지 않는다. |
| `<dir>/<room>.state` | 방별 `StateEnvelope`(기존 `--state-file` 과 같은 형식: 커서·epoch·joined·그룹 상태). |
| `<dir>/<room>.mode` | `agent`·`silent`·`alert`(#423). 없으면 `silent`. `agent` 는 기본 **한 방만**; `--room-frames` 로 띄우면 여러 방(아래). |
| `<dir>/<room>.state.refused` | #263 정지 마커(기존과 동일). |
| `<dir>/cmd/<id>.json` → `<dir>/out/<id>.json` | 명령 큐. CLI 가 쓰고, 세션이 하나씩 처리한 뒤 결과를 쓴다. |
| `<dir>/responder.state` | 응답기 inbox(#354, 기존 `<state>.inbox.json` 역할). |

## 명령

```
native-mls-bot extract-identity <room> <device> --state-file <기존 state> --identity-file <새 identity>
native-mls-bot <base-url> steward <device> --identity-file <path> --rooms-dir <dir> [--responder-unix …] [--access-jwt-file …]
native-mls-bot room create  <room> [agent|silent|alert] --rooms-dir <dir>   # 로컬 그룹 생성(릴레이 방은 첫 초대 commit 이 만든다)
native-mls-bot room join    <room>                  --rooms-dir <dir>   # key package 게시 → 멤버가 초대하면 Welcome 으로 참여
native-mls-bot room invite  <room> <device>         --rooms-dir <dir>   # 상대의 key package 소비(방 → 없으면 로비, #380 P5) → Add commit → echo 뒤 Welcome
native-mls-bot room remove  <room> <device>         --rooms-dir <dir>   # Remove commit(bare)
native-mls-bot room close   <room>                  --rooms-dir <dir>   # 릴레이 방 닫기(410 room_closed) + 이 봇에서 방 잊기(#389)
native-mls-bot room members <room>                  --rooms-dir <dir>
native-mls-bot room mode    <room> agent|silent|alert --rooms-dir <dir>
native-mls-bot room status  <room>                  --rooms-dir <dir>   # room 인자는 형식상 필요(아무 식별자)
```

`room …` 은 결과 JSON 한 줄을 stdout 에 쓰고 `ok` 가 아니면 exit 1. 세션이 없으면 90초 뒤
"timed out waiting for the steward" 로 실패한다(큐 파일은 지운다).

## 응답기에서 방 명령 (P4)

응답기(ccc-node 워커)도 같은 명령을 부를 수 있다 — 파일 큐가 아니라 응답기 포트의 `tool` /
`tool-result` 프레임으로(`AGENT.md` "도구(P4)"). 봇이 **owner actor 가 시작한 turn** 에서만 받고,
인수를 `[A-Za-z0-9_-]{1,64}` 로 검사한 뒤 위 CLI 와 같은 `Steward::execute` 로 실행한다. 대응:

| tool | 명령 |
|---|---|
| `room_create{room, mode?}` | `room create <room> [agent\|silent\|alert]`(기본 silent) |
| `room_join{room}` | `room join <room>` |
| `room_invite{room, device}` | `room invite <room> <device>`(방 key package → 없으면 로비, #380 P5) |
| `room_remove{room, device}` | `room remove <room> <device>` |
| `room_close{room}` | `room close <room>`(#389) |
| `room_members{room}` | `room members <room>` |
| `room_mode{room, mode}` | `room mode <room> agent\|silent\|alert` |
| `room_status{}` | `room status`(room 자리는 `-`) |

결과 JSON 은 `out/<id>.json` 과 같은 모양(`ok` 포함). `steward` 모드가 아니면 `steward_only`, 오너가
아니면 `owner_only`, 인수 불량은 `bad_arguments` 로 거절되고 방에는 아무것도 게시되지 않는다.
이벤트 로그: `agent_tool{name, op, room, arg, ok}`.

## 초대 흐름 (relay-app 의 `invite` 와 같은 규약)

1. 피초대 기기가 key package 를 올린다 — 그 방에(iOS 「참여 요청」(방 이름 입력), relay-app 「키 패키지 게시」, 봇 `room join`)
   **또는** 방과 무관한 **로비**에(앱이 실행될 때 자동 보충, #380 P5 — 사람 기기는 방 이름을 몰라도 초대받을 수 있다).
2. `room invite <room> <device>`: 먼저 `GET /v2/rooms/<room>/keypackages?device=…&consumer=<봇>`, 없으면(404)
   `GET /v2/lobby/keypackages?device=…&consumer=<봇>&room=<room>` 로 **로비 fallback**(릴레이는 방이 아직 없거나
   봇이 멤버일 때만 허용) → `invite_with_commit` → 외부 JSON 에 `members`(merge 뒤 로스터, actor 는 device 접두) 를 실어
   **commit POST**(CAS = 현재 epoch). 결과는 `pending`(seq) + `key_source: "room" | "lobby"`. 409 면 `clear_pending` 뒤 오류.
   둘 다 없으면 게시 없이 오류: `no key package for <device> in room <room> or in the lobby (앱을 한 번 열어 로비 키를 보충하세요)`.
   `room join`(봇 자신의 참여)은 그대로 방 범위 key package 만 올린다 — 로비는 사람 기기용.
3. 세션이 자기 commit echo 를 읽으면 `merge_pending` → epoch+1 → 상태 저장 → **Welcome POST**(targets=[device]).
   이벤트 로그: `own_commit_merged`, `welcome_sent`.
4. 피초대 기기가 Welcome 으로 참여한다.

제거도 같다(Welcome 없음). pending 이 남아 있는 동안 같은 방의 invite/remove 는 거부된다.

## 방 닫기 (#389)

`room close <room>` = `POST /v2/rooms/<room>/close?device=<봇>` → 릴레이가 방을 tombstone 하고 이후 모든 경로가 410 `room_closed` 를
돌려준다(앱은 「운영자가 이 대화방을 닫았습니다」로 정지하고 「목록에서 지우기」를 보인다). 그다음 봇이 그 방을 잊는다 —
`<room>.state`·`<room>.mode`·`<room>.state.refused`·`.state.tmp` 삭제 + 세션 메모리에서 제거(재시작해도 되살아나지 않는다).
- 거부: `agent` 모드 방(먼저 `room mode <room> silent`), 자기 commit 이 pending 인 방, 모르는 방.
- 결과 `relay`: `closed`(200, 이미 닫힌 방도 멱등) · `absent`(404 `no_such_room` — 만들기만 하고 초대한 적 없는 방) ·
  `not_member`(403 `not_a_member` — 이 봇이 내보내진 방, 또는 아직 참여 전 방은 요청 없이) → 셋 다 로컬에서는 잊는다.
- 되돌릴 수 없다: 닫힌 방은 다시 열리지 않는다(새 방을 만들어 초대). 응답기 도구 `room_close` 도 owner-only·승인 대상이다.

## 제약·주의

- 릴레이 재시작·일시 장애(#392): 방 페이지 읽기가 연결 거부·reset·응답 잘림·502/503/504 로 실패하고 그 방이 아직 움직이지 않았으면 세션을 끝내지 않고 기다린다(0.5초부터 두 배, 최대 30초). 이벤트 `relay_unreachable{attempt, wait_ms, error}` → 복구 시 `relay_reachable{after_attempts}`. 페이지 처리 도중(Welcome·echo POST)의 실패는 지금처럼 세션을 끝내 디스크 커서에서 다시 시작한다.
- 릴레이는 기기당 방 생성 32개(`RoomsMaxPerDevice`, #380 D3로 16→32). 새 actor 는 기존 방에 commit 할 수 없다 — 사람 기기는 **초대로만** 들어간다.
- `agent` 방은 기본 한 번에 하나(응답기는 그 방의 메시지만 받고, 답도 그 방에만 쓴다). 여러 개는 아래 `--room-frames`.

## 여러 agent 방 (#423, `--room-frames`)

노드 개인방 + 플릿 알림방(+ 이후 공용방)을 봇 하나·응답기 하나로 서빙한다. `--room-frames`(또는 env
`NATIVE_MLS_BOT_ROOM_FRAMES=1`)로 띄운 steward 만 `agent` 방을 여러 개 둘 수 있다(없이 둘 이상이면 지금처럼 기동 거부).

| 항목 | 단일 방 와이어(기본) | `--room-frames` |
|---|---|---|
| `turn` 프레임 | `room` 없음, `turn_id = t-<seq>` | `"room": "<방>"`, `turn_id = t-<방>-<seq>`(릴레이 seq 는 방마다 따로라 충돌 방지) |
| 답·진행·승인·uncertain | 유일한 agent 방 | **요청이 온 방**(그 방이 아직 `agent` 일 때만 — 도중에 silent 로 바꾸면 말하지 않음) |
| `notice` 프레임 | agent 방 이름일 때만 | 그 방이 `agent` 또는 `alert` 면 게시, 아니면 버림(`agent_outbound_dropped`) |
| 재시작 시 미확인 턴 | agent 방 | 그 턴의 방(inbox 에 `room` 기록; #423 이전 inbox 는 첫 agent 방) |

- 동시 turn 은 프로세스 전체 1개, 큐(`queue_max`) 하나를 방들이 공유한다(Matrix 브리지와 같음).
- `alert` 모드 = 플릿 알림방: `notice` 만 게시하고, 그 방 메시지는 turn 이 되지 않는다(복호화·커서만 진행). 봇끼리의 말 규칙은 #425.
- 응답기(ccc-node hande 브리지)는 `room` 이 자기 설정 방 목록에 있어야 받는다(없으면 `rejected: room-not-allowed`) — 방을 agent 로
  바꾸기 전에 브리지 방 목록에 먼저 넣는다. 세션은 `(actor, room)` 별로 갈린다.
- `status` 이벤트의 `polls_per_round` = 한 라운드의 GET 수(방 수). 방을 늘리면 폴링 요청이 비례해 는다(④ #424 측정 입력).
- 되돌리기: 추가 agent 방을 `room mode <방> silent` 로 돌린 뒤 `--room-frames` 를 뺀다.

## 플릿 알림방의 봇끼리 메시지 (#425, 오너 확정 ④-A)

봇 출력(`client_id = <기기>-echo-<n>`)은 어느 방에서든 읽지 않는 것이 기본이다(루프 방지). **`alert` 모드 방에서만**, 아래를
모두 만족하는 봇 글이 **읽기 전용 turn** 이 된다.

| 조건 | 내용 | 어기면(`peer_skipped.reason`) |
|---|---|---|
| 허용 목록 | 발신 actor 가 `<dir>/<방>.peers`(한 줄에 actor 하나, `#` 주석) 에 있음. 파일 없음 = 아무도 아님. 메시지마다 다시 읽음 | `not_a_peer` |
| 머리 | 본문이 `[alert:<actor>]` 또는 `[alert:<actor>:<깊이>]` 로 시작하고 그 actor 가 발신 actor 와 같음 | `no_alert_header` · `header_actor_mismatch` |
| 깊이 | 깊이 < 2(원래 알림만) | `depth` |
| 속도 | 방마다 분당 6건(`peer_per_min`) | `rate` |

- **읽기 전용(a)**: 그 turn 의 답·진행·승인·uncertain 은 방에 쓰지 않는다(`agent_outbound_suppressed`). 승인 요청은 묻지 않고 즉시 거절,
  도구는 owner-only 라 거절. 응답기에는 `"peer": true` 가 붙어 간다.
- **깊이(b)**: 알림방에 쓰는 모든 notice 앞에 봇이 **자기 actor** 로 `[alert:<actor>]` 를 붙인다(워커가 쓴 머리는 지우고 다시 씀 — 사칭 불가).
  peer turn 이 도는 동안 나온 notice 는 `[alert:<actor>:2]` — 사람은 보지만 다른 봇은 받지 않는다. 연쇄는 한 단계에서 끝난다.
- **속도(c)**: notice 는 방마다 분당 10건(`notice_per_min`), 넘으면 `notice_rate` 로 버린다(모든 방 공통).
- 알림 형식: `[alert:<node>] <제목>` + 줄바꿈 뒤 본문. 발신 경로 = ccc-node push spool → 브리지 `notice` 프레임 → 봇 → 알림방.
- 응답기(ccc-node hande 브리지)는 `sender` 가 자기 `owner`/`family_users` 에 없으면 `rejected: sender-not-allowed` 로 거절한다 — peer actor
  를 받으려면 브리지 설정에 넣어야 한다(거절돼도 peer turn 은 방에 아무것도 쓰지 않는다).
- 답장 허용 플래그는 없다(오너 확정: 읽기만). 생기면 깊이 상한을 그 답장에도 적용해야 한다.
- 단일 방 모드(`session <room> <device> --state-file …`)는 그대로 있다. 공명 전환은 `extract-identity` 1회 뒤
  `steward` 로 ExecStart 을 바꾸는 drop-in(`deploy/native-relay-bot.service.d-40-steward.conf`)으로 한다(승인 항목).
- 명령 큐 디렉터리는 봇 사용자 소유여야 한다. CLI 를 다른 사용자로 돌리면 `runuser -u <봇사용자> -- …` 로.
