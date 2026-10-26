# native-mls-bot 에이전트 모드 (#354 A1)

echo 봇(받은 메시지를 그대로 되돌림)을 **ccc-node 응답기**로 바꾸는 선택 모드. 기본(플래그 없음)은 그대로 echo 봇이라 기존 스모크(`tests/native_mls_bot_smoke.py`)는 바뀌지 않는다.

## 켜는 법

```sh
native-mls-bot <base-url> session <room> <device> \
  --state-file /var/lib/native-relay-bot/bot/state.json \
  --access-jwt-file /var/lib/native-relay-bot/bot/jwt \
  --responder-argv-json '["/path/to/ccc-python","/path/to/family-messenger/scripts/fleet_worker.py","--workdir","/root","--codex-cli","/path/to/ccc-codex","--approval-policy","on-request","--sandbox","workspaceWrite","--approval-timeout","600","--turn-timeout","1100"]' \
  --owner-actor owner
```

- `--responder-argv-json`(또는 env `NATIVE_MLS_BOT_RESPONDER_ARGV_JSON`): 응답기 프로세스 argv(JSON 문자열 배열, 셸 없음). 프로토콜은 `docs/FLEET-WORKER.md`(`scripts/fleet_worker.py`) 그대로다. **개발·시험용** — 워커가 봇 사용자로 돈다.
- `--responder-unix <socket>`(또는 env `NATIVE_MLS_BOT_RESPONDER_UNIX`): 서비스 매니저가 가진 유닉스 소켓에 접속한다. **운영용** — 봇(`native-relay-bot`)과 AI 자격을 가진 사용자(공명: `gongmyoung`, Codex 로그인·ccc-node 하네스)가 다를 때 자격 파일을 한 바이트도 옮기지 않는다. `deploy/`:
  - `native-responder.socket` — `/run/native-responder/responder.sock`, 0600 봇 사용자, `Accept=yes`, `MaxConnections=1`
  - `native-responder@.service` — 연결마다 `fleet_worker.py` 를 자격 사용자로 띄우고 `StandardInput/Output=socket`
  - `native-relay-bot.service.d-30-agent.conf` — 기존 봇 유닛 drop-in(env 2개 + `Requires=native-responder.socket`). ExecStart 불변, 되돌리기 = 파일 삭제
  둘은 배타적이다(둘 다 주면 시작 거부).
- **Rust 응답기(#396)**: 같은 포트를 `native-responder`(이 크레이트의 두 번째 bin, `src/bin/native-responder/`)가 말한다. 턴 직렬화·타임아웃·승인 nonce·도구 인수 검증·uncertain 퇴역은 Rust, ccc-node 런타임 호출만 `scripts/ccc_adapter.py`(자식 프로세스, stdio 파이프). 봇 쪽 프레임은 `fleet_worker.py` 와 같아 **봇 바이너리·봇 유닛은 바뀌지 않는다**. 응답기 유닛 ExecStart 만 `native-responder --adapter-argv-json '["<venv python>","<dir>/ccc_adapter.py"]' <fleet_worker 와 같은 플래그>` 로 바꾼다(예: `deploy/native-responder@.service`). 되돌리기 = ExecStart 를 `fleet_worker.py` 로 복원(소켓 활성화라 다음 연결부터). 빌드: `cargo build --release --locked --bin native-responder`.
- 응답기 바인딩: `fleet_worker.py --provider codex`(기본, CodexRuntime) 또는 **`--provider claude`**(ccc-node `ClaudeRuntime`, `--model claude-opus-5-5 --effort high --claude-permission-mode default`; 브리지 venv 파이썬 필요). 공명 운영은 Claude(2026-10-15 오너 결정 — ChatGPT 계정 Codex 가 `*-sol` 모델을 거부함).
- `--owner-actor`(env `NATIVE_MLS_BOT_OWNER_ACTOR`, 기본 `owner`): 승인 답장을 낼 수 있는 actor(기기 ID 의 첫 `-` 앞).
- 응답기가 죽으면 세션도 끝난다(exit 1) — 서비스 매니저가 봇·응답기를 함께 다시 띄운다(`Restart=on-failure`).
- `--room-frames`(env `NATIVE_MLS_BOT_ROOM_FRAMES=1`, #423): steward 에서 agent 방 여러 개 — `turn` 에 `room`, 답은 요청 온 방으로. 규칙표는 `STEWARD.md` "여러 agent 방".
- 플릿 알림방(#425): `alert` 모드 방에서 `<방>.peers` 에 있는 봇의 `[alert:<actor>]` 글만 읽기 전용 turn(답 없음). 규칙은 `STEWARD.md` "플릿 알림방의 봇끼리 메시지".

## 노드에 설치하기 (플릿 롤아웃, #420 ⑥ / ccc-node #2380)

노드마다 **봇 기기 1개 + 방 1개**: `deploy/install-node-bot.sh --node <node> --relay-url http://<릴레이 tailnet>:18921 --relay-public-url https://<릴레이 호스트> --binary <native-mls-bot 빌드> --token-env /root/.config/native-relay/bot-service-token.env` (root). 사용자·디렉터리·바이너리·JWT 갱신 타이머·steward 유닛(`<node>-bot`, actor = `<node>`)·응답기 drop-in(`/run/ccc-hande/responder.sock`, ccc-node 브리지가 서빙)을 만들고, **신원을 부트스트랩**하고(steward 모드는 identity 파일을 만들지 않고 읽기만 하므로, 8초 한도의 `session` 1회 실행으로 state 파일을 만든 뒤 `extract-identity`로 `bot/identity.json`을 뽑고 state는 파기 — 기존 파일이 있으면 유지), 봇의 `steward_ready` 로그에서 공개키를 읽어 등록 후보 JSON을 `/var/lib/native-relay-bot/bot/enrollment.json`(0600)에 쓴다 — 릴레이 운영자가 `native-devices -enroll-first`에 넣는다(승인). 등록 전 봇은 403을 받으며 재시도한다(정상). 응답기(ccc-node `CCC_CHANNEL=hande`)는 ccc-node `scripts/install-hande-bridge.sh`가 세운다. 되돌리기: `systemctl disable --now native-relay-bot native-relay-jwt-refresh.timer`.

## 동작 규칙 (오너 결정 2026-10-15, #354)

| 규칙 | 구현 |
|---|---|
| ②-B 모든 메시지에 반응 | 멘션 게이트 없음. 응답기가 빈 답을 주면 전송 없음 |
| 봇끼리 루프 방지 | actor 가 `bot` 으로 시작하는 발신 무시(`agent_skipped: bot_actor`) + 기존 `*-echo-<n>` 무시 |
| 첨부 무시 | `client_id` 가 `file-v1-<uuid>` 또는 `file-v2-<uuid>`(#499 분리 첨부 — 설명자에 파일 키가 있어 에이전트에 절대 넘기지 않음)면 무시(`agent_skipped: attachment`) |
| ③-B 가족 허용 | `bot*` 를 뺀 모든 actor 의 메시지가 turn 이 된다. 실행 권한은 아래 승인으로만 |
| ④-B 승인 왕복 | 응답기 `approval` → 방에 `⚠️ 승인 필요 #n: …` → **owner actor 의 답장** `승인 n` / `거절 n`(`approve n`/`deny n`) 만 유효 → 응답기 `approve`/`deny`. 미응답은 응답기 `--approval-timeout` 이 거절 |
| 동시성 | 한 번에 1 turn, 대기열 8(초과는 `agent_offer: Dropped{queue_full}`) |
| 중복 실행 금지 | 활성 turn 을 `<state>.inbox.json`(0600)에 **응답기에 보내기 전** 기록. 재시작 때 남아 있으면 `⚠️ 요청(#seq)을 끝까지 확인하지 못했습니다` 1건만 게시하고 지운다 — 재실행 없음 |
| 불확실 결과 | `result.status=uncertain`·`rejected`·워치독(21780초 = Matrix `CLAUDE_PROCESS_TIMEOUT` 21720초 + 60초, env `NATIVE_MLS_BOT_TURN_SECS`) → 같은 안내 1건. 30분마다 「⏱ 요청(#n)을 처리한 지 N분」 알림(알림만, env `NATIVE_MLS_BOT_TURN_AGE_NOTICE_MIN`·`_RENOTICE_MIN`, 0=끔). uncertain 뒤 응답기는 퇴역(FLEET-WORKER)하므로 세션 종료 → 재시작 |
| 답 길이 | 8 KiB 초과는 글자 경계에서 자르고 `…(길어서 줄임)` |
| 발신자 표기 | 응답기의 `sender` 검증이 Matrix 형식이라 `@<device>:hande` 로 넘긴다 → 프롬프트 머리글 `[가족방 메시지 · 보낸 사람: @owner-iphone-27a879:hande]` |

응답기 출력(stdout JSON)에는 승인 인수·답변 본문이 들어 있다 — 봇 stdout(이벤트 로그)에는 길이·종류만 남긴다(`agent_outbound`), 본문은 방에만 간다.

## 도구(P4, #372)

응답기(`scripts/fleet_worker.py`)가 turn 도중 봇에게 **steward 방 명령**을 부탁하는 길. 같은 JSON-lines 포트 위에 프레임 두 개가 늘었다. 방 명령은 `steward` 모드(`STEWARD.md`)에서만 실제로 실행된다 — 단일 방 `session` 모드에서는 `steward_only` 로 거절.

```
워커 → 봇 (stdout)  {"type":"tool","turn_id":"t-12","tool_id":"<nonce>","name":"room_invite","arguments":{"room":"family","device":"jungin-iphone-1b89e3"}}
봇 → 워커 (stdin)   {"type":"tool-result","turn_id":"t-12","tool_id":"<nonce>","ok":true,"result":{…Steward::execute 의 JSON, "ok":true…}}
                    {"type":"tool-result","turn_id":"t-12","tool_id":"<nonce>","ok":false,"error":"<이유>"}
```

| 규칙 | 구현 |
|---|---|
| 활성 turn 에만 | `turn_id` 가 활성 turn 과 다르거나(비어 있어도) turn 이 없으면 무시. `tool_id` 는 `[A-Za-z0-9_-]{1,128}`(아니면 무시) |
| 인수 검증 | `name` ∈ `room_create{room, mode?=silent}` · `room_join{room}` · `room_invite{room, device}` · `room_remove{room, device}` · `room_close{room}` · `room_members{room}` · `room_mode{room, mode}` · `room_status{}`. 값은 모두 문자열 `[A-Za-z0-9_-]{1,64}`, `mode` 는 `agent|silent`, 모르는 키·빠진 키는 거절 → `error:"bad_arguments"`(즉시, 방에는 안 나감) |
| **owner 만** | turn 을 시작한 메시지의 발신 기기 actor(첫 `-` 앞)가 `--owner-actor` 와 다르면 `error:"owner_only"`(즉시, 실행 없음). 가족이 "정인 넣어줘"라고 해도 봇이 방을 건드리지 않는다 — 오너가 직접 말해야 한다 |
| 한 번에 하나 | turn 당 미응답 tool 1개. 그 사이 둘째 `tool` 은 `error:"busy"` |
| 실행 | 폴 루프가 `Steward::execute` 로 실행(명령 큐 `cmd/`·`out/` 와 같은 코드, 파일은 안 거침). 실행 오류는 `ok:false, error:<execute 의 메시지>`. turn 이 끝나면(result/rejected/워치독) 미응답 tool 은 버려진다 |
| `room_invite` 로비 fallback | 상대가 그 방에 올린 key package 가 없으면 릴레이 **로비** key package(`GET /v2/lobby/keypackages`, #380 P5)로 초대한다. 결과 `result.key_source` 는 `room` \| `lobby`; 둘 다 없으면 `error: … no key package for <device> in room <room> or in the lobby (앱을 한 번 열어 로비 키를 보충하세요)` |
| 승인 문구 | 워커 쪽 승인 `action` 이 `mcp__steward__room_*` 이면 방에는 description 대신 **이름과 인수**를 보인다: `⚠️ 승인 필요 #n: 방 명령 room_invite · device=jungin-iphone-1b89e3 · room=family`(키 정렬, 값 64바이트 제한). 다른 action 은 기존 그대로 |
| 승인 없는 도구 | 워커가 `room_status`·`room_members`(읽기 전용)를 ccc-node `mcp_allowed_tools`에 넣어 방 승인 없이 실행된다(#378; `--steward-tools-approve-all`이면 전부 승인). 봇의 owner-only·busy 검사는 그대로 모든 호출에 적용된다 |
| inbox | `<state>.inbox.json` 의 활성 turn 에 `sender_device` 가 추가됐다(owner 판정용). 없는 옛 파일도 그대로 읽힌다(version 1 유지) |

이름 → steward 명령: `room_create→create <room> [mode]` · `room_join→join <room>` · `room_invite→invite <room> <device>` · `room_remove→remove <room> <device>` · `room_close→close <room>`(#389 — agent 모드 방·pending commit 은 거절) · `room_members→members <room>` · `room_mode→mode <room> <mode>` · `room_status→status`(room 자리는 `-`).

## 이벤트 (stdout JSON lines)

`agent_started` · `agent_offer{seq, from, outcome}` · `agent_skipped{seq, reason}` · `agent_approval_reply{n, allow, known}` · `agent_outbound{kind, bytes}`(kind: `reply`·`interim`·`notice`·`approval_request`·`approval_resolved`·`uncertain` — #474 `interim`/`notice` 는 [FLEET-WORKER](../../../docs/FLEET-WORKER.md) 선택 출력 프레임) · `agent_outbound_dropped{reason}` · `agent_worker_gone{reason}` · `agent_tool{name, op, room, arg, ok, key_source?}`(P4: 실행 요약만 — 기기·방 식별자, 본문 없음; `key_source` 는 invite 성공 때만 `room`\|`lobby`, #380 P5)

## 바꾸지 않은 것

MLS·정책 검사·상태 파일·ack·정지(⛔) 로직은 0줄 변경. 릴레이 서버 변경 0. 답 메시지의 릴레이 `client_id` 는 echo 와 같은 `<device>-echo-<n>`(iOS·웹·다른 봇이 echo 와 똑같이 다룬다).
