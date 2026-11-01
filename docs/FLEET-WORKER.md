# 노드 실행부의 상주 JSON 포트

`scripts/fleet_worker.py`는 신뢰된 부모 프로세스의 stdin/stdout으로 ccc-node
AgentRuntime에 연결한다. Telegram/Matrix 접속이나 새 네트워크 리스너는 만들지 않는다.
런타임 시임은 ccc-node의 정식 인터페이스 `telegram_bot.contracts`(ccc-node #1756)를
우선 사용하고, 그 이전 체크아웃에서는 하위 호환 shim인 `telegram_bot.core` 경로로
자동 폴백한다 — 혼합 플릿 롤아웃에서도 노드 포트가 깨지지 않는다.
CLI 바인딩은 Telegram 브리지와 **같은 ccc-node `CodexRuntime`**이다. 플래그 없이 실행하면
시험용 기본값(빈 작업 폴더·read-only·approval=never·메모리 미주입)이고, 아래 하네스
플래그를 주면 그 노드의 Telegram 경로와 같은 하네스(AGENTS.md·메모리 materializer·
working-state·승인 정책)에 붙는다. 다른 provider의 실행 정책은 아직 구현되지 않았다.

노드의 ccc-node가 설치된 Python으로 실행한다. SDK 의존성과 AI 자격 증명은
해당 노드에 유지한다. 부모가 고정된 인자로 실행하고 메시지를 셸 명령에 삽입하지 않는다.

```sh
# 시험용 기본값(기존과 동일)
/path/to/ccc-python scripts/fleet_worker.py \
  --workdir /path/to/pilot-workspace --codex-cli /path/to/ccc-codex
# 노드 하네스 바인딩(Telegram 브리지와 같은 project root·메모리)
/path/to/ccc-python scripts/fleet_worker.py \
  --workdir /root --codex-cli /path/to/ccc-codex \
  --memory-materializer /path/to/ccc-node/bridge/.../ccc_codex_memory.py \
  --working-state inherit --approval-policy on-request --sandbox workspaceWrite \
  --approval-timeout 300
```

## 하네스 플래그

| 플래그 | 기본값 | 뜻 |
| --- | --- | --- |
| `--workdir` | (필수) | Codex 작업 디렉터리. 노드 하네스에 붙일 때는 Telegram 브리지의 project root(예: `/root`)와 같게 둔다. Codex는 여기서 `AGENTS.md`·`.codex/` 설정을 읽는다. |
| `--memory-materializer` | 없음 | ccc-node의 Codex 메모리 materializer 절대 경로(브리지 `.env`의 `CCC_CODEX_MEMORY_MATERIALIZER_PATH`와 같은 파일). 없으면 메모리 미주입. |
| `--working-state` | `off` | `inherit`이면 서비스 단위 환경의 `CCC_WORKING_STATE_*` 키를 런타임에 전달한다. `off`는 archive를 끈다. |
| `--approval-policy` | `never` | Codex app-server 승인 정책(`never`·`on-request`·`on-failure`·`untrusted`). `never`가 아니면 승인 요청이 방의 `/approve`·`/deny` UI로 나간다. |
| `--sandbox` | `readOnly` | `readOnly`·`workspaceWrite`(네트워크 차단)·`dangerFullAccess`. 브리지의 bash 정책 매핑과 같은 계약이다. |
| `--approval-timeout` | `120` | 방이 `/approve`에 답할 수 있는 시간(초). 초과하면 거절로 처리한다. |
| `--model` · `--effort` | 없음 | 비우면 노드 `.codex/config.toml`의 값을 쓴다. |

부모(`fleet_matrix.py`)는 방 종류별로 다른 인자를 줄 수 있다(`worker_argv` = 개인방,
`worker_argv_family` = 가족방). 가족방은 read-only로 두고 소유자 개인방만 쓰기·승인을
여는 구성이 기본 권장이다. **`--sandbox readOnly`도 파일 시스템 전체 읽기를 허용**하므로,
하네스 root 아래의 비밀값 노출은 방 참여자 신뢰 범위로 판단한다.

## 프로토콜

입력은 UTF-8 JSON 한 줄이며 프레임 상한 64KiB다. 작업 ID는 ASCII 영문·숫자·`-_`,
1~128자다. 한 번에 작업 하나만 실행한다. 다음 입력을 기다리는 동안 작업은 별도 asyncio
task로 실행되므로 승인/취소 입력이 작업 뒤에 막히지 않는다.

- `{"type":"turn","turn_id":"job-1","prompt":"...","session_id":null,"sender":"@owner:example","room_kind":"direct"}`
  — `sender`(Matrix ID)·`room_kind`(`direct`|`family`)는 선택이며 부모가 이미 허용한 값만
  넣는다. worker는 이를 `[가족방 메시지 · 보낸 사람: @dad:example]` 머리글로 프롬프트 앞에
  붙여 모델이 공용방의 발신자를 구분하게 한다. 형식이 틀리면 `invalid-turn`으로 거절한다.
- `{"type":"approve","turn_id":"job-1","approval_id":"worker-generated-nonce"}`
- `{"type":"deny","turn_id":"job-1","approval_id":"worker-generated-nonce"}`
- `{"type":"cancel","turn_id":"job-1"}`
- `{"type":"tool-result","turn_id":"job-1","tool_id":"worker-generated-nonce","ok":true,"result":{...}}` /
  `{"type":"tool-result","turn_id":"job-1","tool_id":"…","ok":false,"error":"owner_only"}` — 아래 `tool`
  프레임의 답. `turn_id`·`tool_id`가 대기 중인 호출과 맞아야 하고(아니면 `control.accepted=false`),
  `ok`가 `true`가 아니면 거절로 본다(`error` 문자열이 없으면 `steward_error`).

### 첨부 turn — `attachment` (#636 · ccc-node#2606, 구현됨 · 양쪽 기본 off)

이 절은 결정(#636 코멘트, 2026-11-01)을 옮긴 **계약**이다. 구현: 봇 송신부 `archive/native-mls/bot/src/attachment.rs`
(+ `responder.rs` 준비 단계, `session.rs` `route_attachment`, host-core `Client::get_blob`), ccc-node 수신부
`core/hande/attachments.py`(ccc-node#2614). 계약이 바뀌면 이 절도 같은 PR에서 고친다.

한데에서 받은 file-v2/file-v1 첨부를 native-mls 봇이 복호해 노드 로컬 파일로 두고, `turn` 프레임에 선택 객체
`attachment`로 그 **경로**를 넘긴다. 파일 바이트(64KiB 프레임 상한)와 파일 키·설명자는 프레임에 싣지 않는다.

```json
{"type":"turn","turn_id":"t-agent-12","prompt":"[첨부: 사진 1개(image/jpeg, 2481920 B) — 이 실행부는 첨부를 열 수 없습니다. 받았지만 볼 수 없다고 답하세요.]",
 "session_id":null,"sender":"@owner-pc:hande","room_kind":"family","room":"agent",
 "attachment":{"v":1,"path":"/…/hande-attachments/3f9c…(32 hex).bin","kind":"image","mime":"image/jpeg",
               "name":"사진.jpg","size":2481920,"sha256":"<64 hex>","caption":""}}
```

| 키 | 필수 | 규칙 |
|---|---|---|
| `v` | ✓ | 정수 `1`. 다른 값이면 수신 측은 `attachment`를 **무시**하고 `prompt`로 실행한다(앞으로의 확장 대비). |
| `path` | ✓ | 절대 경로, 양쪽에 설정된 **spool 디렉터리의 직속 자식**. 파일 이름은 봇이 만든 무작위 `[0-9a-f]{32}\.bin`이고, 사용자가 준 이름이나 turn_id는 넣지 않는다. |
| `kind` | ✓ | `image` \| `file`. 판별한 `mime`이 이미지 허용 목록(ccc-node `IMAGE_EXTENSIONS`: jpeg·png·gif·webp·heic·heif·bmp·tiff)에 있으면 `image`, 아니면 `file`. |
| `mime` | ✓ | 봇이 **복호한 바이트의 매직 바이트**로 판별한 `type/subtype`. 설명자 `mime`은 쓰지 않는다(FILE-V2 §4.4). 판별하지 못하면 `application/octet-stream`. |
| `name` |  | 설명자 `name`(표시용 힌트, 신뢰하지 않음). 1~255자, 제어 문자 없음. 양방향 제어 문자가 섞였으면 키를 빼서 보낸다(FILE-V2 저장 이름 규칙). 경로를 만들 때는 쓰지 않는다. |
| `size` | ✓ | 평문 바이트 수 = 파일 크기, `1..`봇 상한. |
| `sha256` | ✓ | **평문**의 sha256(소문자 hex 64자). 설명자 `blob`(암호문 해시)과는 다른 값이다. |
| `caption` | ✓ | 사용자 지시문(`prompt`와 같은 신뢰 수준의 사람 글, 8,000 B 이하). 클라이언트에 캡션 입력이 없어 **봇이 채운다**(2단계): 오너 첨부를 `caption_secs`(기본 10초) 동안 보류하고, 그사이 같은 방·같은 actor 의 **일반 텍스트**(빈 글·`/` 명령 아님 — 승인 답장·`/stop` 은 그 전에 따로 처리)가 오면 그 글을 캡션으로 묶어 turn 하나로 보낸다(turn 은 첨부의 seq, 저널 `agent_caption`). 창이 끝나거나 다른 사람의 글·명령·다음 첨부가 오면 보류분을 캡션 없이(`""`) 먼저 보낸다 — 도착 순서는 유지. 빈 문자열이면 수신 측의 기본 지시문을 쓴다. |

모르는 키는 무시한다. `attachment` JSON은 2KiB를 넘지 않는다(프레임 전체 64KiB 상한은 그대로다).

**`prompt` 대체 문구.** 옛 `fleet_worker.py`·`native-responder`·ccc-node는 모르는 키 `attachment`를 무시하고
`prompt`만으로 턴을 실행한다. 그래서 봇은 첨부 턴의 `prompt`에 위 예처럼 "첨부를 받았지만 열 수 없다"는 문구를
넣는다. 첨부를 받아들이는 수신 측은 이 문구를 버리고, `attachment`와 `caption`으로 이미지/문서 프롬프트를 만든다
(ccc-node `build_image_prompt`·`build_document_prompt`, channel `Hande`).

**파일 수명과 소유권** — 같은 파일을 지우는 쪽은 언제나 하나다.

1. 봇: 큐에는 설명자만 메모리에 둔다(대기 중인 첨부는 파일을 만들지 않는다). **턴을 시작할 때** poll loop 밖의
   스레드에서 blob을 받고 FILE-V2 §4 순서로 확인한다: 길이 `size+16` → sha256 = `blob` → AES-256-GCM 복호(AAD
   `hande-file-v2`) → 평문 길이 = `size`. 그다음 spool에 `O_CREAT|O_EXCL|O_NOFOLLOW`, 0600으로 쓰고 fsync한 뒤
   프레임을 보낸다. file-v1(MLS에 들어 있는 평문)은 받기·복호 단계를 건너뛴다. 받기·확인이 실패하면 턴을 시작하지
   않고 방에 고정 문구를 하나 올린다.
2. 수신 측(받아들일 때): 아래 검증을 통과하면 파일을 자기 0700 staging 디렉터리로 `rename`해 **소유권을 가져가고**,
   턴이 끝나면(완료·취소·오류) 지운다. `EXDEV`(다른 파일시스템)면 복사하지 않고 실패로 처리한다.
   검증: spool 직속 자식인지, 심볼릭 링크 없음(`O_NOFOLLOW`), 일반 파일, 같은 uid, 모드 0600, 크기 = `size`,
   sha256 = `sha256`, 자기 한도 이하(ccc-node는 Matrix와 같은 `max_document_size_mb`·`image_context_guard` 설정).
3. 봇: 그 턴이 `result`·`uncertain`·worker 종료로 끝났을 때 spool 파일이 아직 있으면 지운다(`ENOENT`는 정상).
   봇이 시작할 때 spool을 비운다.
4. 설명자 원문·파일 키·blob id는 봇 메모리 밖으로 나가지 않는다. 프레임, 저널, `<state>.inbox.json` 모두 금지다.
   저널에는 `kind`·`size`·평문 sha256 앞 12자만 남긴다.

**수신 측 응답.** `attachment`의 형식이 틀리면(타입·필수 키·경로 규칙) `{"type":"rejected","turn_id":…,"reason":"invalid-attachment"}`로
답한다. 파일 단계 실패(없음·크기/sha 불일치·한도 초과·`EXDEV`)는 모델을 부르지 않고, Matrix 첨부 실패와 같은 고정
문구로 `result`(`complete`)를 돌려준다. 이미지를 볼 수 없는 런타임도 막지 않는다. 프롬프트의 "볼 수 없으면
그렇다고 말하라" 문구로 처리한다(Telegram·Matrix와 같다).

**게이트와 켜는 순서.**

- 봇: 첨부 전달 플래그 `NATIVE_MLS_BOT_AGENT_ATTACHMENTS=1`(기본 off)·spool 경로 `NATIVE_MLS_BOT_ATTACHMENT_SPOOL`
  (절대 경로, 켜면 필수)·상한 `NATIVE_MLS_BOT_ATTACHMENT_MAX_BYTES`(기본 10,000,000 B, ccc-node `max_document_size_mb` 기본값과
  같다, 최대 50 MiB)·캡션 창 `NATIVE_MLS_BOT_ATTACHMENT_CAPTION_SECS`(기본 10, 0 = 보류 없이 바로, 최대 120). 대체 문구
  `prompt` 끝에는 캡션이 한 줄 붙는다(옛 실행부도 사람의 질문은 본다). 준비(받기·복호·spool)가 끝나기 전의 `/stop` 은 워커에 `cancel` 을 보내지 않고 `⏹️` 로 끝낸다.
  저널: `agent_attachment`(`outcome=ready` + kind·mime·size·sha256 앞 12자, 또는 `outcome=failed` + reason). 설명자 `size`가 상한을 넘으면 **받지 않고** `agent_skipped`(`reason=attachment_oversize`)와 고정 문구로 처리한다.
  1단계는 **`owner_actor` 발신만** 전달한다. 다른 actor의 첨부는 지금처럼 `agent_skipped`(`reason=attachment`)로 둔다.
- ccc-node 한데: `attachment_frames`(기본 `false`)와 spool 경로. 꺼져 있으면 `attachment`를 무시하고 `prompt`로
  실행하며, 파일은 3번에 따라 봇이 지운다.
- 봇과 브리지는 **같은 파일시스템**이어야 하고 두 쪽의 spool 경로가 같아야 한다. Termux(공융·대교)는 한 uid 라 파일
  0600. Linux systemd 노드는 봇(`native-relay-bot`)과 브리지(root 또는 그 그룹 사용자)가 달라, spool 을 봇 소유·그룹
  `native-relay-bot`·2770 디렉터리(`/var/lib/native-relay-bot/attachments`, 봇 유닛 `ReadWritePaths`)로 두고 파일은
  디렉터리를 따라 0640 이 된다. 브리지는 spool 디렉터리 소유자 uid 의 0600/0640 파일을 받고, *other* 가 쓸 수 있는 spool 은
  거부한다(ccc-node#2625). 설치: `bot/deploy/install-node-bot.sh --attachments`.
- 켜는 순서는 **브리지 교체·`attachment_frames` → 봇 교체·플래그**다. interim과 반대인데, 여기서는 봇이 보내는
  쪽이기 때문이다. 끄는 순서는 반대다.

### 도구 프레임 — `--steward-tools` (#372 P4, `--provider claude` 전용)

worker는 in-process SDK MCP 서버 `steward`로 방 운영 도구 `room_create / room_join /
room_invite / room_remove / room_close / room_members / room_mode / room_status`를 모델에 노출한다
(모델이 보는 이름은 `mcp__steward__room_invite` 꼴). 모델이 도구를 부르면 worker는 **실행하지
않고** 부모에게 묻는다:

- 출력 `{"type":"tool","turn_id":"job-1","tool_id":"worker-generated-nonce","name":"room_invite","arguments":{"room":"family","device":"jungin-iphone-1b89e3"}}`
  — 인수는 `[A-Za-z0-9_-]{1,64}` 문자열만, 도구별 필수/선택 인수 밖의 키는 보내지 않고
  `bad_arguments`로 모델에 돌려준다(`room_status`는 인수 없음). 한 turn에 도구 호출은 한 번에
  하나(겹치면 `busy`), 활성 turn이 없으면 `no_active_turn`.
- 부모(native-mls 봇)가 **발신 actor가 owner인지** 검사하고 steward 명령을 실행한 뒤
  `tool-result`로 답한다. `--tool-timeout`(기본 90초) 안에 답이 없으면 `steward_timeout`.
  취소(`cancel`)는 대기 중인 도구 호출을 `cancelled`로 닫는다.
- 결과는 MCP 텍스트(JSON 한 줄)로 모델에 돌아간다. `ok=false`면 `is_error`.

권한: `--claude-permission-mode default`면 **변경 도구**(`room_create / room_join / room_invite /
room_remove / room_close / room_mode`) 호출마다 SDK `can_use_tool` → 이 포트의 `approval` 왕복(방의
`⚠️ 승인 필요 #n`)이 먼저 일어나므로 오너가 명령마다 확인한다. **읽기 전용 도구**
`room_status`·`room_members`는 부수 효과가 없어 기본으로 승인 없이 실행된다(#378): worker가
`SessionRequest.mcp_allowed_tools=["mcp__steward__room_status","mcp__steward__room_members"]`를
넘기고 ccc-node가 이를 SDK allow-list에 넣는다(ccc-node는 호출자 자신의 서버 도구만 받으므로
`Bash`나 다른 번들 도구는 이 경로로 열 수 없다). 봇의 owner-only 검사는 승인 유무와 무관하게
모든 호출에 적용된다. 전부 승인받게 하려면 `--steward-tools-approve-all`.
`--steward-tools`는 ccc-node `SessionRequest.mcp_servers`(ccc-node #2340)가, 읽기 전용 승인 생략은
`mcp_allowed_tools`(ccc-node #2345)가 있어야 하며, 없으면 시작 시 `ValueError`로 멈춘다(조용히 다른
동작으로 뜨지 않는다).

부모는 Matrix 발신자·방 허용 목록을 먼저 검사한다. 승인도 요청을 받은 동일한
계정/방/발신자에게만 라우팅한다. 이 프로토콜 자체는 네트워크 인증 수단이 아니다.
프로세스 재시작 뒤의 오래된 승인과 작업 ID만 맞는 승인은 수락하지 않는다.
승인 인수가 너무 크면 잘라서 보여주지 않고 거절한다. 미응답 승인은 기본 120초 후 거절한다.

출력은 `session`, `approval`, `approval-resolved`, `control`, `rejected`, `result`, 그리고
`--steward-tools`일 때 `tool` 이벤트다.

선택 출력 프레임(#474) — native-mls 봇은 아래 두 프레임을 방에 게시한다. 보내는 쪽은 ccc-node 한데
전송층(`core/hande/transport.py`)이며 그쪽 설정 `interim_frames`·`notice_frames`(기본 `false`)를 켜야
나간다. 이 기능이 없는 옛 봇은 두 프레임을 무시하므로(모르는 `type`) 켜는 순서는 **봇 교체 → 브리지 설정**이다.

- `{"type":"interim","turn_id":"t-12","text":"…"}` — 진행 중인 turn의 중간 출력(진행 상황 말풍선).
  활성 turn과 `turn_id`가 같을 때만, 공백뿐인 본문은 버린다. 답과 같은 경로·같은 크기 상한(`reply_max_bytes`,
  8KiB)으로 agent 방에 게시하고 turn은 `result`까지 계속된다. turn당 최대 40건(`DEFAULT_INTERIM_MAX`),
  넘는 것은 버린다(최종 `result`는 그대로 온다).
  - `"kind":"status"` (status-v1, family-messenger#560, `archive/native-mls/STATUS-V1.md`): 브리지의 작업 상태
    한 줄(`⏳ Working — 10s | Bash: …`, 매트릭스가 한 말풍선을 덧쓰는 그 줄)이다. 봇은 이것을 일반 interim 과 **다른
    경로**로 게시한다 — 릴레이 `client_id` 가 `status-<uuid>`(앱은 보낸이별 임시 말풍선 하나로 갱신, 릴레이는 푸시
    안 함), 턴당 상한 `DEFAULT_STATUS_MAX`(720)는 `interim_max` 와 별도, 409 는 재시도하지 않는다(다음 heartbeat 가
    대체). 모르는 `kind`(또는 없음)는 일반 interim 이다 — 옛 봇은 `kind` 를 무시하므로 켜는 순서는 **봇 교체 → 브리지
    `status_frames`**. 저널 `agent_outbound` `kind=status`, 게시 결과 `status_posted` / `status_dropped`.
- `{"type":"notice","room":"soonwook","text":"…"}` — turn과 무관한 노드 발신(푸시 알림·리마인더·경보).
  활성 turn이 없어도 받는다. `room`은 릴레이 식별자 규칙 `[A-Za-z0-9_-]{1,64}`, 본문이 비면 버린다.
  봇은 **agent 방과 이름이 같을 때만** 게시하고 다른 방은 침묵한다(B-H3, 저널 `agent_outbound_dropped`
  `reason=notice_not_agent_room`).
  - `"kind":"status"` (ccc-node#2590, `archive/native-mls/STATUS-V1.md` §1·§2): turn 밖의 상태 한 줄 — 브리지가
    턴이 끝난 뒤에도 남은 백그라운드 대기(CI·빌드)를 `⏳ 대기 중 · …` 로 보인다. 봇은 일반 notice 가 아니라
    status-v1 경로(`Outbound::StatusNotice` → 릴레이 `client_id` `status-<uuid>`, 저장·푸시 없음)로 게시한다.
    활성 turn 이 있어도 그대로 게시한다. 라우팅은 notice 와 같되 **agent 방만**(alert 방에는 게시하지 않음).
    방마다 **20초에 1건**(`DEFAULT_STATUS_NOTICE_MIN_SECS`)까지, 넘으면 버린다(저널 `agent_outbound_suppressed`
    `kind=status_notice_rate`). 일반 notice 의 분당 상한(`notice_per_min`)과는 별개다. 앱은 5분 갱신이 없으면
    말풍선을 지우므로 브리지는 대기가 남아 있는 동안 ≤2분마다 다시 보낸다. 모르는 `kind` 는 일반 notice 다 —
    옛 봇은 `kind` 를 무시하고 글로 게시하므로 켜는 순서는 **봇 교체 → 브리지 설정**. 저널 `agent_outbound` `kind=status`.

저널: 게시된 두 프레임은 `agent_outbound`의 `kind`가 `interim`·`notice`로 남는다. 입력 중 표시(typing)는
이 포트에 없고 봇은 릴레이 typing(#562)도 보내지 않는다. iOS `AgentThinking`은 타임라인만 보고 추정하므로
「…의 답 기다리는 중」(기다림)으로만 표시한다 — 작업 중 신호는 status-v1 이다(#560, #601).
JSON escaping으로 출력 프레임은 입력보다 클 수 있으므로 부모는 최대 512KiB까지
읽되 상한 초과를 오류로 처리한다. stdout에는 요청에 대한 응답/승인 인수가 포함될 수 있으므로
일반 로그로 복사하지 않는다. 연결부는 암호화된 원래 방에 전달한다.

성공은 `result.status=complete`와 본문·session_id로 전달된다. 취소·시간 초과·provider 오류·
터미널 이벤트 누락은 `uncertain`이며 작업의 부수 효과가 없었다거나 취소가 모두 되돌렸다는 뜻이 아니다.
취소·시간 초과·실행 오류는 모두 해당 worker를 폐쇄하고 runtime 종료를 시도한다.
`interrupt()`가 정상 반환해도 turn/start 응답 전에는 실제 중단을 뜻하지 않을 수 있으므로
이 worker에서 다음 작업을 받지 않는다. 종료 시도 실패는 `runtime_closed=false`로 보고한다. 결과를 확인한 뒤 부모 inbox에서
조정하며 자동 재실행하지 않는다. stdin EOF/잘못된 프레임은 진행 작업 중단 및 runtime 종료로 이어진다.
provider 이벤트 iterator를 먼저 취소하지 않고 shield된 실행부에 실제 interrupt를 보낸 후 정리한다.
중복 취소/EOF는 이미 진행 중인 정리를 다시 취소하지 않는다. stdout은 비차단 pipe이며
5초 이내에 출력할 수 없으면 연결을 중단해 부모의 출력 정체가 프로세스 종료를 막지 않도록 한다.

부모는 `session` 이벤트를 영구 기록하되, 이 포트에는 실행 전 확인 응답(handshake)이 없으므로
이를 실행 효과의 exactly-once 보장으로 해석하지 않는다. 앞 단계 inbox의 running/uncertain
기록이 실행 재처리 방지의 기준이다. 서로 다른 대화의 session_id를 전달하지 않는 것은 부모의 책임이다.

## Rust 응답기 `native-responder` (#396)

위 포트를 Python `fleet_worker.py` 대신 **Rust 바이너리** `native-responder`
(`archive/native-mls/bot/src/bin/native-responder/`)가 말할 수 있다. 부모 쪽 프레임·검증·오류 코드는
이 문서 그대로이므로 봇(`--responder-unix`/`--responder-argv-json`)과 `fleet_matrix.py`(`worker_argv`)는
바뀌지 않는다. 플래그도 같고, `--adapter-argv-json`(또는 env `NATIVE_RESPONDER_ADAPTER_ARGV_JSON`) 하나가 늘었다.

| 맡는 쪽 | 내용 |
| --- | --- |
| Rust `native-responder` | 프레임 상한·검증(작업 ID·발신자·방 종류·본문), 한 번에 한 작업(`busy`), 발신자 머리글, 작업/승인/도구 타임아웃, 승인·도구 nonce와 작업 일치 검사, 과대 승인 거절, steward 도구 인수 검증과 읽기 전용 allow-list(#378), `uncertain` 뒤 퇴역, 출력 5초 정체 중단, 하네스 플래그 검증(`harness_options`와 같은 결과) |
| Python `scripts/ccc_adapter.py` | ccc-node 런타임 import(정식 시임 → core 폴백), `start_or_resume`/`send_turn` 이벤트 중계, SDK 승인 콜백과 in-process steward MCP 핸들러를 Rust에 되묻기, `interrupt`(5초)·`close`(10초), 구 ccc-node fail-closed 검사(`mcp_servers`·`mcp_allowed_tools`) |

어댑터는 정책이 없다 — 받는 `configure` 프레임(런타임·세션 인수, 도구 표·설명·allow-list)을 그대로 쓴다.
`fleet_worker.py`는 롤백 경로로 남아 있다(공명 실기기 검증 뒤 별도 PR에서 정리).

### 어댑터 프로토콜 (Rust ↔ `ccc_adapter.py`, stdio 파이프, JSON 한 줄)

- Rust → 어댑터: `configure{protocol:1, provider, runtime_options, request_options, steward}` (처음 한 번) ·
  `turn{prompt, session_id}` · `approval-decision{request_id, allow}` · `tool-result{request_id, result}`(MCP 결과 dict) ·
  `interrupt` · `close`
- 어댑터 → Rust: `ready{protocol}` 또는 `fatal{reason}` · `session{session_id}` · `text{text}` · `completion{stop_reason}` ·
  `error` · `turn-end{session_id}` · `turn-failed` · `approval-request{request_id, action, description, arguments}` ·
  `tool-call{request_id, name, arguments}` · `interrupted{ok}` · `closed{ok}`

런타임 오류 문구는 어댑터 밖으로 나가지 않는다(`error`·`turn-failed`에 본문 없음, stderr는 journal).
`ready`가 120초 안에 오지 않거나 `fatal`이면 Rust는 프레임 하나 받지 않고 exit 1로 끝난다(구 ccc-node + `--steward-tools`가 이 경우).
불확실 종료 순서는 Python과 같다: 대기 승인 거절·도구 `cancelled` → `interrupt` → `close` → `result uncertain`(`runtime_closed`=close 성공 여부, 11초 무응답 = false) → exit 1.

검증: `cargo test --bin native-responder`(상태 기계·하네스·와이어 36건), `tests/test_ccc_adapter.py`(어댑터 단위),
`tests/test_native_responder.py`(실제 바이너리 + 실제 어댑터 + 가짜 ccc-node, 파이프·socketpair stdio — CI `native-mls-bot` job).

## 검증 범위와 다음 단계

단위 검사: 동시 입력·busy, nonce/작업 ID 일치, 승인 재사용 거절, 명시적 거절/만료,
승인 중 취소, oversized/잘못된 프레임, provider 오류/부분 완료/답변 크기 초과,
EOF 정리, 중단 실패 후 새 작업 거절.

계속 구현할 부분: 상시 Matrix 수신·crypto/sync 복구, 인증된 승인 UI, room membership,
첨부 스트리밍, 상태(입력 중) 표시(중간 응답은 #474 `interim`), 모델/메모리/사용량 정책의 기존 Telegram 경로와의
동등성, 다른 provider와 전체 플릿 배포. 운영 서비스에는 아직 설치하지 않는다.
