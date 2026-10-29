# 호스트 계약 — Rust 코어가 하는 일 / 호스트가 하는 일 (#366 3b · #338 §5)

> **범위**: 모바일 호스트 중 **Rust 중심** 트랙(Android 먼저, 오너 결정 2026-10-15). iOS 는 [`ios/CONTRACTS.md`](ios/CONTRACTS.md) 동결 계약(Swift 코어)을 그대로 두며 이 문서의 대상이 아니다.
> 코어 = `host-core`(`native-mls-host`: 와이어·정책·방 규칙·동기화·송신) + `ios-ffi`(`family-mls-ios-ffi`: 파사드 `Device` 와 `MlsRoom` 을 uniffi 로 노출). 설계 근거 [#366 3단계 설계](https://github.com/jinwon-int/family-messenger/issues/366#issuecomment-6260278788).

## 1. 책임 분담

| 층 | Rust 코어(`MlsRoom`) | 호스트(Kotlin) |
|---|---|---|
| MLS(그룹·AAD·commit 정책·record 코덱) | 파사드 — 호스트 재작성 **0줄** | — |
| 와이어(경로·쿼리·JSON·오류 봉투·CF Access 헤더) | `host-core api` | — |
| HTTP 바이트 전송(TLS·프록시·타임아웃) | — | `HttpTransport`(OkHttp/`HttpURLConnection`) |
| 동기화 상태기계(ack·GET·gap·welcome/commit/application 순서) | `room::poll` | `poll()` 호출 주기(전면 4 s · 백그라운드 FCM wake) |
| 송신(암호화 → dedup 키 → 영속 → POST · 409 재시도 ≤8) | `room::send_application` | `send()` 호출·결과 표시 |
| 자기 commit echo → merge · 초대 Welcome 게시 순서 | `own_event` · `postCommit`/`postWelcome` | 초대 흐름의 호출 순서(§2) |
| 프레이밍(encrypt/decrypt) · dedup client_id(`<identity>-<8 hex>`) | 코어 | — |
| 영속(그룹 상태 + 동기화 위치, 원자 쓰기) · 봉인(Keystore) | `persist` 콜백 **호출 시점** 보장 | `RoomObserver.persist` 구현(§4) |
| 정지(거부 commit · 잘린 이력) 판정 | 코어 | `halted` 마커 영속 · 화면 |
| 메시지 저장·표시 · 첨부 판정(`client_id` `file-v1-…`) · 알림 | — | `RoomObserver.application` |
| 로그 | 이벤트 어휘(§3) | `RoomObserver.event` 싱크 |

단일 작성자: Android 앱은 프로세스 1개(NSE 같은 2번째 프로세스 없음). `MlsRoom` 메서드는 내부 Mutex 로 직렬화되므로 호스트는 같은 방의 `MlsRoom` 인스턴스를 **하나만** 들고 여러 스레드에서 호출해도 된다. 같은 방 상태 파일을 두 인스턴스가 쓰는 것은 금지.

## 2. `MlsRoom` API (uniffi Kotlin: `com.seoyoon_family.hande.mls`)

| 호출 | 하는 일 | 규칙 |
|---|---|---|
| `MlsRoom(identity, room, baseUrl, transport, observer)` | 새 신원·새 방(그룹 없음) | `identity` = `actor-device` 모양, `room` 은 식별자(영숫자 `_-`, ≤64) |
| `MlsRoom.import(identity, room, state, sync, …)` | `persist` 가 받은 두 값으로 복원 | `sync.room == room` 아니면 `Host` 오류 · `halted` 는 그대로 복원(정지 유지) |
| `MlsRoom.adopt(identity, room, state, after, …)` (3c) | **다른 상태로 방을 시작** — 로비 시드로 방을 만들 때(`after` = 0) · 로비 key package 로 받은 Welcome 을 열 때(`after` = `seq - 1`) | 그룹 없음(`dispatch("create")` 또는 Welcome `poll`) · 돌아오기 전에 `persist` 1회 · **방은 전부 `MlsLobby.seedState()` 에서 시작**해야 서명키가 하나다(`new` 는 새 키를 만든다 — 테스트 대역 전용) |
| `poll()` | 동기화 한 바퀴(ack → GET → gap → 이벤트 순서 처리) → 상태가 움직였으면 `persist` | `Relay{transient}` 면 백오프 뒤 재호출(0.5 s → 30 s) · 정지된 방은 아무것도 안 함 |
| `send(plaintext)` → `Sent | Queued | AlreadyDelivered` | 암호화 → dedup 키 예약 → **`persist`** → POST(epoch) | `Queued` = 409 cas_mismatch, 다음 `poll` 뒤 자동 재전송(≤8회, `Replayed`/`Dropped` 이벤트) |
| `dispatch(method, bytes)` | `MlsDevice.dispatch` 와 같은 진입점·같은 롤백(create · key_package · invite_with_commit · remove_pending …) | 성공하면 **즉시 `persist`**(돌려받은 바이트가 릴레이로 나가기 전에 디스크에) · `create`/`join` 은 joined |
| `postCommit(commit)` · `postWelcome(welcome, targets)` | 이 기기가 만든 commit / Welcome 게시 | 초대: `dispatch("invite_with_commit", kp)` → `u32le len‖commit‖welcome` 분리 → `postCommit` → `poll` 이 `OwnCommitMerged` 를 알리면 → `postWelcome(welcome, [대상])` |
| `exportState()` · `syncState()` | 수동 스냅샷(디버그·백업) | 영속의 정본은 `persist` 콜백 |
| `setAccessToken(token?)` | CF Access 토큰 교체 | 코어가 `Cf-Access-Jwt-Assertion` 헤더를 넣는다 — 전송 구현은 인증을 몰라도 된다 |
| `closeRoom()` → `Boolean` (3c) | `POST /v2/rooms/{r}/close` — 방을 닫는다(멤버 전원 410 `room_closed`) | 참 = 닫혔다(이미 닫혀 있어도) · 거짓 = 릴레이에 그 방이 없다 · 403 `not_a_member` 는 `Relay` 오류 · 로컬 상태 버리기는 호스트 몫 |
| `readSeq()` → `Long` (#571 후속) | 릴레이가 아는 **같은 사람(actor)의** 읽음 위치 — `poll` 의 `GET /events` `read_seq` 와 `markRead` 응답의 max | 영속하지 않는다(재시작 뒤 첫 `poll` 전에는 0) → 호스트는 자기 로컬 값(`Settings.readSeq`)과 `max` 로 합쳐 안 읽음을 판정한다(`Unread.isUnread`: 마지막 글이 남의 글이고 그 위치보다 뒤) · 옛 릴레이는 늘 0 · MLS 커서·ack 와 무관 |
| `markRead(seq)` → `Long` (#571 후속) | `POST /v2/rooms/{r}/read {device, seq}` — 이 기기가 `seq` 까지 봤다. 돌아오는 값 = 릴레이의 actor 단위 결과(`seq` 보다 클 수 있다) | 이미 아는 위치 이하면 보내지 않음 · 옛 릴레이(봉투 없는 404)·404 `no_such_room` 은 **무시**(알던 값 반환) · 410/403/400 `bad_seq`·전송 실패는 `Relay` 오류 — 안내 신호이므로 호스트는 로그만 남긴다 · 시점 = 방을 열 때·보는 중 마지막 seq 가 움직일 때(웹 `room.js markRead` 와 같음) |
| `invite(target)` → `MlsInvite` (#574) | 형제 기기 초대(봇 `invite`·웹 `room.js invite` 순서): 대상 key package 를 방 풀(`GET /v2/rooms/{r}/keypackages`) → 로비(`GET /v2/lobby/keypackages?room=`) 순으로 소비 → `invite_with_commit` → 대기 Welcome 을 `sync.pendingInvite` 에 싣고 **`persist`** → commit 게시 → `poll`(자기 echo merge) → Welcome 을 대상에게만 게시 | `Invited{commitSeq, welcomeSeq, epoch}` = 끝 · `Posted{commitSeq}` = echo 가 이 페이지에 없었다(Welcome 은 다음 `poll` 의 `after_page` 가 올린다; 전송 실패도 거기서 재시도) · `NoKeyPackage`(새 기기는 활성이 된 뒤 첫 틱에야 로비 키를 올린다) · `Pending`(내 commit 또는 대기 Welcome) · `Raced`(409 cas_mismatch — 대기 commit 을 버렸다) 는 **다음 틱에 다시** · 참여 전·정지된 방·식별자 위반은 `Host` 오류 · **대기 Welcome 은 영속된다**(#574 후속: `RoomSyncState.pendingInvite{commitSeq, targets, welcome}` — commit 이 나가기 전에 디스크에; 재시작한 `poll` 이 echo 를 merge 하면 올리고, commit 이 merge 없이 사라졌으면(릴레이에 닿지 않은 commit 을 외부 commit 이 지움·merge 거부) `WelcomeDropped{commitSeq, targets}` 로 버린다 → 호스트 대기열이 다시 초대) |

## 2b. `MlsLobby` API — 기기 수준(방 무관) 호출 (3c · #574)

한 기기에 하나. 로비 key package(#380 P5, iOS `LobbyKeyring` 과 같은 규칙) · 방 목록 · 푸시 등록 · 기기 셀프서비스(#574: `/v2/me` · 후보 우편함 · 승인 · 역할 — 서명은 로비 상태의 서명키, 즉 등록 JSON 의 `signing_key`). 영속은 `LobbyObserver.persist(slot)` 한 콜백(`MlsLobbySlot{state, published}` 를 통째로 원자 저장 — `FileLobbyStore`). 셀프서비스 호출의 거절은 오류가 아니라 **값**(`Refused{refusal}`): 다음 행동이 상태코드·코드로 갈리기 때문(웹 `{status, body}` 와 같은 뜻); 전송 실패·JSON 오류만 `RoomException`.

| 호출 | 하는 일 | 규칙 |
|---|---|---|
| `MlsLobby(identity, baseUrl, transport, observer)` | 새 기기 신원(서명키 생성) | 돌아오기 전에 `persist` 1회. **이 상태가 기기의 시드**: 등록 JSON `signing_key` = `publicKey()` hex, 방은 전부 `adopt(…, seedState(), 0, …)` 로 만든다 |
| `MlsLobby.import(identity, slot, …)` | 영속된 슬롯으로 복원 | — |
| `replenish(target)` → `MlsLobbyReport{live, max, minted, pruned}` | 서버 `live` < `min(target, 서버 max)` 면 부족분을 만들어 게시. 먼저 장부 앞쪽(소비·만료분)의 로컬 비밀을 지운다 | 비밀은 **게시 전에** `persist`(persist-before-bytes-leave) · 게시 실패 시 새 비밀은 바로 지움 · 파사드 상한(8)에 닿으면 멈춤(오류 아님) · 옛 릴레이(로비 없음)는 404 `Relay(transient=false)` → 호스트가 건너뜀. 시점 = 시작·포그라운드·방 참여 뒤(iOS 와 같음), 기본 target 8 |
| `welcomes()` → `[MlsLobbyWelcome{room, seq, epoch, createdAt, from, keyPackageRef}]` | 아직 읽지 않은 Welcome 이 있는 방들. `from` = 올린 기기(#574, 옛 릴레이는 빈값) · `keyPackageRef` = 만든 로비 키의 ref(#380, 없으면 빈값) | 모르는 방이면 `MlsRoom.adopt(identity, room, seedState(), seq - 1, …)` → `poll` 이 join · 이미 멤버인 방은 그 방의 `poll` 이 `WelcomeIgnored` · `from` 이 `/v2/me` 의 같은 actor 활성 기기면 형제 기기의 초대(`SelfService.isSibling`) — 묻지 않고 받는다 |
| `me()` → `MlsMe{subject, policyRevision?, devices[]}` (#574) | `GET /v2/me` — 검증된 JWT subject(등록 JSON 의 보조 출처) · 기기 저장소가 있는 릴레이는 정책 revision(= 서명할 `base_revision`) 과 내 subject 의 기기 전부 `{deviceId, actor, fingerprint, status, acceptance, roles}` | 옛 릴레이는 `{subject}` 만 → `policyRevision` null · `devices` 빈 목록 · 봉투 없는 404(호출자 인증 꺼짐) 는 `Relay` 오류 — 호스트가 「셀프서비스 없음」으로 기억 · 401 은 세션 필요 |
| `postCandidate()` → `MlsCandidatePost` (#574) | `POST /v2/devices/candidates {device_id, actor, signing_key, fingerprint}`(strict, **subject 없음** — 릴레이가 JWT 에서) — 체인에 없는 이 기기가 자기 공개 기록을 우편함에 | `Posted{fingerprint, policyRevision, expiresAt(초)}` = 형제 기기가 승인한다(만료 5분 전에 다시) · `Refused{refusal{status, code, detail, revision?}}`: 409 `device_exists` = ID 사용 불가 · 403 `first_device_out_of_band`/봉투 없는 404(옛 릴레이) = 운영자 흐름 |
| `listCandidates()` → `MlsCandidateList` (#574) | `GET /v2/devices/candidates?device=<나>` — 내 subject 의 우편함 | `Listed{policyRevision, candidates[{deviceId, actor, subject, signingKey, fingerprint, createdAt, expiresAt}]}` · 체인에 없는 기기는 403 `Refused` · 호스트는 `SelfService.canApprove`(활성 + registrar 이거나 actor 에 registrar 없음) 일 때만 묻는다 |
| `approve(candidate, baseRevision)` → `MlsPolicyCommit` (#574 E2) | ① `policy_fingerprint(signing_key)` 로 지문을 **다시 계산**해 후보의 지문과 다르면 `Mls("candidate fingerprint mismatch")` ② `sign_approval{action:"approve-device", device_id, actor, subject, signing_key, acceptance:"trusted-device-fingerprint", base_revision}` ③ `POST /v2/devices/approvals`(AddDeviceEvidence + `signature`·`fingerprint`·`approved_by`) | `Committed{deviceId, approvedBy, revision}` · `Refused`: 409 `stale_revision`(`refusal.revision` 으로 호스트가 **한 번** 다시) · 403 `approval_rejected`(`detail` = registrar 아님 등) · 사람의 대역외 지문 비교는 이 호출 **앞** 에서 화면이 한다 |
| `setRoles(deviceId, actor, roles, baseRevision)` → `MlsPolicyCommit` (#574 E5) | `roles` = 대상의 **완전한** 목록(정렬·중복 제거는 코어) → `sign_roles` → `POST /v2/devices/roles` | `Committed{…, roles}` · 409 는 호스트가 `/v2/me` 를 다시 읽고(대상의 역할도 움직였을 수 있다) 한 번 다시 · 마지막 registrar 해제는 403 `detail` |
| `dispatch(method, bytes)` (#574) | 파사드 정책 메서드 `policy_fingerprint`·`sign_approval`·`sign_roles` 를 기기 서명키로 직접(`MlsDevice.dispatch` 와 같은 바이트, `policy_wire`) | 그 밖의 메서드(`key_package`·`create`·`members`…)는 `Invalid` — 그룹·key package 연산은 방·`replenish` 의 몫 |
| `withdraw()` → 거둔 개수 | `DELETE /v2/lobby/keypackages` + 로컬 비밀 삭제(#389, 「이 기기 지우기」 직전) | — |
| `status()` · `publishedCount()` · `slot()` · `seedState()` · `publicKey()` | 화면·등록·백업 | 영속의 정본은 `persist` |
| `rooms()` → `[MlsRoomListing]` | `GET /v2/rooms?device=` — 참여 방 목록(공개 필드만) | 방 목록 화면의 정본은 **로컬 상태 파일**; 이 목록은 새 방 발견·닫힘 표시용 |
| `registerPush(token, topic)` · `unregisterPush()` | `/v2/push/devices` | `topic` = 패키지 id(`com.seoyoon_family.familychat`) · 와이어 필드는 오늘 `apns_token`(FCM 일반화 = 릴레이 #338 G3, 호출 모양은 그대로) |
| `setAccessToken(token?)` | CF Access 토큰 교체 | `MlsRoom` 과 같다 |

## 3. 콜백

### `HttpTransport.send(method, url, headers, body) → HttpResponse{status, body}`
- 바이트만 옮긴다. `url` = `baseUrl` + 경로·쿼리(코어가 만든다). `headers` 를 그대로 붙인다. `body` 가 있으면 `Content-Type: application/json`.
- **응답이 있으면 상태코드가 무엇이든 그대로 돌려준다**(4xx/5xx 포함 — 오류 봉투 해석은 코어). **연결 실패·타임아웃처럼 응답이 없을 때만** throw → 코어는 `transient` 로 분류하고 호스트에 `RoomException.Relay(transient=true)` 로 돌려준다.
- TLS·인증서·프록시·타임아웃은 호스트 몫. 리다이렉트는 따르지 않는다.

### `RoomObserver`
| 콜백 | 언제 | 호스트 의무 |
|---|---|---|
| `persist(state, sync)` | 그룹 상태가 움직인 뒤(`poll` 끝 · `send` 의 POST **전** · `dispatch` 성공 직후 · `postCommit`/`postWelcome` 전) | **원자 쓰기**(tmp → fsync → rename → 디렉터리 fsync) 뒤에 돌아온다. 돌아오기 전에는 바이트가 나가지 않는다(review 2 B-H2). 실패하면 throw — 코어는 그 전송을 하지 않는다. `state` 는 봉인해서(Keystore 키, EncryptedFile) 저장. `sync.sends`(dedup 카운터)·`sync.pendingInvite`(#574 후속 대기 Welcome — 대상의 key package 로 봉인된 공개 와이어 바이트, `state` 처럼 봉인할 필요 없음) 도 함께 |
| `event(RoomEvent)` | 처리 이벤트마다 | 로그 싱크(봇 JSON 로그와 같은 어휘: `AckRefused` `Joined` `WelcomeIgnored` `Rejected` `CommitApplied` `Undecryptable` `OwnEvent` `OwnCommitMerged` `OwnCommitMergeRejected` `Conflict` `AlreadyDelivered` `Replayed` `Dropped` `WelcomeDropped`(#574 후속 — 호스트는 그 대상을 초대 대기열에 되돌린다)). 평문·키는 없다 |
| `application(seq, sender, clientId, plaintext)` | 다른 기기의 복호화된 메시지, 페이지 순서 | 저장·표시·알림. `clientId` 가 `file-v1-…` 이면 첨부(relay-app 규칙, ≤256 KiB 는 호스트 정책) |
| `halted(reason, detail, sync)` | 정책이 commit 을 거부(`reason` = 정책 코드) · 이력이 잘림(`history_gap`) | 마커 영속(재시작 뒤에도 정지) · 화면에 사유 · 해제 = 방 상태 버리고 재초대(iOS §3.5 와 같은 규칙) |

## 4. 불변식(호스트가 깨면 안 되는 것)
1. **persist-before-bytes-leave**: `persist` 가 성공하기 전에 암호문·Welcome·commit 이 나가지 않는다(코어가 순서를 지키고, 호스트는 `persist` 안에서 정말로 디스크에 닿아야 한다).
2. **ack = 영속된 커서**: 코어는 `persist` 뒤에만 `acked` 를 올린다. 호스트가 `persist` 를 가짜로 성공시키면 릴레이가 아직 못 읽은 이력을 정리할 수 있다.
3. **재시작 = `import(state, sync)`**: 두 값은 같은 `persist` 호출에서 온 쌍이어야 한다(한쪽만 새것이면 ratchet·커서가 어긋난다). 봉인 해제 실패·다른 방의 상태는 `Host` 오류.
4. **정지는 최종**: `halted` 뒤 그 방은 읽지도 ack 하지도 않는다. 거부된 commit 을 다시 받아들이는 경로는 없다.
5. **dedup 키는 코어가 만든다**(`<identity>-<8 hex>`, 카운터 영속). 호스트가 따로 만들지 않는다. 봇의 `-echo-` 형식은 쓰지 않는다(봇이 echo 로 오인).
6. **프레이밍은 코어**: 호스트는 평문만 다룬다.

## 5. 오류 처리 지침
| `RoomException` | 뜻 | 호스트 |
|---|---|---|
| `Relay(reason, transient=true)` | 연결 실패 · 502~504 | 백오프 뒤 같은 호출 재시도. 화면엔 「연결 중…」 |
| `Relay(reason, transient=false)` | 401 · 403(`device_subject_mismatch` = 미등록, `not_a_member` = 제거됨) · 404 · 410 `room_closed` 등 | 코드별 화면(등록 대기 · 방 닫힘). 재시도하지 않는다 |
| `Mls(reason)` | 파사드 거부 · 롤백 실패 · 암호화 실패 | 롤백 실패("state rollback …")는 재등록 필요. 그 밖은 로그 |
| `Host(reason)` | 호스트 콜백이 throw · 전제 위반 | 호스트 버그 — 로그·보고 |

## 6. 아직 코어에 없는 것(호스트가 임시로 하거나 보류)
- 3c 에서 코어로 들어간 것: 로비 key package 게시·보충(`MlsLobby.replenish`) · 방 목록(`rooms()`) · 푸시 등록(`registerPush`) · 방 닫기(`MlsRoom.closeRoom`) · 로비 Welcome 받아들이기(`MlsRoom.adopt`).
- 남은 것: **첨부 크기 정책**(호스트 `application` 콜백에서 `client_id` `file-v1-…` 판정 뒤 적용) · 푸시 **와이어의 FCM 일반화**(릴레이 #338 G3 — 클라이언트 호출 모양은 그대로) · 로비 key package 의 **방 상태 사본에서의 정리**(`join` 이 남은 것을 모두 지우므로 방 쪽은 자동; 로비 쪽은 `replenish` 가 서버 `live` 기준으로 정리).

## 7. 검증
- Rust: `ios-ffi/tests/room_host.rs`(3a, 10 시나리오 — #574 형제 기기 `invite` · 후속의 대기 Welcome 영속·재시작 포함) · `ios-ffi/tests/lobby_host.rs`(3c, 12 시나리오: 보충·상한·게시 실패 롤백·로비 Welcome adopt·import·회수·방 닫기·푸시 + #574 `/v2/me`·후보 게시→승인·역할·로비 `dispatch`) — 대역은 `tests/support/mod.rs`(in-memory 릴레이·관찰자·기기 정책 체인 대역).
- JVM(Linux, CI `native-mls-android.yml`): [`android/host`](android/) — Kotlin 바인딩 + `JdkHttpTransport`/`FileRoomStore`/`FileLobbyStore` + in-memory 릴레이로 **같은 시나리오**(두 기기 왕복 · 409 재전송 · 영속 뒤 `import` 이어 받기 · 정지 · 로비 보충→adopt→방 목록→닫기→푸시→회수 · 읽음 위치 · #574 후보→승인→역할→형제 초대→adopt). 실행 `android/scripts/jvm-roundtrip.sh`.
- 호스트 판정(Android `core/SelfService`): `:app:testDebugUnitTest` 의 `SelfServiceTest`(웹 `tests/self-service.test.mjs` 와 같은 경우) · `AppLoginTest.subjectOf*`(등록 JSON `subject` = JWT `sub`).
- 실기기·에뮬레이터(Android 앱)는 #338 B 단계.
