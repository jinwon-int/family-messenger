# NOTES-L3 — iOS L3 lane 작업 노트 (family-messenger #276 / #271, branch `lane/l3-sync-271`)

- 작업자: nosuk (session `nosuk-276-l3-20261005`), GitHub 계정 seoseo-ai (`export GH_CONFIG_DIR=/root/.config/gh` 필요)
- 베이스: b459721 (feat(native-mls): iOS app skeleton … #278)
- 오너 disk-first 지시(#276, 2026-10-06): **이미 읽은 파일 재독 금지** — 재개 시에는 이 NOTES + `git status`만 보고 시작. **파일 하나 끝날 때마다 commit+push**하고 #276에 `SHA + 파일 + swift-test 결과` 한 줄 코멘트.
- 로컬 swift 툴체인 없음(`swift: command not found`) → 검증은 CI `swift-core-linux`만 (예산 ≤10min).
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
2. [ ] CommitPolicy 구현 + `Tests/PolicyTests.swift` (벡터 로드 포함).
3. [ ] `Relay/URLSessionRelayTransport` + 테스트 — **직전에 server.go를 읽어 consumeKeyPackage 쿼리 이름 확정**. 헤더: access cookie → `Cookie: CF_Authorization=…`, bearer → `Cf-Access-Jwt-Assertion`. 상태 매핑: 409 `cas_mismatch`→`.cas(epoch,revision)`, 401→`.unauthorized`, 403 코드→`.refused`, 미구현 확장①②→404→`.refused('not_found')`.
4. [ ] `Sync/RoomSyncEngine` + fake engine/transport + InMemory store 테스트:
    - own-commit echo→merge_pending; Welcome→join; 타 커밋→stage_commit→policy ①~④→merge_staged | discard_staged+⛔halt(`RoomRecord.haltedReason`).
    - application→decrypt→MessageStore.insert; cursor는 persist **후에만** set → 이후 `?ack=`.
    - `first_seq > cursor+1` → halt `'history_gap'`.
    - send: encrypt→outbox 정확 바이트→POST; 409→clear_pending→sync→**새 client_id로 재암호화**(旧 항목 정합/reconcile); 200 duplicate=정확 바이트 재시도.
    - GET 페이지 1개 = 트랜잭션 1개(load→ops→save); `withExclusive` 내부 네트워크 호출 금지 가드 테스트; 포그라운드 4s 폴링.
5. [ ] 등록 플로우: 403 `device_subject_mismatch` → 'operator registration pending' + enrollment JSON(`device_id`,`actor`,`subject`,`signing_key`,`fingerprint`) per relay-app §1.

## 머지/PR 계획

- 머지 순서 3 (InMemory store — L1 불필요).
- PR 본문에 **added/deleted 라인 수 + CI minutes** 포함 필수.
- 리뷰: seoseo-ai 릴레이 exact-head 승인 → 머지큐 enqueue.
- #276 클레임 코멘트 게시됨 (node=nosuk, session=nosuk-276-l3-20261005).
