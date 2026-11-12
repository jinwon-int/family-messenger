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
- **첨부 turn**(#636, 기본 끔): env `NATIVE_MLS_BOT_AGENT_ATTACHMENTS=1` + `NATIVE_MLS_BOT_ATTACHMENT_SPOOL=<절대 경로>`(ccc-node 한데 `attachment_spool_dir` 와 **같은 문자열**), 선택 `NATIVE_MLS_BOT_ATTACHMENT_MAX_BYTES`(기본 10000000)·`NATIVE_MLS_BOT_ATTACHMENT_CAPTION_SECS`(기본 10, 0 = 끔: 오너 첨부를 그 초만큼 보류하고 같은 사람의 다음 일반 텍스트를 캡션으로 묶어 turn 하나로). 봇과 브리지가 **같은 파일시스템**이어야 한다(브리지는 `rename` 으로 파일을 가져간다). Termux 는 한 uid·0600. Linux systemd 노드는 `deploy/install-node-bot.sh --attachments`(또는 같은 drop-in·디렉터리)로 봇 소유·그룹 `native-relay-bot`·2770 spool(`/var/lib/native-relay-bot/attachments`)을 쓴다 — 파일은 디렉터리를 따라 0640, 브리지(root 또는 그 그룹 사용자)는 spool 소유자 uid 와 0600/0640 을 받는다(ccc-node#2625). 켜는 순서: ccc-node `attachment_frames` → 이 플래그. 계약 `docs/FLEET-WORKER.md` "첨부 turn".
- **나가는 첨부**(#761, 기본 끔): env `NATIVE_MLS_BOT_AGENT_ATTACHMENTS_OUT=1` — 워커의 `attachment` 출력 프레임(브리지가 spool 에 쓴 `out-<32 hex>.bin`)을 봇이 `O_NOFOLLOW` 로 읽어 확인(일반 파일·other 쓰기 불가·크기·평문 sha256·상한) → 매직 바이트로 MIME 재판별 → 새 키·nonce 로 AES-256-GCM(FILE-V2 §2) → `POST /v2/rooms/{room}/blobs`(응답 `id` = sha256(암호문) 확인) → 그 turn 의 agent 방에 설명자를 `file-v2-<uuid>` 로 게시하고 같은 연결로 `attachment_ack` / `attachment_nack{reason}` 를 돌려준다. spool·상한은 들어오는 첨부와 같은 `NATIVE_MLS_BOT_ATTACHMENT_SPOOL`·`NATIVE_MLS_BOT_ATTACHMENT_MAX_BYTES`(들어오는 첨부 플래그 없이도 켤 수 있다). 파일은 결과와 무관하게 봇이 지우고, 시작할 때 `out-*.bin` 을 비운다. 첨부를 처리하는 동안 그 뒤의 워커 프레임(interim·`result`)은 읽지 않으므로 방에는 첨부가 답보다 먼저 보인다. turn 당 4건(`DEFAULT_ATTACHMENT_OUT_MAX`). 켜는 순서: 이 플래그 → ccc-node `attachment_out_frames`. 계약 `docs/FLEET-WORKER.md` "나가는 첨부".
- `--room-frames`(env `NATIVE_MLS_BOT_ROOM_FRAMES=1`, #423): steward 에서 agent 방 여러 개 — `turn` 에 `room`, 답은 요청 온 방으로. 규칙표는 `STEWARD.md` "여러 agent 방".
- **입력 중 표시**(#562 봇 쪽, 기본 켬; 끄기 `--no-typing` 또는 env `NATIVE_MLS_BOT_TYPING=0`): Telegram `sendChatAction(typing)`·Matrix `m.typing` 과 같은 모델 — turn 이 답을 만드는 동안 폴 루프가 그 turn 의 방에 릴레이 `POST /v2/rooms/{room}/typing {"device":"<봇 기기>","clear":false}`(웹 `room.js` `typing()` 과 같은 본문, 같은 CF Access 헤더)를 turn 시작 즉시, 이후 4초마다 보낸다(릴레이 TTL `TypingTTLSeconds` 6초 미만, 갱신 하한 1초 이상) → 가족 앱 방 제목 옆에 「공명이 타닥타닥…」. 릴레이는 봇의 새 application 이벤트(답·interim·status-v1 ⏳ 줄·승인 요청)가 저장되면 그 기기의 신호를 스스로 지우므로, turn 이 계속되면 그 라운드에 바로 다시 켠다. 멈춤: 답 게시(`reply`)·불확실/중단 줄(`uncertain`·`stopped`)·빈 답으로 끝(`turn_end`)·**승인 요청을 올리고 owner 답을 기다리는 동안**(`approval`, 승인 처리 뒤 워커가 계속하면 다시 켬)·`/stop` 처리 중(`stop`)·방이 agent 모드가 아니거나 halted(`room_unavailable`)·워커 사망(`worker_gone`)·세션 종료(`shutdown`). 게시로 이미 지워진 경우가 아니면 멈출 때 `{"clear":true}` 를 한 번 보낸다(실패해도 TTL 로 사라짐). peer turn(#425)은 답이 안 나가므로 표시하지 않는다. 호출은 best-effort: 실패는 turn 당 한 줄(`typing_failed`, 오류 코드만·본문 없음), 거절(4xx·옛 릴레이의 404)이나 일시 오류 3회 연속이면 그 turn 은 더 보내지 않는다 — turn 을 실패시키거나 재시도 폭주하지 않는다.
- 플릿 알림방(#425): `alert` 모드 방에서 `<방>.peers` 에 있는 봇의 `[alert:<actor>]` 글만 읽기 전용 turn(답 없음). 규칙은 `STEWARD.md` "플릿 알림방의 봇끼리 메시지".

## 노드에 설치하기 (플릿 롤아웃, #420 ⑥ / ccc-node #2380)

노드마다 **봇 기기 1개 + 방 1개**: `deploy/install-node-bot.sh --node <node> --relay-url http://<릴레이 tailnet>:18921 --relay-public-url https://<릴레이 호스트> --binary <native-mls-bot 빌드> --token-env /root/.config/native-relay/bot-service-token.env` (root). 사용자·디렉터리·바이너리·JWT 갱신 타이머·steward 유닛(`<node>-bot`, actor = `<node>`)·응답기 drop-in(`/run/ccc-hande/responder.sock`, ccc-node 브리지가 서빙)을 만들고, **신원을 부트스트랩**하고(steward 모드는 identity 파일을 만들지 않고 읽기만 하므로, 8초 한도의 `session` 1회 실행으로 state 파일을 만든 뒤 `extract-identity`로 `bot/identity.json`을 뽑고 state는 파기 — 기존 파일이 있으면 유지), 봇의 `steward_ready` 로그에서 공개키를 읽어 등록 후보 JSON을 `/var/lib/native-relay-bot/bot/enrollment.json`(0600)에 쓴다 — 릴레이 운영자가 `native-devices -enroll-first`에 넣는다(승인). 등록 전 봇은 403을 받으며 재시도한다(정상). 응답기(ccc-node `CCC_CHANNEL=hande`)는 ccc-node `scripts/install-hande-bridge.sh`가 세운다. 되돌리기: `systemctl disable --now native-relay-bot native-relay-jwt-refresh.timer`.

## 바이너리 교체 (플릿 롤아웃 — `deploy/native-mls-bot-swap` · `deploy/native-mls-bot-fleet`)

새 봇 빌드를 노드에 올리는 정본(#676·#703·#731+#733 임시 스크립트를 일반화). **바이너리만 바꾸고 봇만 재시작**한다 — 브리지·설정 무변경. 노드 교체도 봇 재시작이라 **오너 승인 뒤에만** 돌린다(파일럿 1노드 → PASS 확인 → 나머지).

1. **빌드**(main 의 깨끗한 클론, toolchain 은 `rust-toolchain.toml`): `cargo build --release --locked --bin native-mls-bot` → x86_64-gnu. Termux 는 `CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld cargo build --release --locked --bin native-mls-bot --target aarch64-unknown-linux-musl`(정적). 스테이징 디렉터리에 파일명에 `x86_64-gnu`·`aarch64-musl` 이 들어가게 두고 `sha256sum native-mls-bot-* > SHA256SUMS`. CI 는 릴리스 바이너리를 내보내지 않는다.
2. **표식**: 새 빌드에만 있는 고정 문자열 하나(새 기능의 리터럴 — 예 #733 `watchdog_max`)를 골라 `grep -ac` 로 새 바이너리 ≥1·현재 운영 바이너리 0 을 확인한다(일부 리터럴은 다른 문자열과 붙어 grep 에 안 잡힌다).
3. **드라이버**(세션과 분리해 실행, 실행마다 새 로그 파일): `ORDER="<노드>" systemd-run --unit <이름> --collect bash -c 'deploy/native-mls-bot-fleet <stage-dir> <표식> >> <새 로그> 2>&1; echo EXIT=$? >> <새 로그>'`. `--dry-run` 이 노드별 계획(모드·바이너리·sha·환경)만 찍는다. `ORDER` 항목 `<ssh 대상>[:옵션…]` — `runit`(Termux) · `extra=<유닛+유닛>`(같은 파일을 쓰는 다른 봇, 예 gwakga `extra=hande-bunjang-bot`) · `bridge_user=<사용자>`(브리지가 사용자 유닛, 예 gongmyoung) · `bin=` · `unit=` · `idle=0`(브리지 없는 알림 전용 봇).
4. **노드에서**(`native-mls-bot-swap <staged> <sha256> [<표식>]`, 드라이버가 보내 분리 실행): sha·표식 확인 → 브리지 유휴 게이트(health.json `turn_occupancy` 가 occupied 아님 10초×2 연속, 최대 30분 — 못 보면 무변경 `ABORT_BUSY`) → 백업 `<bin>.old-<sha16>` → **임시 파일 + rename**(실행 중인 파일에 쓰면 ETXTBSY) → 봇(+`extra`) 재시작 → 새 PID·`/proc/<pid>/exe` sha·재시작 뒤 로그의 `"joined":true`+`"halted":false`·브리지 active(PID 변경은 WARN) → 실패 시 같은 방식으로 되돌림(`ROLLED_BACK`). 마지막 줄 `RESULT=PASS|UNCHANGED|ABORT_BUSY|ROLLED_BACK|ROLLBACK_FAILED|ABORT_*`.
5. **드라이버 규칙**: PASS·UNCHANGED → 다음 노드, ABORT_BUSY → 끝에서 1회 재시도, 그 밖 → 그 자리 HALT(남은 노드 무변경). 마지막 줄 `FLEET_EXIT=PASS|PARTIAL_BUSY|HALT`. 노드 로그 `~/.ccc-node/state/native-mls-bot-swap.log`.
6. **확인·기록**: 끝난 뒤 노드마다 `/proc/<MainPID>/exe` sha 를 직접 다시 보고, 노드별 표(이전·새 sha, 봇·브리지 PID, 결과)를 이슈에 남긴다. 롤백은 `<bin>.old-<sha16>` 을 다시 `native-mls-bot-swap` 으로 올리면 된다.

## 동작 규칙 (오너 결정 2026-10-15, #354)

| 규칙 | 구현 |
|---|---|
| ②-B 모든 메시지에 반응 | 멘션 게이트 없음. 응답기가 빈 답을 주면 전송 없음 |
| 봇끼리 루프 방지 | actor 가 `bot` 으로 시작하는 발신 무시(`agent_skipped: bot_actor`) + 기존 `*-echo-<n>` 무시 |
| 첨부 | 기본: `client_id` 가 `file-v1-<uuid>` 또는 `file-v2-<uuid>`(#499 분리 첨부 — 설명자에 파일 키가 있어 에이전트에 절대 넘기지 않음)면 무시(`agent_skipped: attachment`). `NATIVE_MLS_BOT_AGENT_ATTACHMENTS=1`(#636, 위 "켜는 법")이면 **owner actor** 의 첨부만 turn 이 된다: 설명자 검증(실패 `attachment_invalid`)·상한(넘으면 받지 않고 `attachment_oversize` + 고정 문구) → turn 시작 때 별도 스레드가 blob 받기·검증·복호·spool → `turn.attachment` + 대체 문구 prompt. 다른 actor 첨부는 그대로 무시 |
| ③-B 가족 허용 | `bot*` 를 뺀 모든 actor 의 메시지가 turn 이 된다. 실행 권한은 아래 승인으로만 |
| ④-B 승인 왕복 | 응답기 `approval` → 방에 `⚠️ 승인 필요 #n: …` → **owner actor 의 답장** `승인 n` / `거절 n`(`approve n`/`deny n`) 만 유효 → 응답기 `approve`/`deny`. 미응답은 응답기 `--approval-timeout` 이 거절 |
| 동시성 | 한 번에 1 turn, 대기열 8(초과는 `agent_offer: Dropped{queue_full}`) |
| `/stop` (Matrix 와 같게) | 가족방의 `/stop`(앞뒤 공백·대소문자 무시, 정확히 그 한 단어)은 turn 이 아니라 **제어**다 — 대기열에 서지 않고 지금 도는 turn 에 바로 FLEET-WORKER `cancel` 을 보낸다(`agent_stop`). 그 방의 turn 만, **turn 을 시작한 사람이나 owner 만**. 결과 `uncertain/cancelled` 은 `⏹️ 요청(#n)을 중단했습니다.` 로 게시하고 응답기는 퇴역하지 않는다(ccc-node 브리지는 사용자 취소 뒤에도 계속 서빙; 스스로 끝나는 응답기는 stdout 닫힘으로 기존처럼 `worker_gone`). 대기열의 다른 메시지는 그대로 이어서 실행. 도는 turn 이 없으면 `ℹ️ 중단할 요청이 없습니다.`, 남의 turn 이면 `ℹ️ 다른 사람의 요청은 오너만 중단할 수 있습니다.` — turn 없이 즉답 |
| 중복 실행 금지 | 활성 turn 을 `<state>.inbox.json`(0600)에 **응답기에 보내기 전** 기록. 재시작 때 남아 있으면 `⚠️ 요청(#seq)을 끝까지 확인하지 못했습니다` 1건만 게시하고 지운다 — 재실행 없음 |
| 불확실 결과 | `result.status=uncertain`·`rejected`·워치독 → 같은 안내 1건. 워치독(#477)은 **침묵** 기준: 그 turn 의 마지막 프레임(interim·status·approval·tool …, 없으면 시작)부터 21780초(= Matrix `CLAUDE_PROCESS_TIMEOUT` 21720초 + 60초, env `NATIVE_MLS_BOT_TURN_SECS`) → 사유 `watchdog`. 진행 프레임을 계속 보내도 turn 전체 상한(기본 `TURN_SECS`×2, env `NATIVE_MLS_BOT_TURN_MAX_SECS`)을 넘으면 → `watchdog_max`. 워치독으로 닫은 turn(최근 4개)의 같은 `turn_id` `result{status:complete}` 가 뒤늦게 오면 `⏱ 늦게 도착한 답(#n)` 접두로 **1회** 게시(재실행 아님, 중복 result·interim 은 버림). 30분마다 「⏱ 요청(#n)을 처리한 지 N분」 알림(알림만, env `NATIVE_MLS_BOT_TURN_AGE_NOTICE_MIN`·`_RENOTICE_MIN`, 0=끔). uncertain 뒤 응답기는 퇴역(FLEET-WORKER)하므로 세션 종료 → 재시작 |
| 릴레이 재시작 | 폴링 GET의 일시 오류(#392)뿐 아니라 **답·중간보고·상태 줄 POST**의 연결 리셋/거부·502–504도 같은 바이트·같은 `client_id`로 백오프 재전송한다(최대 7회, 약 61 s — 바이트가 같은 재전송은 릴레이가 200 `duplicate`로 받는다). 그래도 실패해야 세션이 끝나고 재시작 때 위 안내가 나간다(2026-11-03 순욱 #7577) |
| 응답기 재시작(#776) | `--responder-unix` 연결이 끊기면(브리지 재시작) 봇은 **종료하지 않고** 같은 소켓에 백오프로 다시 접속한다(250 ms부터 2배, 최대 2 s 간격, 창 120 s — env `NATIVE_MLS_BOT_RESPONDER_RECONNECT_SECS`, 0 = 예전처럼 즉시 종료). 끊길 때 돌던 turn 은 `⚠️ 요청(#seq)을 끝까지 확인하지 못했습니다(responder_restart)` 1건만 게시하고 재실행하지 않는다. 끊긴 동안 온 메시지는 대기열에 섰다가(`대기 순번 n번`) 새 연결에서 차례로 시작한다. 끊긴 동안의 notice 응답은 기록만 남는다(브리지가 재접속 뒤 다시 보낸다). 창이 지나도 소켓이 없으면 예전처럼 `agent_worker_gone` → 종료 → systemd 재시작. `--responder-argv-json` 은 바뀌지 않는다 |
| 입력 중 표시(#562) | turn 이 답을 만드는 동안 `POST /v2/rooms/{room}/typing` 4초 간격(TTL 6초), 답·승인 요청·끝·중단에 멈춤. 기본 켬, `--no-typing` / `NATIVE_MLS_BOT_TYPING=0` 끔(위 "켜는 법") |
| 답 길이 | 8 KiB 초과는 글자 경계에서 자르고 `…(길어서 줄임)` |
| 답장 인용 펼치기(#728) | 본문이 ReplyQuote v2(첫 줄 `> 이름 #seq: 요약` + 빈 줄 + 답, iOS `ReplyQuote.swift` 와 같은 파싱)이고 **같은 방** seq 원문이 봇 메모리에 있으면 prompt 를 `[답장 대상 #seq · 이름]` + 원문 전체(≤8 KiB, 답 본문은 자르지 않음 — 15 KiB prompt 상한 안에서 원문을 줄임) + 빈 줄 + 답으로 바꾼다. 원문 보관: agent 모드 방마다 최근 평문 200건(건당 ≤16 KiB) **메모리 링버퍼만** — 디스크 미기록·종료 시 지움·재시작 시 소실. 받은 글(봇 포함 모든 발신, 첨부·status 줄 제외)은 해독 때, 봇 자신의 글은 릴레이 ack seq 로 기록. 못 찾으면(재시작·오래된 글·첨부·v1 `> 이름: …`) 글 그대로 — 요약 200자가 폴백. 이벤트 `agent_offer.reply_quote{seq, outcome: expanded\|miss}`(본문 없음) |
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

`agent_started` · `agent_responder_lost{reason, queued}` · `agent_responder_reconnected{attempts, after_ms, queued}`(#776) · `agent_offer{seq, from, outcome, reply_quote?}` · `agent_skipped{seq, reason}` · `agent_approval_reply{n, allow, known}` · `agent_outbound{kind=attachment, attachment{kind, mime, size}?, sha256(앞 12자), outcome, reason?, answered}`(#761 나가는 첨부 — 키·nonce·설명자·blob id·경로·이름은 남기지 않음; 게시는 `attachment_posted{seq, client_id}`, 409 는 `attachment_conflict` 뒤 다음 폴에 재게시(최대 8폴), 실패 `attachment_dropped`) · `agent_outbound{kind, bytes}`(kind: `reply`·`interim`·`status`·`notice`·`approval_request`·`approval_resolved`·`uncertain`·`queue_notice` — #474 `interim`/`notice` 는 [FLEET-WORKER](../../../docs/FLEET-WORKER.md; `status` 는 status-v1 #560 `kind:"status"` interim, `status-<uuid>` client_id 로 게시 → `status_posted{seq, client_id}` / `status_dropped{reason}`) 선택 출력 프레임; `queue_notice` 는 작업 중에 온 메시지에 봇이 직접 다는 대기 순번 안내(Matrix 동등, 문구 `⏳ 이 메시지는 대기 순번 N번에 저장되었으며 도착 순서대로 처리됩니다.` — 지금 도는 작업이 1번 — 와 대기열이 차면 `대기 중인 요청이 많습니다. 잠시 후 다시 요청해 주세요.`). 보내기 실패는 `agent_outbound_dropped{reason: queue_notice_send_failed}` 로만 남기고 세션은 계속한다) · `agent_outbound_dropped{reason}` · `notice_acked{room, id, seq}` / `notice_nacked{room, id, reason}` / `notice_answer_lost{room, id, answer, seq|reason}` / `notice_bad_id{room, bytes}`(#703: `id` 를 붙인 notice 프레임의 확인 응답 — 같은 응답기 연결로 `{"type":"notice_ack","id":…,"seq":N}` / `{"type":"notice_nack","id":…,"reason":…}` 를 쓴다, 규칙·이유 표는 [FLEET-WORKER](../../../docs/FLEET-WORKER.md) notice. 본문은 남기지 않음) · `agent_worker_gone{reason}` · `agent_tool{name, op, room, arg, ok, key_source?}`(P4: 실행 요약만 — 기기·방 식별자, 본문 없음; `key_source` 는 invite 성공 때만 `room`\|`lobby`, #380 P5) · `typing_started{room, seq}` / `typing_stopped{room, seq, reason, sent, failed, cleared}`(#562: 입력 중 표시 구간마다 한 쌍 — 호출마다 찍지 않는다) · `typing_failed{room, error}`(turn 당 최대 1줄). `agent_started` 에 `typing`(켬/끔)

## 바꾸지 않은 것

MLS·정책 검사·상태 파일·ack·정지(⛔) 로직은 0줄 변경. 릴레이 서버 변경 0. 답 메시지의 릴레이 `client_id` 는 echo 와 같은 `<device>-echo-<n>`(iOS·웹·다른 봇이 echo 와 똑같이 다룬다).
