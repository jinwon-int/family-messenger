# NOTES-L3 — iOS L3 lane 작업 노트 (family-messenger #276 / #271, branch `lane/l3-sync-271`)

- 작업자: nosuk (session `nosuk-276-l3-20261005`, GLM) → **2026-10-07 Claude 인수** (session `nosuk-276-l3-claude-20261007`), GitHub 계정 seoseo-ai (`export GH_CONFIG_DIR=/root/.config/gh` 필요)
- 베이스: b459721 (feat(native-mls): iOS app skeleton … #278) → 2026-10-07 `origin/main` c85347c 로 rebase(무충돌, 레인 파일만).
- 오너 disk-first 지시(#276, 2026-10-06): **이미 읽은 파일 재독 금지** — 재개 시에는 이 NOTES + `git status`만 보고 시작. **파일 하나 끝날 때마다 commit+push**하고 #276에 `SHA + 파일 + swift-test 결과` 한 줄 코멘트.
- ~~로컬 swift 툴체인 없음~~ → **로컬 있음**: `export PATH=/root/swift-dl/extract/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH` 후 `cd archive/native-mls/ios/FamilyMLSCore && swift test`(빌드 포함 ~15s). 먼저 로컬, 그다음 CI.
- ⚠️ **CI 마스킹**: `native-mls-ios.yml` `swift-core-linux` 스텝이 `swift test … | tail -n 40`(pipefail 없음)이라 실패해도 green. 2026-10-07 로컬 첫 실행에서 bf0564c 는 컴파일 오류(exclusivity) + RelayTransportTests 2건 실패였는데 CI 는 green 이었다(#276 코멘트 6032687976). 워크플로는 레인 밖 → 수정은 파이널라이저/워크플로 소유자. **CI green 을 테스트 통과 증거로 쓰지 말고 로컬 결과를 기록할 것.**
- 커밋 컨벤션: conventional 제목 + rationale 본문.

## 읽기 완료 목록 (재독 금지 — 아래 요약이 유일 출처)

- `archive/native-mls/bot/src/policy.rs` L18–170: check_commit / parse_stage_report / roster_after 전체 알고리즘 (스켈레톤 이후 구현 커밋에서 벡터와 함께 포트).
- `RelayTransport` 프로토콜 시그니처: `postKeyPackages`, `consumeKeyPackage(room:device:target:)`, `postEvent`, `getEvents(room:device:after:limit:ack:)`, `closeRoom`, `listRooms`, `registerPush`, `unregisterPush`.
- `RelayTypes` public 타입(EventKind…PushPayload). `MlsEngine.swift`는 uniffi `MlsDevice`를 비추는 프로토콜.
- 기존 파일: `Store/InMemoryStateStore.swift`, `Tests/RelayTypesTests.swift`, `Tests/StateStoreContract.swift`.
- CONTRACTS 문서 위치: `archive/native-mls/ios/CONTRACTS.md` (주의: `archive/native-mls/CONTRACTS.md`는 없음 — 프롬프트 실패 확인됨).
- **아직 안 읽음**: `server.go`(consumeKeyPackage 쿼리 이름 확정에 필요 — transport 구현 직전 필독), `tests/fixtures/commit-policy-vectors.json`(테스트 작성 시 읽음; L2 소유, read-only).

## 설계 사실 (policy.rs / CONTRACTS에서 확정 — 구현 근거)

- roster 프레이밍: `u32le count` + 멤버마다 `u32le idLen ‖ id ‖ 32B key`. 잘림 → `nil`(Rust None).
- stage report = 4 섹션: adds / removes / updates / path.
- `roster_after = sorted-unique(roster − removes + adds)`.
- `check_commit(roster, committer, outer: Option)` → 기대 roster 또는 `Refusal{reason, detail}`.
- refusal 토큰(문자열 그대로): `committer_path`, `committer_mismatch`, `committer_not_member`, `unexpected_update_proposal`, `add_already_member`, `add_duplicate`, `remove_not_member`, `remove_duplicate`, `add_remove_overlap`, `outer_inner_mismatch`.
- 거부된 연산 → engine을 연산 직전 스냅샷으로 복원, outbox 항목 없음.
- encrypt 프레이밍: `u32le‖room‖u32le‖clientId‖plaintext` (engine/sync 쪽 — policy 아님).

## 제약

- 쓰기 허용(신규 파일만): `archive/native-mls/ios/FamilyMLSCore/Sources/FamilyMLSCore/{Relay/URLSession*,Sync/**,Policy/**}`, `Tests/FamilyMLSCoreTests/{Relay*,Sync*,Policy*}`.
- 편집 금지: `RelayTypes.swift`, `RelayTransport.swift`, `Store/**`, `Engine/**`, `project.yml`, workflows, relay server, `commit-policy-vectors.json`(L2 소유; 테스트에서 read-only).
- 벡터 fixture는 Swift 패키지 **외부**에 있음 → 테스트에서 `#filePath` 기준 상위 디렉터리 탐색으로 로드(전략 확정: #filePath에서 repo root까지 올라가며 `archive/native-mls/tests/fixtures/` 확인, 못 찾으면 탐색 경로를 실어 실패).

## 진행 계획 (하나 끝날 때마다 push + #276 SHA 코멘트)

1. [x] `Policy/CommitPolicy.swift` 빈 골격(타입+시그니처+TODO) + 본 NOTES — 이 커밋.
2. [x] CommitPolicy 구현 + `Tests/PolicyTests.swift` (벡터 로드 포함). — a48695c/6222d22(rebase 후 5e4e066/27c6f30), 로컬 9 cases 통과.
3. [x] `Relay/URLSessionRelayTransport` + 테스트 — bf0564c(rebase 후 389b2e2) + **a4b4fda 수정**(Swift 6 exclusivity 컴파일 오류, `.path` 이중 인코딩 → `percentEncodedPath`, pathComponent 를 RFC 3986 unreserved 로). 로컬 19 cases 통과. — **직전에 server.go를 읽어 consumeKeyPackage 쿼리 이름 확정**. 헤더: access cookie → `Cookie: CF_Authorization=…`, bearer → `Cf-Access-Jwt-Assertion`. 상태 매핑: 409 `cas_mismatch`→`.cas(epoch,revision)`, 401→`.unauthorized`, 403 코드→`.refused`, 미구현 확장①②→404→`.refused('not_found')`.
4. [x] `Sync/RoomSyncEngine` + fake engine/transport + InMemory store 테스트 — b4435b5 · 7c3e8f4(SyncFakes) · d51c8cf(SyncEngineTests 30건):
    - own-commit echo→merge_pending; Welcome→join; 타 커밋→stage_commit→policy ①~④→merge_staged | discard_staged+⛔halt(`RoomRecord.haltedReason`).
    - application→decrypt→MessageStore.insert; cursor는 persist **후에만** set → 이후 `?ack=`.
    - `first_seq > cursor+1` → halt `'history_gap'`.
    - send: encrypt→outbox 정확 바이트→POST; 409→clear_pending→sync→**새 client_id로 재암호화**(旧 항목 정합/reconcile); 200 duplicate=정확 바이트 재시도.
    - GET 페이지 1개 = 트랜잭션 1개(load→ops→save); `withExclusive` 내부 네트워크 호출 금지 가드 테스트; 포그라운드 4s 폴링.
5. [x] 등록 플로우(`Sync/Enrollment.swift` + SyncEnrollmentTests 6건): 403 `device_subject_mismatch` → 'operator registration pending' + enrollment JSON(`device_id`,`actor`,`subject`,`signing_key`,`fingerprint`) per relay-app §1.

## 구현 결정 (4·5번, 2026-10-07)

- 엔진 인스턴스: 트랜잭션마다 `tx.generation` 이 캐시와 같으면 재사용, 다르면(NSE 가 사이에 씀) `importState`. 상태 없음 → `create` 후 **즉시 저장**(등록 JSON 의 서명키 고정).
- 참여 여부 = 엔진 `members` roster 에 내 ID(별도 영속 없음). `members` 는 L2 추가분 — ios-ffi 는 `policy_wire` 로 이미 라우팅. `.invalid` 면 throw.
- 거부된 commit 은 커서가 지나가지 않는다(그 앞에 머묾). poison(엔진 `.rejected`)은 보고 후 지나감(봇과 같음). 해독 불가·발신자 불일치(`sender_mismatch`)는 `undecryptable` 행.
- MessageStore insert 는 트랜잭션 안(save 전), 이미 있는 seq 는 건너뜀 → save 실패 후 재처리 안전. 커서·RoomRecord 는 save 뒤.
- 송신 전 `syncAll`(relay-app `send` 와 같음). 등록 대기·정지 중엔 ratchet 을 쓰기 전에 throw.
- 403 `device_subject_mismatch` = 등록 대기(영속 X, 매 폴링 재시도), 410/403 `room_closed` = ⛔, 404 `no_such_room` = 볼 것 없음, ack 거부(400 bad_ack / 403 not_a_member + ack) = ack 만 끔.
- 재시작 후 평문 없는 pending 항목이 409 → reconciled(`SendOutcome.reconciled`) — 재암호화 불가, 화면이 알릴 것(파이널라이저).

## 증명하지 않은 것 (PR 본문에도)

- 실 릴레이 왕복(격리 릴레이 `-access-mode disabled` 스모크, §2.4 두 번째 항목) — Linux 에 xcframework 없음, macOS job/수동 필요.
- `URLSessionRelayTransport.perform()` 실제 HTTP 왕복(Linux URLProtocol 제약으로 순수 함수만 테스트).
- 실 MLS 엔진(ios-ffi)과의 결합 — 전부 가짜 엔진. 특히 `members` 가 그룹 없을 때 `.rejected` 를 던진다는 가정.
- 첨부(attachment) 수신 분기 없음(text 만), 키 패키지 발행·초대(내 commit 생성) 흐름은 범위 밖.

## 머지/PR 계획

- 머지 순서 3 (InMemory store — L1 불필요).
- PR 본문에 **added/deleted 라인 수 + CI minutes** 포함 필수.
- 리뷰: seoseo-ai 릴레이 exact-head 승인 → 머지큐 enqueue.
- #276 클레임 코멘트 게시됨 (node=nosuk, session=nosuk-276-l3-20261005).
