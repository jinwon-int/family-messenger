# 결정 기록 — 2026-09-13: 전달·암호화는 Matrix 스택을 채택, 화면·AI 층은 직접 만든다 ("D")

**상태:** 오너 결정(2026-09-13). 이 문서는 방향 결정이며 구현 완료·배포 완료를 뜻하지 않는다.
**대체하는 문서:** [OWN-SYSTEM.md](OWN-SYSTEM.md)의 "서버·전달·암호화를 직접 만든다" 부분,
[NATIVE-E2EE.md](NATIVE-E2EE.md)의 OpenMLS 통합 경로. 두 문서는 이력과 수용 기준으로 보존한다.
**유지하는 문서:** [VISION.md](VISION.md)(변경 없음), [ROADMAP.md](ROADMAP.md)(이 결정으로 개정).

## 결정

| 층 | 결정 | 근거 |
|---|---|---|
| 메시지 전달·키 배달 서버 | **단일 바이너리 Rust Matrix 홈서버**(1순위 Tuwunel, 대안 continuwuity). Synapse/Postgres 컨테이너는 퇴역 | "프로세스 하나 + DB 하나"에 Synapse보다 가깝다. 키 배달 API를 직접 쓰면 홈서버 일부를 다시 만드는 일이 된다 |
| 종단간 암호화 | **Matrix 암호화 스택**(`matrix-sdk-crypto` WASM — Element Web이 2024년부터 신규 로그인에 쓰는 것). 기기 검증·크로스사이닝·키 백업/복구 포함 | 우리가 조립하지 않는다. OpenMLS 통합 경로(기기 신뢰·교체·복구·그룹 상태 영구화)는 완성 전 사람 사용이 불가능해 첫 가족 메시지가 5~6개월 뒤로 밀렸다 |
| 가족이 보는 화면 | **직접 만든 웹 앱**(HTML/CSS/JS + `matrix-js-sdk`). Element는 쓰지 않는다 | 제품 경험(기억 확인·실행 승인·AI 열람 범위 안내)은 우리가 소유해야 한다 |
| AI 참여 층(신원·호출·기억·승인·에이전트 레지스트리) | **우리 Go 서버**(`server/`)가 담당. 채팅 서버가 아니라 "AI 참여 서비스"로 역할 변경 | `internal/access`(CF Access 검증·서명 정책 스토어)·SQLite 스토어·SSE는 그대로 재사용 |
| 에이전트 연결 | **`scripts/fleet_matrix.py` 계열 재사용**(megolm 송신·기기 고정·크래시 안전 sync) + `fleet_core` 계약 | 플릿 코드 중 가장 잘 만들어진 부분이 이미 Matrix용이다 |

## 왜 지금 바꾸는가 (2026-09-13 실측)

- 육손 운영 Matrix: 배포 5일, healthy, 매일 백업 성공, **메시지 0건**(활성 계정 2·방 2·기기 4).
- 최근 25개 PR 중 22개가 네이티브 MLS "successor custody"(기기 교체 시 그룹 재수립). 10개 테이블·10개 HTTP 서브리소스·스키마 12판·약 2,100 LOC가 "2인 방 기기 1대 교체"에 쓰였고, 각 단계 파일이 스스로 "이 transcript로는 아무것도 활성화하지 않는다"고 선언한다.
- #16 비-CI 실증(2026-09-12)은 "부분 통과 / 전체 실패 / 추가 지시 대기"에서 정지.
- VISION의 첫 목표("가족방 하나 + 가족 + AI 한 명")는 어느 트랙에도 아직 없다.

즉 **쓰는 사람이 없는 배포 위에, 사용자보다 여러 단계 앞선 암호학 인프라를 쌓고 있었다.** 우리가 소유해야 하는 것은 "가족의 기억·승인·에이전트 신원"이지 "메시지 바이트를 순서대로 전달하고 키를 배달하는 일"이 아니다.

## 검토한 대안

| 안 | 내용 | 기각/채택 이유 |
|---|---|---|
| A | Synapse + Element 그대로, AI 층만 만든다 | 가장 빠르지만 화면을 소유하지 못한다(기억·승인 UX가 채팅 메시지 흉내에 갇힘). 기각 |
| B | 서버·화면·E2EE 통합 전부 직접(현행) | E2EE 완성 전 사람 사용 금지 규칙과 결합해 첫 가족 메시지가 5~6개월 뒤. 평문 과도기(B2)를 허용해도 "임시가 영구가 되는" 위험. 기각 |
| C | 화면·AI 층 직접, Synapse를 전달층으로 | D와 같되 서버가 Synapse+Postgres(컨테이너 3개). D가 상위 호환 |
| **D** | 화면·AI 층 직접, **단일 바이너리 홈서버 + Matrix 암호화 스택** | 화면 소유·바이너리 1개에 근접·첫날부터 E2EE. **채택** |

## 정직한 대가

1. **의존성 증가.** Matrix 프로토콜(크다), `matrix-js-sdk`(크다), Rust 홈서버 1개. "의존성 최소"에서 B보다 후퇴한다. 대신 가장 위험한 층(암호학 조립)을 맡지 않는다.
2. **홈서버 포크 리스크.** conduwuit는 2025년 아카이브됐고 Tuwunel·continuwuity 두 후속이 있다. 완화: 하나를 고정하고 상대편으로의 DB 마이그레이션 가능 여부를 분기마다 확인. 최악의 경우 Synapse 복귀 — 프로토콜이 같아 화면·에이전트 코드는 무손실.
3. **기기 검증 UX는 우리 일.** 이모지 비교·복구 키 안내를 "가족 누구나" 수준으로 만들어야 한다. 메커니즘은 SDK가 준다.
4. **매몰 비용.** `server/internal/chat/mls*.go`, successor 9단계, `experiments/openmls-browser`, `experiments/device-keystore`는 전달층으로는 폐기한다. NATIVE-E2EE의 위협 모델·기기 정책·수용 기준은 D의 인수검사 기준으로 그대로 쓴다.

## 홈서버 선정 — 1주 평가 (0단계)

후보: **Tuwunel**(1순위: 공식 후속, 상용·정부 후원, 관리형 온라인 백업에 검증·보존·복원 내장, 정적 바이너리·deb) / **continuwuity**(대안: 커뮤니티, 연합 점유 ~8%, 관리는 admin 방 명령).

평가 항목(둘 다 육손 격리 디렉터리에서, 운영 Synapse 무변경):
- CF 터널 뒤 client API·`.well-known` 동작, 공개 가입·게스트·federation 완전 차단 설정
- 미디어 한도(영상 수십 MiB)·저장 경로·백업 방식(RocksDB 온라인 백업 + media 디렉터리 별도)
- 계정 생성·비활성화·방 관리의 스크립트 가능성(우리 `admin.py`가 호출할 수 있는가)
- 메모리·디스크 실측, 재시작·복원 드릴 1회
- 라이선스·릴리스 주기·보안 공지 경로

통과 조건: 위 항목 전부 "확인함"으로 기록. 결과는 이 문서에 추기한다.

## 코드 처분

| 대상 | 처분 |
|---|---|
| `server/internal/access`, SQLite 스토어·마이그레이션, SSE, `cmd/family-policy` | 유지 — AI 참여 서비스의 인증·정책·저장·이벤트 |
| `server/internal/chat/mls*.go`, `mls_successor_*`, `*_assets*.go`(synthetic UI 번들 12종) | `archive/native-mls/`로 이동 후 빌드에서 제외. 삭제는 1단계 가족 투입 이후 |
| `experiments/openmls-browser`, `experiments/device-keystore` | 동일하게 archive. `.github/workflows/mls-experiment.yml` 비활성화 |
| `server/*-evidence.json`, `server/*.md`(PR별 증거 18+11개) | `docs/evidence/`로 이동. 코드 옆에는 AUTH/MEDIA 계약만 |
| `scripts/fleet_matrix.py`, `fleet_matrix_state.py`, `fleet_core.py`, `fleet_worker.py`, `fleet_remote.py` | 유지·확장(가족방 모드, mention 모드 연결) |
| `compose.yaml`(Synapse/Element/Postgres), `scripts/init.py`·`backup.py` | 1단계 홈서버 교체 시 대체. 그 전까지 운영 유지 |

## 이 결정이 바꾸지 않는 것

- VISION의 제품 원칙 6개와 첫 버전 수용 기준.
- "합성 시험 통과만으로 실제 가족 사용을 승인하지 않는다."
- 사용자 복구 키를 서버가 수집하지 않는다. 복호화 실패를 평문 전환으로 숨기지 않는다.
- 노드의 AI/GitHub 자격 증명은 원래 노드에 남는다. 가족 채팅 권한은 서버 실행 권한이 아니다.
