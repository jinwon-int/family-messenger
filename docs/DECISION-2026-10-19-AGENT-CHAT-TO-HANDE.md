# 결정 기록 — 2026-10-19: 에이전트 채팅을 Matrix에서 「한데」로 옮긴다 (초안, 단계형 컷오버)

**상태:** **초안 — 오너 확정 전.** 오너 방향 제시(2026-10-19 "에이전트 채팅을 Telegram → Matrix로 옮겼고, 이제 독자 개발한 한데 앱으로 옮긴다")를 받아 작성한 검토·결정 초안이다. 아래 §4 "오너 확정 항목"에 답이 적히기 전에는 어떤 운영 변경도 승인하지 않는다.
**이어받는 문장:** [결정 E](DECISION-2026-09-21-MATRIX-PLUS-NATIVE-E2EE.md) §5 「전달층을 독자 스택으로 바꾸는 컷오버는 … 오너가 따로 고른다」· [#271 런칭 게이트 6](https://github.com/jinwon-int/family-messenger/issues/271) 「봇·에이전트 경로(fleet 봇은 Matrix 유지 여부)」· [#354](https://github.com/jinwon-int/family-messenger/issues/354) 오너 결정 1-A(에이전트 **1개** 직접 참여).
**바꾸지 않는 것:** 결정 D·E의 "가족 채팅 운영 전달층은 Matrix" — 이 문서는 **에이전트 채팅**(오너 ↔ 플릿 노드 개인방 + 플릿 알림방)만 다룬다. 가족 Matrix(패밀리챗) 은퇴는 별도 결정이다. [VISION.md](VISION.md)·[NATIVE-E2EE.md](NATIVE-E2EE.md) 불변.
**추적:** [#271](https://github.com/jinwon-int/family-messenger/issues/271) 게이트 6 코멘트 · [#92](https://github.com/jinwon-int/family-messenger/issues/92). 문서와 어긋나면 #92가 우선한다.

## 1. 결정 (초안)

| 항목 | 내용 |
|---|---|
| 목표 | 오너가 플릿 노드 에이전트와 대화하는 **주 채널을 Matrix에서 한데(독자 E2EE 방 + v2 릴레이)로** 옮긴다. |
| 방식 | **단계형 컷오버.** 한 번에 바꾸지 않고 §3의 0→4단계를 게이트마다 통과하며 옮긴다. |
| 폴백 | Matrix 에이전트 브리지는 **최소 1~2노드에 폴백으로 유지**한다(Telegram 정리 때 서서 1곳을 남긴 것과 같은 원칙). 릴레이 장애 시 "릴레이가 죽은 사건을 릴레이로 알리는" 모순을 피하기 위해서다. |
| 전제 | §2의 설계 한도 5개와 운영 공백은 **코드로 먼저 해소**한 뒤 노드를 늘린다. 한도를 운영 수작업으로 우회하지 않는다. |
| 이번 결정이 하지 않는 것 | 가족 Matrix 은퇴 · 릴레이 운영 노드 변경 · 비밀값 발급·이동 · 바이너리 교체 · 기존 Matrix 대화 이력 이관(기본 비이관) |

## 2. 왜 "채널 교체"가 아니라 "스택 교체"인가 — 2026-10-19 실측

Telegram→Matrix 이동은 같은 ccc-node 브리지 안에서 프론트엔드만 바뀌었다. 한데는 전송·암호화·응답기·운영 도구가 모두 다르다. main `0683db8`(family-messenger) · `1e577217`(ccc-node) 기준으로 읽은 사실이다.

### 2-1. 설계 한도 (코드 변경 없이는 못 넘는 것)

| # | 한도 | 근거 | 플릿 12노드에 미치는 영향 |
|---|---|---|---|
| H1 | 봇 하나가 응답하는(agent 모드) 방은 **정확히 1개**. 둘 이상이면 기동 거부 | `archive/native-mls/bot/src/session.rs` "more than one room in agent mode; the responder serves exactly one" · `STEWARD.md` | 노드별 개인방 + 플릿 공용방 구조가 불가능 |
| H2 | actor = 기기 ID의 첫 `-` 앞 → `bot-<노드>`는 전부 actor `bot` · **actor당 활성 기기 ≤4** | `responder.rs` actor 유도 · `devicepolicy.go` `MaxActivePerActor=4` | 현 이름 규칙으로 **최대 4노드** |
| H3 | 정책 체인 **revision 상한 64, 컴팩션 미구현**(소진 시 정지) · 기기 총 **32**(폐기 tombstone 영구 포함) | `devicepolicy.go` `MaxDevicePolicyRevisions=64`, `MaxDevicesTotal=32` · [DEVICES-V4.md](../archive/native-mls/server/DEVICES-V4.md) | 10-15 시점 rev 18. 봇 12 등록(+12) + 가족 기기 + 교체·폐기마다 +1 → 소진 가능 |
| H4 | actor `bot*` 발신은 turn이 되지 않는다(봇끼리 루프 방지) | `responder.rs`, `session.rs` | 플릿 알림방·노드 간 지목 같은 "봇이 보낸 것을 봇이 읽는" 흐름 전부 차단. 의도된 안전장치라 완화는 설계 결정 |
| H5 | 릴레이에 long-poll/SSE·rate limit 없음, 봇은 **200 ms 단순 폴링**, 쓰기는 SQLite 단일 연결 + mutex | `session.rs` `POLL`, `server.go` | 12봇 × 방 N개 × 5 req/s 상시 부하가 릴레이 한 프로세스에 집중 |

### 2-2. 잃는 기능 (Matrix 프론트엔드에는 있고 한데 응답기에는 없는 것)

- 명령어 전부(`/new /model /effort /stop /continue /resume /history /restart /waits /cancelwait /memory_promote /distill /skills /task_*`). 한데 봇은 `/…`도 일반 turn으로 넘긴다.
- 스트리밍 미리보기 · 첨부 수신(봇은 `file-v1-*` 무시) · 답변 파일 송신 · 음성.
- 세션 연속성: 봇이 매 turn `session_id: null`을 보낸다(`responder.rs`). 어댑터의 `start_or_resume`이 이를 어떻게 다루는지 **실측 전**(§3 1단계).
- ccc-node 운영 계층: 승인 감사 원장 · continuation monitor · dead-session 복구 · health.json · self-update idle gate · doctor 판정 · fleet-watch 프로브 · restart receipt · duration.jsonl 집계. 한데 응답기는 ccc-node 브리지를 거치지 않고 런타임(`AgentSession`)에 직접 붙기 때문에 이 계층이 한데 경로를 **모른다**.
- ccc-node 쪽에는 범용 전송 인터페이스가 없다(`CCC_CHANNEL`은 `telegram|matrix` 고정). Matrix 때도 Telegram 믹스인이 "자동으로 따라오지 않아" 기능을 하나씩 다시 옮겼다. 같은 일을 세 번째로 하지 않으려면 전송 추상화를 먼저 만든다(ccc-node [#1602](https://github.com/jinwon-int/ccc-node/issues/1602) 첫 항목).

### 2-3. 운영 리스크

- **단일 장애점 이동**: Matrix 홈서버 호스트 강제 재부팅으로 12분 두절([#412](https://github.com/jinwon-int/family-messenger/issues/412), 워치독 진행 중) → 한데로 가면 Go 단일 프로세스 + SQLite + CF Access인 릴레이가 **에이전트 채팅과 가족 채팅의 공통 SPOF**가 된다. 릴레이 오프호스트 워치독은 아직 없다.
- **알림 경로**: 지금 노드 알림(헬스·리마인더·메일 미러·fleet-watch)은 전부 Matrix 플릿 알림방으로 간다. 이동 뒤 폴백 채널 없이는 릴레이 장애를 알릴 길이 없다.
- **Termux 노드 2대**: 응답기가 systemd 소켓 활성화를 전제한다. Android 타깃 Rust 빌드는 CI에 있으나 Termux 운영 경로는 미검증.
- **노드당 수작업 게이트**: CF 서비스 토큰·JWT 갱신 타이머·정책 enroll(릴레이 운영 노드 CLI, 승인)·오너 앱 초대를 12회 반복.
- **PC 경험**: 오너가 PC에서 에이전트와 대화하려면 `relay-app`(웹, 이력 미보관 설계). Element 웹/데스크톱 수준이 아니다.

## 3. 단계와 게이트

| 단계 | 내용 | 게이트(다음 단계로 넘어가는 조건) |
|---|---|---|
| **0. 결정 기록**(이 문서) | 범위·폴백·롤백 조건 확정, #271 게이트 6 코멘트, ROADMAP §5 연결 | §4 오너 확정 |
| **1. 에이전트 1개 안정화**(공명, 진행 중) | [#404](https://github.com/jinwon-int/family-messenger/issues/404) 관찰 기간 완료 · 세션 연속성 실측 · 명령어 최소셋(`/new /model /stop`)을 응답기에 추가 | 7일 응답기 오류 0(`agent_offer`/`agent_outbound` 저널) + 오너 체감 OK |
| **2. 플릿 전제조건**(코드만, PR-first) | ① H3 revision 컴팩션 ② H2 노드별 actor 분리 + 🤖 표시(`FC_AGENT_ACTORS`)·루프 규칙 갱신 ③ H1 봇 다중 agent 방 ④ H5 릴레이 long-poll(또는 wait 파라미터) ⑤ H4 봇-봇 메시지 허용 정책(명시적 허용 목록) ⑥ ccc-node 전송 추상화 + 한데 채널 등록(health/doctor/self-update/fleet-watch 인지) ⑦ 릴레이 오프호스트 워치독(#412 자매) | 각 항목 CI green + 격리 릴레이(`-access-mode disabled`, loopback) 스모크 |
| **3. 소수 노드 파일럿** | Linux 노드 2~3개를 개인방으로 연결, Matrix 병행. 7일간 두 채널 turn 수 비교(`duration.jsonl`) | 한데 turn ≥ Matrix turn · 응답기 오류 0 · 승인 왕복 1회 이상 |
| **4. 플릿 전환** | 나머지 노드 · 플릿 공용방/알림방 · Termux 2대. Matrix 브리지는 1~2노드 폴백 유지 | 12노드 실제 응답 + 지목 안 된 노드 침묵([ROADMAP](ROADMAP.md) 4단계 게이트 재사용) |

각 단계의 **운영 변경**(바이너리 교체·유닛·정책 enroll·비밀값 발급·릴레이 재시작)은 단계 안에서도 건마다 승인이다. 코드·문서 PR은 자율 범위다.

**롤백(모든 단계 공통):** 해당 노드의 Matrix 브리지를 다시 켠다. 한데 쪽 기기는 `-revoke`로 폐기하지 않고 봇 유닛만 정지한다(revision 소모 방지, H3).

## 4. 오너 확정 항목 (번호형)

① **범위** — 권장 **①-A 에이전트 채팅만**(개인방 + 플릿 알림방). ①-B 가족 Matrix까지 함께 은퇴(별도 결정 문서 필요).
② **폴백 유지 노드** — 권장 **②-A 서서 + 1노드**(Telegram 폴백과 같은 노드에 두면 두 폴백이 한 호스트에 몰림 — 다른 노드 1개 추가). ②-B 서서만.
③ **actor 명명(H2)** — 권장 **③-A 노드별 actor**(예 `agent-<노드>`; `FC_AGENT_ACTORS`는 접두 매칭으로). ③-B `bot` actor 한도 상향(정책 불변식 변경, 가족 기기 한도와 비대칭).
④ **봇-봇 메시지(H4)** — 권장 **④-A 플릿 알림방에서만 허용**(방 단위 허용 목록). ④-B 전면 허용(루프 위험). ④-C 금지 유지(플릿 알림은 Matrix 폴백에 남김).
⑤ **2단계 수행 배정** — 항목 ①~⑦을 이슈로 쪼개고 노드 배정은 오너.

답 예시: "①-A ②-A ③-A ④-A ⑤ 이슈 개설 진행".

## 5. 확인하지 못한 것

- 세션 연속성(§2-2): `ccc_adapter.py`의 `start_or_resume`이 `session_id: null`을 받을 때 매번 새 세션인지, 어댑터가 자체 매핑을 갖는지 — 공명 저널 실측 필요.
- 12봇 폴링 부하(H5)의 실제 수치 — 격리 릴레이에서 측정 전까지는 추정.
- Termux에서 Rust 봇·응답기 운영 가능 여부 — 빌드만 CI에 있음.
- 오너 PC 경험을 `relay-app`으로 감당할지, 데스크톱 클라이언트가 필요한지 — 3단계 파일럿에서 판단.

관련: [#271](https://github.com/jinwon-int/family-messenger/issues/271) · [#354](https://github.com/jinwon-int/family-messenger/issues/354) · [#366](https://github.com/jinwon-int/family-messenger/issues/366) · [#404](https://github.com/jinwon-int/family-messenger/issues/404) · [#412](https://github.com/jinwon-int/family-messenger/issues/412) · ccc-node [#1602](https://github.com/jinwon-int/ccc-node/issues/1602) · [FLEET-BRIDGE.md](FLEET-BRIDGE.md) · [archive/native-mls/bot/AGENT.md](../archive/native-mls/bot/AGENT.md)
