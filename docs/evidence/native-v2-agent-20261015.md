# 에이전트 직접 참여 A4/A5 — 「한데」 가족방의 공명 에이전트 첫 실사용 (2026-10-15 16:0x ~ 16:46 KST, #354 · #271 런칭 게이트 6)

대상: 오너 iPhone **한데 앱**(TestFlight build 12, 기기 `owner-iphone-27a879`) ↔ 릴레이(서서 `native-relay`, 정책 rev 16) ↔
공명 `native-relay-bot`(에이전트 모드, 바이너리 main `c393f591` sha256 `aec294d6…`) ↔ 소켓 활성화 응답기
`native-responder@`(User=gongmyoung, `fleet_worker.py --provider claude --model claude-opus-5-5 --effort high --claude-permission-mode default`).
수행·관측 = yukson(공명 root ssh, 저널 `journalctl -u native-relay-bot`·`-u "native-responder@*"`), 판정 = 오너. 오너 결정 #354 ①-A ②-B ③-B ④-B.

## 전제 변경(이 검증 중 발견·수정)

| 블로커 | 원인 | 수정 |
|---|---|---|
| 첫 turn(seq 105) `runtime-error` → `worker_gone` | 공명 ChatGPT 계정 Codex가 `gpt-6.1-sol`(config 기본)·`gpt-5.6-sol`·`gpt-5.6`을 "not supported when using Codex with a ChatGPT account"(400)로 거부 | 오너 결정 "Claude opus 5.5 high" → [#360](https://github.com/jinwon-int/family-messenger/pull/360) `069f64ef` `fleet_worker.py --provider claude`(ccc-node `ClaudeRuntime`, 브리지 venv 파이썬) |
| 재시험(seq 107·109) 도 `worker_gone`, 워커 2초 만에 종료 | 워커 첫 emit이 `ConnectionResetError('Connection lost')` — systemd `StandardInput/Output=socket`에서 stdin·stdout이 같은 소켓인데 asyncio `_UnixWritePipeTransport`가 fd readability를 "피어 종료"로 해석 → 봇이 수 분 뒤 보낸 turn 프레임이 쓰기 전송을 닫음(접속 직후 보내는 프로브는 등록 전이라 미재현) | [#361](https://github.com/jinwon-int/family-messenger/pull/361) `build_output`: `S_ISSOCK`이면 `loop.sock_sendall`. 공명 선배치(sha `1a9a7b3b…`) |
| 봇 재시작 직후 `worker gone` 1회 → exit 1 → 10초 뒤 복구 | 소켓 `MaxConnections=1` — 옛 봇 연결이 아직 닫히지 않아 새 연결 거부("Too many incoming connections (1)") | `MaxConnections=2`(#361 템플릿·공명) |
| 봇 사용자가 소켓 디렉터리를 못 지남 | `DirectoryMode=0750`(root 소유) | `0755`(소켓 자체는 0600 봇 소유) |

## 수행·관측

| 단계 | 시각(KST) | 결과 | 관측(공명 저널) |
|---|---|---|---|
| 배포 | 16:0x | ✓ | 바이너리 `42a06650…` → `aec294d6…`(`.old-42a06650` 보존) · `/opt/native-responder/` · 유닛 2개 + drop-in · `enable --now native-responder.socket` · `restart native-relay-bot` → `identity restored:true` → `ready` → `agent_started{owner_actor:owner, queue_max:8, turn_secs:1200}` |
| 소켓 스모크(봇 사용자) | 16:0x | ✓ | 알 수 없는 명령 → `rejected unknown-command` 0.1초 · 클라이언트 쓰기 종료 → 워커 정상 종료 |
| ① 오너 "공명아 오늘 뭐할까?" | 16:11:24 | ✗ | seq **105** → `agent_offer Started` → 16:11:29 `agent_outbound uncertain` → `worker_gone`(Codex 모델 거부, 위 표) → 방에 "⚠️ 요청(#105)을 끝까지 확인하지 못했습니다(worker_gone)" |
| Claude 전환 후 소켓 경유 실제 turn | 16:2x | ✓ | "한 단어로만 대답: 안녕" → `session` 1.5초 → `result complete` "안녕" 3.6초 |
| ② 오너 재시험 | 16:29:51 · 16:38:20 | ✗ | seq **107**·**109** → `worker_gone` 2초 만(소켓 stdout 결함, traceback 확보) |
| 수정본 배치·재시작 | 16:4x | ✓ | `agent_started`, 재시작 시 worker gone **0**(MaxConnections=2) |
| **③ 오너 "공명아 오늘 뭐할까?"** | **16:43:12** | **✓** | seq **111**(27 B) → `agent_offer Started` → **16:43:40 `agent_outbound reply` 2,622 B** → 16:43:41 방 게시 seq **112**(`bot-gongmyoung-echo-47`). **28초**. 오너: "공명이 답변 왔어" |
| **④ 오너 "디스크 남은 용량"** | **16:46:05** | **✓** | seq **113**(47 B) → **16:46:12 reply** 448 B → seq **114**. **7초**. 오너: "466기가중 360기가 남아있대" = 공명 `df -h /` **466G / 360G 가용** 과 일치 |
| 상태 | 16:5x | ✓ | 봇 `NRestarts=0`, 워커 `native-responder@12` 동일 인스턴스 유지(2 turn 처리), 새 오류 0 |

## 판정 제안(#354 수용 기준 대비)

- **A4 ⑤-1 일반 메시지 → 답**: ✓(③, 28초). 🤖 알림 제목은 actor `bot` 규칙(FC_AGENT_ACTORS)으로 자동 — 오너 화면 확인은 별도.
- **A4 ⑤-2 도구 사용 요청**: ✓(④, `df` 실행 결과 일치). **승인 왕복(④-B)은 이번에 발동하지 않았다** — `df`는 공명 Claude 하네스의 허용 정책 안이라 `can_use_tool` 콜백이 호출되지 않음. 승인 왕복은 단위 테스트(가짜 워커)·소켓 수준까지만 증명.
- **런칭 게이트 6(봇·에이전트 경로)**: "독자 E2EE 방에 에이전트 직접 참여" 방향이 실기기에서 성립. 가족 발신(③-B)은 가족 투입 뒤.

## 발견·후속

- asyncio write-pipe 전송은 소켓 stdout에 쓰면 안 된다(#361). 소켓 프로브는 접속 후 **지연을 두고** 보내야 봇과 같은 조건.
- ChatGPT 계정 Codex의 모델 허용은 CLI 버전뿐 아니라 계정 종류에도 걸린다(`*-sol` 거부). 공명 Codex 설정은 그대로(브리지 Danso·A2A 워커 무관).
- 봇 `agent_outbound` 이벤트에 uncertain `reason`이 없다 — 저널만으로 원인 분류가 안 됨 → 후속(이벤트에 reason 추가).
- 응답 지연: 도구 많은 질문 28초, 단일 명령 7초. 가족방 체감은 오너 판단.
- 미착수: 승인 왕복 실기기(허용목록 밖 도구 — 예: 홈에 파일 쓰기 요청), 가족 기기 발신, 1주 소음·비용 관찰(②-B).

## 증명하지 않는 것

- **④-B 승인 왕복의 실기기 동작**(요청 게시 → 오너 `승인 n` → 실행 → 결과): 이번 두 turn 모두 승인 요청이 발동하지 않았다.
- 가족 actor 발신(③-B)·`bot*` actor 무시·첨부 무시의 실기기 동작(단위 테스트만).
- inbox 중복 실행 금지의 실기기 동작(재시작 중 활성 turn이 없었다).
- 🤖 알림 제목·잠금화면 표시(오너 화면 미확인).
- 응답기 메모리 주입(bare `ClaudeRuntime`): CLI가 `/home/gongmyoung` 하네스를 읽는 것으로 가정, 내용 검증 안 함.
