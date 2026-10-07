# NOTES-FINALIZER — iOS 트랙 파이널라이저 작업 노트 (#271 통합 · #282 계약 · #276 스모크)

- 작업자: seoseo (session `seoseo-finalizer-20261007`, Claude). 2026-10-07 오너 재배정(방통→서서), 공융 전달.
- 베이스: main `8638fb0` (L1 #283 · L2 #281/#282 · L3 #317 · CI pipefail #315 머지 후).
- 재개 규칙: **이 파일 + `git status` 부터**. 파일/단계마다 commit+push, #271 에 "SHA + 내용 + 테스트 결과" 한 줄.
- 머지·merge queue·승인은 하지 않는다(오너 승인 후 공융).
- 환경: 이 노드에 swift/go/rust 없음 → Docker(`swift:6.0-noble`, `golang:<go.mod>`, `rust:1.91.1`) `--rm`, 작업 디렉터리만 마운트.
  FamilyChat 앱 타깃은 iOS 전용 → macOS CI 로만 검증(PR 당 재시도 ≤5).
  운영 `native-relay`·`/opt/**`·운영 DB 금지. 스모크 릴레이 = 임시 포트(127.0.0.1) + `mktemp -d`.
- PR 스택: ① `finalizer/contracts-271`(base main) → ② `finalizer/integration-271`(base ①) → ③ `finalizer/relay-smoke-276`(base ②).

## 읽은 것 요약 (재독 불필요)

- #282 본문 불일치 3건 — 서버 원문으로 확인:
  1. close: `server.go handleCloseRoom` → **200 `{"closed":true}`**(멱등). CONTRACTS §2.1 은 204.
  2. `room_closed`: events POST/GET·keypackages·close 모두 **410**(`server.go` 634·694·836·964). CONTRACTS 는 403.
  3. 인증: `auth.go bearerToken` 은 `Cf-Access-Jwt-Assertion` → `Authorization: Bearer` 순으로 **헤더만** 읽는다.
     `CF_Authorization` 쿠키는 CF 엣지가 검증해 헤더로 바꿔 주는 값(`static.go` 머리말) — 엣지 없는 직결(로컬·스모크)은 `.bearer` 필요.
  - Python `tests/native_v2_relay_smoke.py:845-855` 가 200→410 을 이미 고정, 봇·relay-app 도 같은 서버를 쓴다.
  - iOS 코드 영향: `URLSessionRelayTransport.closeRoom` 은 2xx 면 통과, `RoomSyncEngine.handleReadRefusal` 은 코드(`room_closed`)로만 판정 → **동작 영향 없음, 문서만 틀림**.
- 파사드 `Device`(openmls-browser `lib.rs:187`) = 서명키 1개 + 그룹 0..1 + 키패키지 저장소. `export_state(identity)` 는 identity 를 바이트에 박고 import 때 재검사.
  봇(`session.rs load_state`)·relay-app(`relay-app:<room>:<device>:<db>`) 모두 **방 하나 = 상태 하나**.
- 정책 체인(`native-devices`)은 기기당 `signing_key` **1개**를 등록하고, `sign_approval`·지문 비교·`remove_pending` 이 그 키를 전제한다.
  릴레이는 MLS 키를 체인과 대조하지 않는다(서버 MLS 상태기계 없음).
- L3 `RoomSyncEngine.transaction`: 방 상태가 없으면 `engineFactory.create(identity:)` 후 즉시 저장 → 그대로 두면 **방마다 서명키가 달라진다**.
- 앱 뼈대 `AppModel.send` 는 `_identity` 엔진(그룹 없음)으로 방 메시지를 암호화한다 — 통합 때 RoomSyncEngine 으로 교체 필요(버그).
- 릴레이 `-access-mode disabled` + `-device-state` 없음 → `authorizeEvent` 가 `active == nil` 이라 멤버 추적 안 함 → GET events `members: []`.
  L3 정책 ④는 `[]` 를 outer 로 비교(웹 relay-app 도 `Array.isArray` 로 동일) → 격리 스모크에서 **타인 commit(최신 epoch)은 `outer_inner_mismatch` 로 정지**한다.
  스모크 시나리오는 타인 commit 처리를 "의도적 위반" 하나로 한정한다.
- 와이어: 초대 = KP 소비(`?device=<대상>&consumer=<나>`) → `invite_with_commit`(출력 `u32le commitLen‖commit‖welcome`) → commit POST(`members` = `members_after_pending` 프레임, actor = ID 첫 `-` 앞, 첫 commit 은 epoch 0 부트스트랩) → 동기화로 내 echo 에서 `merge_pending` → Welcome POST(`targets=[대상]`).
- 확장 ① `GET /v2/rooms?device=` 는 서버에 있다(#282) — `URLSessionRelayTransport.listRooms` 는 아직 404 고정. ② 푸시는 §12-D(범위 밖).
- CI: macOS `ios-build` 최근 7분(07:40→07:47, run 37588781476) — 예산 25분.
- 무서명 시뮬레이터(`CODE_SIGNING_ALLOWED=NO`)에서 App Group 컨테이너는 nil 일 수 있다 → live 는 Application Support 폴백.

## 결정

- **D1 계약 정리 = 계약 문서를 서버에 맞춘다**(서버 변경 없음). 근거: 서버 동작이 의도적(멱등 200, 410 Gone, 쿠키는 엣지 몫)이고
  Python 스모크·봇·relay-app 이 이미 의존. origin 이 쿠키를 직접 읽게 하면 CSRF 면이 생긴다(브라우저 자동 첨부).
  쿠키 경로는 "엣지 경유 전용", 직결은 `.bearer`.
- **D2 identity ↔ 방 상태 시드 = 복제 시드**: `_identity` 슬롯(서명키만, 그룹·키패키지 없음)의 `export_state` 바이트를 방 상태가 없을 때
  `importState` 해 방 상태의 출발점으로 쓴다(앱 측 `SeededEngineFactory`, Core 무변경). 결과: 모든 방이 같은 서명키 → 등록 JSON·지문 1개,
  `sign_approval`·`remove_pending` 일관. `_identity` 슬롯에서는 `key_package`·`create` 를 절대 하지 않는다(개인 init 키가 방들로 복제되지 않게).
  대안(방마다 새 키) 기각: 체인에 기기당 키 1개라 두 번째 방부터 지문 불일치.
- D3 스모크 = macOS CI 잡에서 Go 릴레이(`-access-mode disabled`, 임시 포트, `mktemp -d`) + 작은 Python 감독자(stop/start 제어 포트) +
  시뮬레이터 XCTest(`TEST_RUNNER_` 환경변수로 URL 전달, 없으면 XCTSkip).

## 진행

1. [ ] NOTES(이 파일) — ① 브랜치 첫 커밋
2. [ ] ① CONTRACTS §2.1 3건 + §6 파이널라이저 재배정 기록 → PR
3. [ ] ② 통합: SeededEngineFactory · Dependencies.live(File*/Keychain/URLSession) · AppModel 방 동기화 · 초대/키패키지 · listRooms 구현 · 테스트 → PR
4. [ ] ③ 스모크: 감독자 스크립트 · RelaySmokeTests · 워크플로 → PR, 결과로 #276 Closes 여부 판단
