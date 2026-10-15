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
- 응답기 바인딩: `fleet_worker.py --provider codex`(기본, CodexRuntime) 또는 **`--provider claude`**(ccc-node `ClaudeRuntime`, `--model claude-opus-5-5 --effort high --claude-permission-mode default`; 브리지 venv 파이썬 필요). 공명 운영은 Claude(2026-10-15 오너 결정 — ChatGPT 계정 Codex 가 `*-sol` 모델을 거부함).
- `--owner-actor`(env `NATIVE_MLS_BOT_OWNER_ACTOR`, 기본 `owner`): 승인 답장을 낼 수 있는 actor(기기 ID 의 첫 `-` 앞).
- 응답기가 죽으면 세션도 끝난다(exit 1) — 서비스 매니저가 봇·응답기를 함께 다시 띄운다(`Restart=on-failure`).

## 동작 규칙 (오너 결정 2026-10-15, #354)

| 규칙 | 구현 |
|---|---|
| ②-B 모든 메시지에 반응 | 멘션 게이트 없음. 응답기가 빈 답을 주면 전송 없음 |
| 봇끼리 루프 방지 | actor 가 `bot` 으로 시작하는 발신 무시(`agent_skipped: bot_actor`) + 기존 `*-echo-<n>` 무시 |
| 첨부 무시 | `client_id` 가 `file-v1-<uuid>` 면 무시(`agent_skipped: attachment`) |
| ③-B 가족 허용 | `bot*` 를 뺀 모든 actor 의 메시지가 turn 이 된다. 실행 권한은 아래 승인으로만 |
| ④-B 승인 왕복 | 응답기 `approval` → 방에 `⚠️ 승인 필요 #n: …` → **owner actor 의 답장** `승인 n` / `거절 n`(`approve n`/`deny n`) 만 유효 → 응답기 `approve`/`deny`. 미응답은 응답기 `--approval-timeout` 이 거절 |
| 동시성 | 한 번에 1 turn, 대기열 8(초과는 `agent_offer: Dropped{queue_full}`) |
| 중복 실행 금지 | 활성 turn 을 `<state>.inbox.json`(0600)에 **응답기에 보내기 전** 기록. 재시작 때 남아 있으면 `⚠️ 요청(#seq)을 끝까지 확인하지 못했습니다` 1건만 게시하고 지운다 — 재실행 없음 |
| 불확실 결과 | `result.status=uncertain`·`rejected`·워치독(1200초) → 같은 안내 1건. uncertain 뒤 응답기는 퇴역(FLEET-WORKER)하므로 세션 종료 → 재시작 |
| 답 길이 | 8 KiB 초과는 글자 경계에서 자르고 `…(길어서 줄임)` |
| 발신자 표기 | 응답기의 `sender` 검증이 Matrix 형식이라 `@<device>:hande` 로 넘긴다 → 프롬프트 머리글 `[가족방 메시지 · 보낸 사람: @owner-iphone-27a879:hande]` |

응답기 출력(stdout JSON)에는 승인 인수·답변 본문이 들어 있다 — 봇 stdout(이벤트 로그)에는 길이·종류만 남긴다(`agent_outbound`), 본문은 방에만 간다.

## 이벤트 (stdout JSON lines)

`agent_started` · `agent_offer{seq, from, outcome}` · `agent_skipped{seq, reason}` · `agent_approval_reply{n, allow, known}` · `agent_outbound{kind, bytes}` · `agent_outbound_dropped{reason}` · `agent_worker_gone{reason}`

## 바꾸지 않은 것

MLS·정책 검사·상태 파일·ack·정지(⛔) 로직은 0줄 변경. 릴레이 서버 변경 0. 답 메시지의 릴레이 `client_id` 는 echo 와 같은 `<device>-echo-<n>`(iOS·웹·다른 봇이 echo 와 똑같이 다룬다).
