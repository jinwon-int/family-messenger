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

부모는 Matrix 발신자·방 허용 목록을 먼저 검사한다. 승인도 요청을 받은 동일한
계정/방/발신자에게만 라우팅한다. 이 프로토콜 자체는 네트워크 인증 수단이 아니다.
프로세스 재시작 뒤의 오래된 승인과 작업 ID만 맞는 승인은 수락하지 않는다.
승인 인수가 너무 크면 잘라서 보여주지 않고 거절한다. 미응답 승인은 기본 120초 후 거절한다.

출력은 `session`, `approval`, `approval-resolved`, `control`, `rejected`, `result` 이벤트다.
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

## 검증 범위와 다음 단계

단위 검사: 동시 입력·busy, nonce/작업 ID 일치, 승인 재사용 거절, 명시적 거절/만료,
승인 중 취소, oversized/잘못된 프레임, provider 오류/부분 완료/답변 크기 초과,
EOF 정리, 중단 실패 후 새 작업 거절.

계속 구현할 부분: 상시 Matrix 수신·crypto/sync 복구, 인증된 승인 UI, room membership,
첨부 스트리밍, 중간 응답·상태 표시, 모델/메모리/사용량 정책의 기존 Telegram 경로와의
동등성, 다른 provider와 전체 플릿 배포. 운영 서비스에는 아직 설치하지 않는다.
