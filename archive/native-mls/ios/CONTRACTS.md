# iOS 독자 E2EE 앱 — 계약 동결 (#271 §12 B~E, 3레인 병렬 구현)

> **상태: 동결 (2026-10-05, 오너 결정 "1": 3레인 병렬).** 이 문서와 `FamilyMLSCore/` 의 프로토콜·타입·계약 테스트가
> 레인 간 경계다. 바꾸려면 **이 문서를 고치는 PR 을 먼저** 올리고 세 레인이 그 PR 에 코멘트한다. 설계 전문은
> [#271](https://github.com/jinwon-int/family-messenger/issues/271), 독자 트랙 설계 [#177](https://github.com/jinwon-int/family-messenger/issues/177),
> 스파이크 A 결과 [#272](https://github.com/jinwon-int/family-messenger/pull/272).

## 0. 레인·소유권·통합 순서

| 레인 | 범위(#271) | **쓰기 허용 경로(이 밖은 금지)** | 검증 | 머지 순서 |
|---|---|---|---|---|
| **L1 Swift 저장** | §12-B | `ios/FamilyMLSCore/Sources/FamilyMLSCore/Store/File*`, `ios/FamilyMLSCore/Tests/FamilyMLSCoreTests/File*` (새 파일만; `StateStore.swift`·`InMemory*`·`MessageRecord.swift` 수정 금지) | `StateStoreContract.run` 통과 + 결함 주입(§3.5) · Linux `swift test` + macOS job | 1 |
| **L2 백엔드** | 파사드 `Session` 공개 API + 릴레이 확장 ①② | `archive/experiments/openmls-browser/src/**`, `archive/native-mls/ios-ffi/**`, `archive/native-mls/server/**`, `archive/native-mls/tests/**`(Go/Python 스모크) | 파사드 host/wasm 테스트 · ios-ffi host 테스트 · Go 테스트 · `native-mls.yml`/`native-mls-ios.yml` | 2 (L1 과 독립, 순서는 리뷰 편의) |
| **L3 Swift 프로토콜** | §12-C 네트워크·동기화·commit 정책 | `ios/FamilyMLSCore/Sources/FamilyMLSCore/{Relay/URLSession*,Sync/**,Policy/**}`, `ios/FamilyMLSCore/Tests/FamilyMLSCoreTests/{Relay*,Sync*,Policy*}` (새 파일만; `RelayTypes.swift`·`RelayTransport.swift` 수정 금지) | Linux `swift test`(가짜 엔진·InMemory 스토어·가짜 전송) + 격리 릴레이 스모크(§2.4) | 3 |
| **파이널라이저**(1인) | 통합 + §12-D 푸시/NSE + §12-E 화면 | `ios/FamilyMLSSpike/**` → 제품 앱 트리, `ios/project.yml`, `.github/workflows/**`, 이 문서 | macOS job 전체 | L1→L2→L3 뒤 |

- 공통 금지: 운영 서버·실계정·실제 도메인/호스트명(CONTRIBUTING). 비밀값은 Keychain/서버 root-only, 코드·로그·픽스처에 없음.
- 세 레인 모두 **이슈 claim 규칙**(DOC-3508)을 따르고, PR 본문에 "삭제/추가 줄 수·CI 분"을 적는다(#177 관례).
- 공유 픽스처 `archive/native-mls/tests/fixtures/commit-policy-vectors.json` 은 **L2 만** 수정(웹·봇·iOS 3구현이 함께 돌린다).

## 1. 엔진 경계 — `MlsEngine` / `Framing` (`Engine/`)

- `MlsEngine.dispatch(_ method: EngineMethod, _ input: Data) throws -> Data` = ios-ffi `MlsDevice.dispatch(method:input:)`. 메서드 wire 이름은 `EngineMethod.rawValue`(durable-worker `allowed` 와 동일).
- 실패 계약: `.rejected` 뒤 엔진은 **연산 전 스냅샷으로 복원**돼 있다(ios-ffi 가 보장). 호스트는 `.rejected` 를 받으면 그 연산의 outbox 항목을 만들지 않는다.
- 프레이밍은 `Framing` 하나로만(봇 테스트와 동일): encrypt 입력 `u32le‖room‖u32le‖client_id‖plaintext`, decrypt 입력 `u32le‖room‖ciphertext`, decrypt 출력 format **2**. 앱은 시작 시 `decrypt_format()==2` 를 확인하고 아니면 중단.
- **L2 추가분**(§2.1 전까지 엔진은 `.invalid`): `members`, `members_after_pending`, `policy_fingerprint(signing_key_hex utf8) -> fingerprint utf8`, `sign_approval(json utf8) -> framed signature bytes` — 입력·출력 바이트 형식은 `web/durable-worker.js` 가 보내고 받는 것과 **동일**(relay-app `enroll.js` 의 `sign_approval` 인자 JSON 그대로).

## 2. 릴레이 경계 — `RelayTransport` / `RelayTypes` (`Relay/`)

### 2.1 와이어(동결, server.go 2026-10-05 main)
| 호출 | 요청 | 응답 | 오류 |
|---|---|---|---|
| `POST /v2/rooms/{r}/keypackages` | `KeyPackagePost{device, packages[{ref=sha256hex, bytes}]}` | `KeyPackagesResponse{stored, duplicates}` | 401/403 |
| `GET /v2/rooms/{r}/keypackages?…` | 소비하는 기기·상대 기기 (쿼리명은 L3 가 server.go `handleConsumeKeyPackage` 로 확정해 `URLSessionRelayTransport` 에 고정) | `StoredKeyPackage{ref, bytes, expires_at}` 또는 404 | |
| `POST /v2/rooms/{r}/events` | `EventPost{device, client_id, kind, epoch, revision?, group_id?, targets?, members?, bytes}` | 201 `EventPostResponse{seq, epoch, revision, duplicate:false}` · 200 `duplicate:true`(정확 바이트 재전송) | 409 `{"error":"cas_mismatch",epoch,revision}` → `RelayError.cas` · 403 `not_a_member`/`device_subject_mismatch`/`room_closed` → `.refused` |
| `GET /v2/rooms/{r}/events?device=&after=&limit=&ack=` | | `EventsPage{epoch, revision, events[StoredEvent], next_after, cursor?, first_seq?, members?}` | |
| `POST /v2/rooms/{r}/close` | | 204 | |
| 인증 | `RelayCredential.accessCookie` → `Cookie: CF_Authorization=…` / `.bearer` → `Cf-Access-Jwt-Assertion` | 401 → `.unauthorized` | |

### 2.2 클라이언트 규칙(L3 가 구현, 테스트로 고정)
- 수신 처리 순서(relay-app §3 = 봇): 내 commit echo → `merge_pending`; Welcome(참여 전) → `join`; 타인 commit → `stage_commit` → **commit 정책 검사 ①~④**(`web/commit-policy.js` 를 Swift 로 포팅, 픽스처 공유) → `merge_staged` / 위반 `discard_staged` + ⛔ 정지(`RoomRecord.haltedReason`); application → `decrypt` → `MessageStore.insert`.
- 처리·영속이 끝난 seq 만 `CursorStore.setCursor` 하고 다음 GET 의 `?ack=` 로 보낸다. `first_seq > cursor+1` → 정지 사유 `history_gap`.
- 송신: `encrypt` → `OutboxStore.enqueue`(정확 바이트) → POST. 409 → `clear_pending` → 동기화 → **새 client_id 로 재암호화**, 옛 항목 `reconciled`. 재시도는 항상 같은 바이트.
- **네트워크는 `withExclusive` 밖**. 엔진 연산과 상태 저장은 안. (수신 1페이지 = 트랜잭션 1개: load → 연산들 → save.)
- 전면 폴링 4초, 백그라운드는 푸시 wake(파이널라이저).

### 2.3 확장 ①② (L2 서버)
- `GET /v2/rooms?device=` → `RoomsResponse{rooms[RoomListing{room, epoch, revision, member, keypackages_outstanding, closed}]}` — JWT subject 의 기기만. 공개 정보만.
- `POST /v2/push/devices` `PushRegistration{device, apns_token(base64), topic}` → 204, 멱등. `DELETE /v2/push/devices?device=` → 204. events insert 트랜잭션 **밖**에서 APNs HTTP/2(p8) 전송, 페이로드 `{"aps":{"mutable-content":1,"alert":{"loc-key":"NEW_MESSAGE"},"thread-id":"<room>"},"room":"<room>","seq":N}`. 토큰·p8 은 리포 밖. Go 테이블 `push_devices(device PK, token, topic, updated_at)`.
- 오너 결정 §14-2 = **허용**(2026-10-05, 3레인 선택에 포함). Bundle ID 는 미정 → `topic` 은 설정값.

### 2.4 L3 수용
- 가짜 전송·가짜 엔진으로 Linux `swift test`: 정책 벡터 전부, 409 재암호화, 정확 바이트 재시도, 커서/ack, history_gap 정지.
- 격리 릴레이(`-access-mode disabled`, loopback) 스모크: relay-app 스모크와 같은 시나리오(초대→참여→양방향→릴레이 중단/재시작→재전송 200 duplicate). 실행은 macOS job 또는 수동(Linux 에선 Swift+xcframework 불가) — 최소한 벡터·전송 디코딩은 Linux 에서.

## 3. 저장 경계 — `MlsStateStore` 등 (`Store/`)

### 3.1 파일 구현(L1) 요구
- 경로: App Group 컨테이너 `mls/<room>.state`(봉인 바이트), `mls/<room>.lock`(0바이트, flock 앵커), `mls/<room>.gen`(generation, 원자 교체), `messages.db`(SQLite, §4).
- 잠금: `flock(LOCK_EX)` on `<room>.lock`, `timeout` 은 폴링(50 ms)으로. 재진입은 오류. **NSE 는 timeout 짧게(≤5 s)** — 못 얻으면 대체 알림(파이널라이저).
- 원자 영속: `<room>.state.tmp` 쓰기 → `fsync` → `rename` → 디렉터리 `fsync` → `.gen` 갱신. 봇 `persist_state` 와 동일.
- 봉인: 평문 `export_state` → libsodium secretstream(또는 CryptoKit `ChaChaPoly` — **둘 중 하나로 L1 이 결정·기록**, 직접 만든 KDF/nonce 금지) 키 = Keychain 32B(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, iCloud 금지). 파일 보호 `.completeUntilFirstUserAuthentication`.
- 무결성: 파사드 record HMAC 은 바이트 안에 이미 있음; 파일 레벨은 봉인의 AEAD 태그로 충분.

### 3.2 계약 테스트
`Tests/FamilyMLSCoreTests/StateStoreContract.swift` 의 `StateStoreContract.run(label:makePair:)` 를 **그대로** 호출(InMemory 가 기준). `makePair` = 같은 디렉터리를 여는 두 스토어 인스턴스(두 프로세스 대역).

### 3.3 결함 주입(L1 추가 테스트, PERSISTENCE.md 26검사 대응)
abort-before-write · abort-after-tmp-before-rename · abort-after-rename-before-gen · 손상 파일(봉인 태그 불일치 → `sealing`) · 잠금 보유 중 프로세스 "죽음"(flock 은 fd 닫히면 해제 — 테스트로 증명) · 두 인스턴스 교대 쓰기 1,000회 generation 단조 증가.

### 3.4 호출자 규칙
트랜잭션 안: `load` → 엔진 연산 → `save`. 밖: 네트워크·UI. 연산이 `.rejected` 면 `save` 하지 않고 throw(디스크 불변).

## 4. 메시지 보관 — `MessageStore` / `MessageSchema.ddl` (`Store/MessageRecord.swift`)
DDL v1 동결(`schema_version`). `messages(room, seq)` PK, `rooms.halted_reason`, `outbox(room, client_id)` PK + `sha256`, `cursors`. L1 이 SQLite(`sqlite3` C API, 의존 0)로 구현하고 `MessageStore`·`OutboxStore`·`CursorStore` 를 **한 DB** 에 둔다(Data Protection 동일).

## 5. CI 예산
- `native-mls-ios.yml`: `swift-core-linux` ≤10분(순수 Swift) · `ios-ffi-host` ≤15분 · `ios-build` ≤25분. 경로 필터로 무관한 PR 은 스킵.
- L2 는 `native-mls.yml`(≤25분)·`native-mls-bot`(≤15분) 안에서.

## 6. 기록된 결정
- 2026-10-05 오너: 3레인 병렬(1번). §14-2 릴레이 확장 허용. 인증 기본 A(쿠키), 파일럿 B 폴백 허용. Bundle ID 미정(설정값).
- 파이널라이저 = bangtong(오너가 바꿀 수 있음).
- 2026-10-05 오너 배정: **L1 = soonwook(순욱) · L2 = gwakga(곽가) · L3 = nosuk(노숙)**. 레인 이슈 #274 / #275 / #276. L2 는 제안이 그대로 채택된 것이며 고정은 아니다(Linux 로컬 컴파일이 가능한 유일한 레인).
