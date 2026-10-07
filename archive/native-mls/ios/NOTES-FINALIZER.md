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

1. [x] NOTES(이 파일) — ① 브랜치 첫 커밋 `5845842`
2. [x] ① CONTRACTS §2.1 3건 + §6 파이널라이저 재배정 기록 → PR #320 (`e4d7391`)
3. [x] ② 통합(`finalizer/integration-271`, PR #321): SeededEngineFactory · Dependencies.live(File*/Keychain/URLSession) · AppModel 방 동기화 · 초대/키패키지 · listRooms 구현 · 테스트 → PR
   - Linux: Core `Executed 97 tests, with 0 failures`(리포 전체 마운트 필수 — 픽스처 탐색이 리포 루트 기준).
   - Linux 하네스(/tmp/fc-typecheck: Combine·CryptoKit·App Group·FFI 스텁)로 앱 비UI 소스 컴파일 + AppModelTests `Executed 12 tests, with 0 failures`.
   - 발견: L3 는 내 echo 를 건너뛰어 **내 메시지가 MessageStore 에 안 들어감** → AppModel 이 서버 seq 확인 시 평문 기록(`recordOwn`).
   - **결함 발견·수정 `d221057`**: L3 가 릴레이 dedup client_id 를 암호화 AAD 에도 넣어 실 엔진에서 모든 수신이
     `sender attribution rejected`(파사드 H1). AAD client_id = 기기 ID 로 수정, Core 99/99.
   - macOS CI 1차(run 37593437387): 앱 컴파일·AppModelTests 통과, 시나리오 ③ 실패(위 결함 — Linux 하네스와 동일),
     Keychain 테스트 skip(`-34018`, 무서명 시뮬레이터) → 무서명 빌드의 live() 는 봉인 키 실패로 fatal.
4. [~] ③ 스모크(`finalizer/relay-smoke-276`, PR #322): 감독자 스크립트 · RelaySmokeTests · 워크플로.
   - macOS 1차(run 37595162269) 실패: **Go 릴레이가 darwin 에서 빌드 불가**(`internal/devicepolicy` 의 `syscall.Openat`/`Renameat`).
     서버 수정은 범위 밖(L2·보안 코드) → 스모크를 Linux 잡 `relay-smoke-linux`(`scripts/linux-smoke.sh`)로 옮김.
     macOS 잡은 실 엔진 + live 저장소 + 메모리 릴레이 시나리오(IntegrationTests)만.
   - Linux 로컬(실 Rust 엔진 = ios-ffi host .a + uniffi Swift 바인딩, 실 Go 릴레이 -access-mode disabled, `--network none`
     감독자 컨테이너에 Swift 컨테이너 합류): `[relay-smoke] PASS ①~⑤`, `Executed 17 tests, with 0 failures`, 릴레이 기동 2회.

## Linux 실 엔진 하네스 재현법 (리포 밖 /tmp, 재사용)

- Rust: `docker run --rm -e RUSTUP_TOOLCHAIN=1.91.1 -e CARGO_PROFILE_RELEASE_STRIP=false -e CARGO_TARGET_DIR=/x/target ... rust:1.91.1`
  → `cargo build --release --lib` + `uniffi-bindgen generate --library .../libfamily_mls_ios_ffi.so --language swift`
  (strip=true 면 .so 에 uniffi 메타데이터가 없어 생성 실패). 링크는 `.a` 만 둔 디렉터리로(.so 우선 선택 방지).
- Go 릴레이: `golang:1.27.1-bookworm`(python 컨테이너 glibc 와 호환) `go build`.
- 감독자: `python:3.12-slim-bookworm --network none`; Swift: `swift:6.0-noble --network container:<감독자>`.
- 하네스 /tmp/fc-e2e/run.sh: 앱 비UI 소스+테스트 복사, Combine·CryptoKit·App Group 스텁, ChaChaPolySealer → nil(Linux Passthrough).

## 통합 메모 (②)

- 새 파일: `FamilyChat/Sync/{SeededEngineFactory,RoomMembership}.swift`, `FamilyChat/App/LiveDependencies.swift`,
  `FamilyChatTests/{IntegrationTests,Support/{InMemoryRelay,LossyTransport,TwoDeviceScenario}}.swift`.
- AppModel: 방별 `RoomSyncEngine` 캐시 + `SerialAsyncQueue`(단일 호출자), 등록 판정 = `GET /v2/rooms` 403 device_subject_mismatch,
  401 → needsLogin, 404(확장 ① 없음) → 아는 방만. `markEnrolled` 제거(등록 확인 버튼 = refresh).
- live(): base = App Group(`FC_APP_GROUP`) → 없으면 Application Support/FamilyChat. 릴레이 URL = `FC_RELAY_URL`(Info.plist `FamilyChatRelayURL`). 실패 시 `startupFailure` → fatal.
- 앱 측 방 만들기/참여/초대 **화면은 없음**(§12-E) — API 만(`createRoom`·`requestJoin`·`invite`).
- 무서명 시뮬레이터 Keychain 은 테스트(`testKeychainSealKeyIsStableAcrossReads`)로 확인, -34018 이면 XCTSkip 으로 기록.

## §12-D 푸시 — 앱 쪽 (session `seoseo-push-d-20261007`, 오너 승인 2026-10-07 "3. 승인")

- 베이스 main `fe722c8`. 운영 릴레이(공융 배포 20:34 KST)는 등록 라우트 라이브·`-apns-key` 미설정(전송 꺼짐). 운영 서비스·`/opt/**`·DB 무접촉.
- Apple 자격(Team ID·Key ID·p8·Bundle ID·App Group·프로비저닝) 없음 → 서명·실 APNs·실기기 App Group 은 **증명하지 않은 것**으로 남긴다.
- PR 은 main 기준 독립 2개: **A `finalizer/push-registration-271`**(등록·전면 수신), **B `finalizer/nse-271`**(NSE·공유 저장·프로세스 간 정합).
  겹치는 파일(AppModel·Strings·project.yml)은 서로 다른 구역만 고친다 — 충돌 나면 먼저 머지된 쪽 위로 rebase.

### 읽은 것 (재독 불필요)
- 서버 `push.go`: `POST /v2/push/devices {device, apns_token(std base64), topic}` → 204(upsert, 토큰 교체), `DELETE ?device=` → 204(없어도).
  둘 다 `bindDevice`(JWT subject ↔ device) → 미등록 기기 403. topic = bundle id 형식(`[A-Za-z0-9.-]`, ≤155), `-apns-topics` 허용목록이면 400 `topic_not_allowed`.
  전송 대상 = 방 멤버(또는 커서 보유) 중 발신자 제외·커서 < seq, **application·welcome** 만(commit 은 안 보냄). 410/BadDeviceToken 이면 그 토큰만 삭제.
  페이로드 `{"aps":{"mutable-content":1,"alert":{"loc-key":"NEW_MESSAGE"},"thread-id":room},"room","seq"}`.
- Core `RelayTransport` 에 `registerPush`/`unregisterPush` 는 이미 있다(계약 §2.3) — `URLSessionRelayTransport` 만 404 고정. 계약 와이어 변경 없음.
- `RoomSyncEngine.syncOnce`: 커서를 **락 밖**에서 읽고 GET → flock 트랜잭션(복호화·`messages.db` 기록·상태 저장) → **unlock 뒤** `setCursor`.
  App·NSE 가 같은 커서로 같은 페이지를 받으면 뒤에 락을 잡은 쪽이 이미 처리된 application 을 **다시 decrypt** 한다(MLS 는 재복호화 불가 →
  거부 → 이미 행이 있어 `undecryptable` 은 안 쓰이지만 "중복 복호화" 이고 `rejected` 로 집계), 커서도 역행할 수 있다.
- L1 `KeychainSealKeySource` 에 접근 그룹이 없다 → App 과 NSE(앱 ID 다름)가 **봉인 키를 공유하지 못한다**. 자격증명(쿠키)도 메모리에만 있다.
- `DeviceIdentity` 는 `UserDefaults.standard` → NSE 가 기기 ID 를 못 읽는다.
- NSE 가 죽거나(24 MB) 시간을 넘기면 iOS 는 원래 alert(`loc-key NEW_MESSAGE`)를 보인다 → **앱 번들에 `NEW_MESSAGE` 현지화가 없으면 원문 키가 뜬다**.

### 결정
- **D4 NSE↔App 단일 작성자**: 같은 `RoomSyncEngine` 코드·같은 App Group `mls/<room>.lock` flock. 네트워크는 락 밖 그대로(앱이 공유 컨테이너 락을
  든 채 정지되면 0xdead10cc 로 죽는다 — 락 구간은 짧게). 정합은 Core 에서 닫는다: ① 트랜잭션 안에서 영속 커서를 **다시 읽고** 그 이하는 건너뜀
  ② `messages.db` 에 이미 있는 seq 의 application 은 **decrypt 하지 않음**(다른 프로세스가 처리 완료 — 행 기록은 상태 저장과 같은 락 안)
  ③ `setCursor` 는 단조(max). 이미 merge 된 타인 commit 의 재-stage 는 엔진이 에폭 불일치로 거부·복원(무해) — 커서 창이 닫힌 뒤엔 일어나지 않는다.
  `decryptedBy` 는 구성값(NSE = `.nse`) — 어느 프로세스가 복호화했는지 행에 남는다.
- **D5 대체 알림**: NSE 처리 = 기한 25 s(시스템 30 s) 경주 + `serviceExtensionTimeWillExpire` + 락 대기 3 s(identity·방 각각, CONTRACTS ≤5 s) +
  요청 타임아웃 10 s. 어느 실패든(페이로드 이상·자격 없음·신원 없음·방 모름·락 초과·네트워크·정지·해독 불가·해당 seq 없음) **"새 메시지가 도착했습니다"**.
  한 번만 전달(once 가드). 앱 번들 `ko.lproj/Localizable.strings` 에 `NEW_MESSAGE` 를 같은 문구로 — NSE 가 죽어도 빈손/원문 키 없음.
  제목 = actor(기기 ID 첫 `-` 앞), 봇(설정 `FC_AGENT_ACTORS`)이면 "🤖 actor". 본문 = 텍스트 / 첨부 「사진」(image/*)·「파일」.
- **D6 토큰 등록 정책**: `ready`(또는 halted — 등록된 기기) 진입 시 알림 권한 요청 → 허용이면 `registerForRemoteNotifications`.
  토큰 수신 → (device, token, topic) 이 마지막 성공과 다르거나, 로그인 뒤 첫 회이거나, 24시간이 지났으면 POST(멱등 upsert). 같으면 안 보냄.
  실패는 지수 백오프(1분→최대 1시간), 401 은 동기화와 같이 재로그인. 로그아웃 = DELETE(최선, 실패해도 로컬 기록 삭제 — 이후 푸시는 자격 없음 →
  대체 알림만). topic = Info.plist `FamilyChatPushTopic`(빌드 설정 `FC_PUSH_TOPIC`, 기본 `$(PRODUCT_BUNDLE_IDENTIFIER)`), 비면 등록 안 함.
- **D7 전면 억제**: `willPresent` 에서 앱이 active 면 표시 옵션 `[]` + 즉시 refresh·화면 갱신(인앱 표시). 백그라운드면 배너·목록·소리.
- **D8 공유 저장**: App Group 이 설정되면 기기 ID = App Group `UserDefaults`(표준 → 1회 이전), 봉인 키·자격증명 = Keychain 접근 그룹(App Group ID).
  자격증명은 로그인 시 Keychain 저장·시작 시 복원·로그아웃/401 시 삭제. 무서명 CI 에선 Keychain -34018 → 메모리 폴백(테스트는 주입).

### 수용(§12-D) — CI 로 증명할 것 / 못 하는 것
| 항목 | 증명 | 위치 |
|---|---|---|
| ① 실패·타임아웃·lock 경합 → 대체 알림 100% | XCTest(시뮬레이터) 표 전수 | B |
| ② App∥NSE 동시 처리 반복 → 상태 손상 0·중복 복호화 0 | Core Linux(결정적 인터리빙) + 시뮬레이터 실 엔진 반복 | B |
| ③ 실 엔진 NSE 경로 복호화 | 시뮬레이터 XCTest(IntegrationTests 패턴) + Linux 하네스 | B |
| ④ 등록 형식·멱등·DELETE | Core 요청 빌더(Linux) + 가짜 전송 XCTest | A |
| 실 APNs 10/10 도착·≥9 본문, 서명 빌드, 실기기 App Group·Keychain 공유, 24 MB 상한 | **증명 안 함**(Apple 자격·실기기) | 오너 준비 후 §12-F |

### 진행
