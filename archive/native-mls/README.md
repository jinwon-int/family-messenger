# archive/native-mls — 동결된 네이티브 MLS 전달층 (빌드·CI 제외)

**상태:** 동결(2026-09-13). 빌드되지 않고, CI에서 테스트되지 않는다. 확장하지 않는다.

## 이것은 무엇인가

우리 Go 서버(`server/`)가 직접 E2EE 전달층이 되려던 시도의 코드·문서·시험 드라이버다.
[결정 D](../../docs/DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md)와
[ROADMAP 0단계](../../docs/ROADMAP.md)에 따라 원래 경로를 그대로 유지한 채 여기로 옮겼다.

| 위치 | 원래 위치 | 내용 |
|---|---|---|
| `server/internal/chat/mls*.go` | `server/internal/chat/` | `/v1/mls/*` 합성 MLS 전달(예약·그룹 바인딩·불투명 로그), 준비 장벽, successor 9단계(context·reservation·custody·handshake·confirmation·lease·retirement·enrollment·closure) |
| `server/internal/chat/*_assets*.go`, `*_bundle*.json` | 같음 | `-tags synthetic_*`로만 임베드되던 합성 UI 번들 12종과 해시 고정 매니페스트 |
| `server/*.md` | `server/` | 위 흐름만 설명하는 계약 문서(MLS-TRANSPORT, PREPARATION, SUCCESSOR*, CLIENT-CUSTODY, ENCRYPTED-UI, VAULT-UI, HISTORY-UI, AGGREGATE*) |
| `tests/` | `tests/` | MLS·successor·번들 흐름만 검증하던 `native_*` 드라이버·검사 모듈, 실험 스모크, 픽스처 |
| `tools/prepare_mls_assets.py` | `tools/` | 번들 준비·검증 도구 |
| `../experiments/{openmls-browser,device-keystore}` | `experiments/` | OpenMLS WASM 브라우저 실험, 기기 키 보관 실험 |

증거 JSON은 [`docs/evidence/server/`](../../docs/evidence/server/)에 있다.

## 왜 동결했나

결정 D: 전달·암호화는 Matrix 스택(단일 바이너리 Rust 홈서버 + `matrix-sdk-crypto`)을 채택하고,
우리는 화면과 AI 참여 층을 만든다. 이 코드는 "2인 방 기기 1대 교체"를 위해 스키마 12판·테이블 10개·
서브리소스 10개를 쌓았지만 사람이 쓸 수 있는 상태에 이르지 못했고, 위협 모델·수용 기준만
D의 인수검사 기준으로 계승한다.

## 남아 있는 것과 남지 않는 것

- **남아 있는 것:** SQLite 스키마 3~12의 마이그레이션(`server/internal/chat/schema_frozen.go`)과
  `mls_*` 테이블. 기존 스키마-12 데이터베이스는 이전과 똑같이 열리고, 옛 판은 같은 스냅숏을 남기며
  12판까지 올라간다. 테이블은 삭제·변경하지 않는다. 스키마 13은 추가하지 않는다.
- **남지 않는 것:** `/v1/mls/*` 라우트 전부(지금은 404), `family-dev`의 `--synthetic-*-ui` 플래그,
  `-tags synthetic_*` 빌드, `native_policy_smoke.py --successor*` 프로브, `.github/workflows/native.yml`의
  MLS 전송 스모크와 스키마 8~11 롤백 프로브.
- `internal/access`의 `successors.go`·`activation.go`는 서명 정책 스토어(정책 버전 2·3)의 일부이므로
  코드에 남아 있다. 다른 것과 함께 검토해 정리한다.
- `.github/workflows/mls-experiment.yml`은 `workflow_dispatch` 전용으로 남아 있으나 옛 경로를 가리키며
  실행되지 않는다. 참고용이다.

## 삭제 계획

ROADMAP 1단계(가족 2명 + AI 1이 가족방에서 실제 E2EE 대화 100건) 게이트를 통과한 뒤 삭제한다.
그 전까지는 이력·참고용으로만 둔다. 이 디렉터리의 코드는 현재 `server/` 모듈과 함께 컴파일되지 않으며,
필요하면 이 커밋 이전의 git 이력에서 빌드 가능한 상태를 찾는다.
