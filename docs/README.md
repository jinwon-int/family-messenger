# 문서 색인

> **보관 코드 위치(2026-09-21)**: `archive/native-mls/`와 `archive/experiments/`는 결정 E로 main에 복원됐다(빌드·기본 CI 제외). 개요는 [archive/README.md](../archive/README.md). 퇴역 Synapse 스택은 태그 [`archive-frozen-20260917`](https://github.com/jinwon-int/family-messenger/tree/archive-frozen-20260917/archive/synapse-stack)에만 있다.

`docs/`의 모든 파일을 한 줄씩 적는다. 상태는 **현행**(지금 따르는 문서), **이력**(결정 과정·수용 기준으로
보존, 일부 내용은 대체됨), **보관**(네이티브 MLS 트랙의 단계별 합성 증거·기록)이다.
문서끼리 어긋나면 [이슈 #92](https://github.com/jinwon-int/family-messenger/issues/92)가 우선한다.

## 먼저 볼 것

- [DECISION-2026-09-21-MATRIX-PLUS-NATIVE-E2EE.md](DECISION-2026-09-21-MATRIX-PLUS-NATIVE-E2EE.md) — 결정 E: Matrix는 운영 전달층으로 유지, 독자 E2EE는 병행 개발. 해동·CI·컷오버는 이 문서의 범위 밖 — **현행**
- [DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md](DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md) — 결정 D: 운영 전달·암호화는 Matrix 스택(단일 바이너리 홈서버 + `matrix-sdk-crypto`), 화면·AI 층은 직접. 대안 비교·대가·홈서버 평가 결과(Tuwunel 1.9.1 확정)·코드 처분표. 개발 동결 문장은 결정 E가 대체 — **현행**(운영 전달층)
- [이슈 #92](https://github.com/jinwon-int/family-messenger/issues/92) — 로드맵 진행 추적과 결정에 이른 대화 기록. 문서와 어긋나면 #92가 우선 — **현행**
- [ROADMAP.md](ROADMAP.md) — Matrix 제품 순서 0~4단계와 KPI, 5단계 독자 E2EE 병행 — **현행**
- [VISION.md](VISION.md) — 제품 비전, 원칙 6개, 첫 버전 수용 기준(결정 D·E로 변경 없음) — **현행**

## 운영·의존성

- [OPERATIONS.md](OPERATIONS.md) — Tuwunel 운영면 기준 설치 신원·계정 발급(`scripts/admin.py create`)·저장공간 경보·백업/복원 참조·첫 운영 전 완료 기준. Synapse 시대 절차는 `archive/synapse-stack/` 보관 — **현행**
- [DEPENDENCIES-AND-RESOURCES.md](DEPENDENCIES-AND-RESOURCES.md) — 구성요소별 직접·간접 의존성, 고정 홈서버 핀·툴체인, 서버 프로세스 수, 자원 실측 기록(`scripts/resource_report.py`로 재생성) — **현행**
- [BENCHMARK.md](BENCHMARK.md) — 2026-09-08 오픈소스 비교와 Matrix 채택 근거. 보관된 Synapse 구성(`archive/synapse-stack/`)을 설명하는 역사적 기록 — **이력**
- [TUWUNEL-DEPLOY.md](TUWUNEL-DEPLOY.md) — 단일 바이너리 홈서버 Tuwunel 배포 런북: 고정 핀 바이너리 확보·설정·터널 ingress·첫 관리자와 검증 체크리스트·백업/복원 요약. 실제 배포는 별도 승인 후 — **현행**
- [TUWUNEL-OPERATIONS.md](TUWUNEL-OPERATIONS.md) — Tuwunel 운영 기준: 보안 기본값, `scripts/admin.py` 계정 관리, `scripts/tuwunel_backup.py` 백업과 `scripts/tuwunel_restore_drill.py` 복원 드릴 — **현행**
- [SYGNAL-DEPLOY.md](SYGNAL-DEPLOY.md) — 푸시 게이트웨이 Sygnal 배포·운영 런북: digest 고정 이미지·VAPID 키 생성과 교체·터널 ingress·검증 체크리스트·조용한 유실 4종 진단. Tuwunel은 벤더 연동이 없어 게이트웨이 없이는 알림이 0건이다. 실제 배포는 별도 승인 후 — **현행**

## 에이전트 연결부(`scripts/fleet_*.py`) — 결정 D로 재사용·확장

- [FLEET-BRIDGE.md](FLEET-BRIDGE.md) — 전체 플릿(노드별 Matrix 신원·운영자 권한·승인/취소·불확실 작업)의 가족 메신저 참여 설계. 가족방·mention 모드는 1단계 — **현행**
- [FLEET-CORE.md](FLEET-CORE.md) — `fleet_core.py`: 네트워크 없는 수신 허용·큐·outbox·불확실 작업 계약 — **현행**
- [FLEET-MATRIX.md](FLEET-MATRIX.md) — `fleet_matrix.py`: 암호화 개인방 연결부 설치·최초 장치 신뢰·수신/복구/실행 경계·제어·`SafetyStop` 차단과 운영자 해제 도구(`fleet_matrix_state.py unblock`) — **현행**
- [FLEET-WORKER.md](FLEET-WORKER.md) — `fleet_worker.py`: 노드 실행부의 상주 JSON 포트(ccc-node AgentRuntime, 현재 Codex read-only 시험 바인딩) — **현행**
- [FLEET-REMOTE.md](FLEET-REMOTE.md) — `fleet_remote.py`: 운영 서버에서 노드 실행부를 SSH로 호출하는 guardian·heartbeat·종료 확인 계약 — **현행**

## 네이티브 트랙 설계 — 운영 전달층은 Matrix(결정 D). 개발은 병행(결정 E). 수용 기준은 유효

- [OWN-SYSTEM.md](OWN-SYSTEM.md) — 2026-09-08 "직접 만드는 가족 메신저" 방향과 구현 계약. 운영 전달·암호화 문장은 결정 D로 대체됨 — **이력**
- [NATIVE-E2EE.md](NATIVE-E2EE.md) — OpenMLS 기반 네이티브 E2EE 타당성·통합. 운영 투입 경로는 결정 D가 대체. 위협 모델·수용 기준은 병행 트랙의 인수검사 — **현행**(수용 기준) / 운영 투입은 **이력**
- [DEVICE-KEY-CUSTODY.md](DEVICE-KEY-CUSTODY.md) — 기기 키 보관·복구 후보 설계(passkey 보호 아카이브 검토). 네이티브 트랙 전제이며 사람 사용 활성화 아님 — **이력**
- [DEVICE-LIFECYCLE.md](DEVICE-LIFECYCLE.md) — 분실·교체 기기 자격·successor 절차 설계. 참조하는 서버 코드는 `archive/native-mls/`에 있음 — **이력**

## evidence/ — 측정·평가 원본

- [evidence/homeserver-eval-20260913.md](evidence/homeserver-eval-20260913.md) — 결정 D 0단계 홈서버 격리 평가 전문(Tuwunel 1.9.1 vs continuwuity 26.8.1, 항목 a~h) — **현행**
- [evidence/e2ee-feasibility-20260909.json](evidence/e2ee-feasibility-20260909.json) — `family.e2ee.feasibility.v1`: OpenMLS 버전·설계 전용 타당성 기록(암호 의존성 미설치 상태) — **이력**
- `evidence/server/` — PR #90에서 `server/*-evidence.json`을 옮긴 네이티브 MLS 단계별 합성 증거. 어떤 단계도 사람 사용을 활성화하지 않음 — 모두 **보관**
  - [evidence/server/preparation-evidence.json](evidence/server/preparation-evidence.json) — 네이티브 E2EE 준비 단계 증거
  - [evidence/server/encrypted-ui-evidence.json](evidence/server/encrypted-ui-evidence.json) — 암호화 채팅 UI 합성 검증
  - [evidence/server/history-ui-evidence.json](evidence/server/history-ui-evidence.json) — 이력 UI 합성 검증
  - [evidence/server/history-v5-evidence.json](evidence/server/history-v5-evidence.json) — 이력 v5 저장 형식 검증
  - [evidence/server/vault-ui-evidence.json](evidence/server/vault-ui-evidence.json) — 키 보관(vault) UI 합성 검증
  - [evidence/server/aggregate-ui-evidence.json](evidence/server/aggregate-ui-evidence.json) — 통합 UI 합성 검증
  - [evidence/server/aggregate-history-ui-evidence.json](evidence/server/aggregate-history-ui-evidence.json) — 통합 이력 UI 합성 검증
  - [evidence/server/successor-evidence.json](evidence/server/successor-evidence.json) — successor(기기 교체) 기본 단계 증거
  - [evidence/server/successor-reservation-evidence.json](evidence/server/successor-reservation-evidence.json) — successor 예약 단계 증거
  - [evidence/server/successor-context-evidence.json](evidence/server/successor-context-evidence.json) — successor 서명 컨텍스트 preflight 증거
  - [evidence/server/successor-custody-evidence.json](evidence/server/successor-custody-evidence.json) — successor custody 단계 증거

새 문서를 추가하거나 상태가 바뀌면 이 색인의 해당 줄을 같은 PR에서 고친다.
