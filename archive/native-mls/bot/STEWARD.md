# Steward — 에이전트가 방을 만들고 사람·에이전트를 넣는 모드 (#372 P2)

오너가 채팅으로 "방 만들고 정인 넣어줘"라고 지시하면 운영 노드(육손)가 공명의 봇에 명령을
넣고, **봇 프로세스 하나**가 MLS 상태를 움직인다. 기기(서명키·정책 체인 등록)는 하나,
방은 여러 개. 새 방의 기본 모드는 `silent`(동기화만, 답 없음 — 오너 결정 D3).

## 파일 배치 (`--rooms-dir <dir>`)

| 경로 | 뜻 |
|---|---|
| `--identity-file <path>` | `Device::export_identity` 봉투(서명키만, 그룹 없음). 0600. 한 번 만들면 바꾸지 않는다. |
| `<dir>/<room>.state` | 방별 `StateEnvelope`(기존 `--state-file` 과 같은 형식: 커서·epoch·joined·그룹 상태). |
| `<dir>/<room>.mode` | `agent` 또는 `silent`. 없으면 `silent`. `agent` 는 **한 방만**(응답기 1개). |
| `<dir>/<room>.state.refused` | #263 정지 마커(기존과 동일). |
| `<dir>/cmd/<id>.json` → `<dir>/out/<id>.json` | 명령 큐. CLI 가 쓰고, 세션이 하나씩 처리한 뒤 결과를 쓴다. |
| `<dir>/responder.state` | 응답기 inbox(#354, 기존 `<state>.inbox.json` 역할). |

## 명령

```
native-mls-bot extract-identity <room> <device> --state-file <기존 state> --identity-file <새 identity>
native-mls-bot <base-url> steward <device> --identity-file <path> --rooms-dir <dir> [--responder-unix …] [--access-jwt-file …]
native-mls-bot room create  <room> [agent|silent]   --rooms-dir <dir>   # 로컬 그룹 생성(릴레이 방은 첫 초대 commit 이 만든다)
native-mls-bot room join    <room>                  --rooms-dir <dir>   # key package 게시 → 멤버가 초대하면 Welcome 으로 참여
native-mls-bot room invite  <room> <device>         --rooms-dir <dir>   # 상대의 key package 소비(방 → 없으면 로비, #380 P5) → Add commit → echo 뒤 Welcome
native-mls-bot room remove  <room> <device>         --rooms-dir <dir>   # Remove commit(bare)
native-mls-bot room members <room>                  --rooms-dir <dir>
native-mls-bot room mode    <room> agent|silent     --rooms-dir <dir>
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
| `room_create{room, mode?}` | `room create <room> [agent\|silent]`(기본 silent) |
| `room_join{room}` | `room join <room>` |
| `room_invite{room, device}` | `room invite <room> <device>`(방 key package → 없으면 로비, #380 P5) |
| `room_remove{room, device}` | `room remove <room> <device>` |
| `room_members{room}` | `room members <room>` |
| `room_mode{room, mode}` | `room mode <room> agent\|silent` |
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

## 제약·주의

- 릴레이는 기기당 방 생성 32개(`RoomsMaxPerDevice`, #380 D3로 16→32). 새 actor 는 기존 방에 commit 할 수 없다 — 사람 기기는 **초대로만** 들어간다.
- `agent` 방은 한 번에 하나. 응답기는 그 방의 메시지만 받고, 답도 그 방에만 쓴다.
- 단일 방 모드(`session <room> <device> --state-file …`)는 그대로 있다. 공명 전환은 `extract-identity` 1회 뒤
  `steward` 로 ExecStart 을 바꾸는 drop-in(`deploy/native-relay-bot.service.d-40-steward.conf`)으로 한다(승인 항목).
- 명령 큐 디렉터리는 봇 사용자 소유여야 한다. CLI 를 다른 사용자로 돌리면 `runuser -u <봇사용자> -- …` 로.
