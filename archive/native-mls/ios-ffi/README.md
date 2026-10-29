# ios-ffi — 파사드의 세 번째 호스트 (스파이크 A, #271 §3·§12-A)

> **상태: 스파이크.** 브라우저(WASM 워커)·봇(native Rust)에 이어 **iOS(Swift)** 가 같은 OpenMLS 파사드
> `archive/experiments/openmls-browser` 를 링크할 수 있는지, 그 비용(빌드 시간·바이너리 크기)은 얼마인지를 잰다.
> 설계 전문 [#271](https://github.com/jinwon-int/family-messenger/issues/271), 독자 트랙 설계 [#177](https://github.com/jinwon-int/family-messenger/issues/177).

## 무엇이 들어 있나

| 파일 | 역할 |
|---|---|
| `src/lib.rs` | `MlsDevice` 객체(uniffi): `new / import_state / export_state / public_key / fingerprint / dispatch(method, bytes)`. **MLS 로직 0줄** — 와이어 프레이밍·AAD·commit 검사·record 코덱은 전부 파사드 |
| `src/room.rs` | **`MlsRoom` 객체**(#366 3a, Android 먼저): 방 하나의 동기화(`poll`)·송신(`send`)·초대 게시(`post_commit`/`post_welcome`)·`dispatch`. 상태기계·릴레이 와이어는 host-core `room`/`api` — **봇과 같은 코드**. 호스트는 `HttpTransport`(바이트 전송)·`RoomObserver`(영속·이벤트·메시지·정지) 두 trait 만 구현한다(아래 절) |
| `tests/host_roundtrip.rs` | 봇 `tests/native_facade_link.rs` 의 두 시나리오를 FFI 객체로 반복 + 거부 시 스냅샷 롤백 검사 (host, `cargo test`) |
| `src/lobby.rs` | **`MlsLobby` 객체**(#366 3c, 기기 수준·방 무관): 로비 key package 보충(`replenish`, iOS `LobbyKeyring` 규칙)·`welcomes`·`withdraw` · 방 목록 `rooms` · 푸시 `register_push`/`unregister_push`. 호스트는 `LobbyObserver.persist(slot)` 하나를 구현한다. `MlsRoom::adopt`(로비 시드/Welcome 으로 방 시작)·`MlsRoom::close_room` 도 3c |
| `tests/room_host.rs` | `MlsRoom` 게이트: in-memory 릴레이(`HttpTransport`)·관찰자(`tests/support/mod.rs`) 위에서 두 기기 왕복 · 자기 commit merge → 상대 적용 · 409 cas_mismatch 재시도 · `import` 이어 받기 · 전송 실패 = transient · history gap 정지 · 읽음 위치(#571 후속: `poll` 이 `read_seq` 를 실어 오고 `mark_read` 가 `POST /read` — actor 단위 공유, 옛 릴레이 404 무시) |
| `tests/lobby_host.rs` | `MlsLobby` 게이트(3c): 보충·상한(릴레이 max·파사드 8)·게시 실패 롤백 · 로비 Welcome `adopt` → join · `import` · 회수 · `close_room` 410 · 푸시 등록 왕복 |
| `build-xcframework.sh` | macOS: iOS 기기·시뮬레이터 staticlib → `FamilyMLS.xcframework` + Swift 바인딩 + sha256 목록 |
| `uniffi.toml` | Swift 모듈명 `FamilyMLS` / FFI 모듈 `FamilyMLSFFI` |
| `src/bin/uniffi-bindgen.rs` | 바인딩 생성기(같은 uniffi 핀) — `--features cli` |

호스트 계약(봇과 동일): 연산 전 `export_state` 스냅샷 → 파사드 거부 시 스냅샷으로 복원. **영속·봉인·잠금은 호스트(Swift) 책임**이다 — #271 §4(App Group + Data Protection + Keychain 봉인 키, App↔NSE `flock`). 이 크레이트는 디스크·네트워크·키체인을 모른다.

## 빌드·검증

```bash
# Linux/macOS 공통 — host 게이트
cargo +1.91.1 test --locked
# Linux 에서도 가능한 1차 신호 — iOS 타겟으로 타입체크(링크 없음)
cargo +1.91.1 check --locked --lib --target aarch64-apple-ios
# macOS — xcframework + Swift 바인딩
./build-xcframework.sh          # → out/FamilyMLS.xcframework, out/swift/FamilyMLS.swift, out/xcframework-sha256.txt
```

CI: `.github/workflows/native-mls-ios.yml` (ubuntu host 게이트 ≤15분 · macOS 빌드 ≤25분, `archive/native-mls/ios-ffi/**`·`archive/native-mls/ios/**` 경로 필터). 예산 규칙은 결정 E 규칙 2.

## 의존성 (#177 원칙 5)

| 크레이트 | 핀 | 라이선스 | 왜 |
|---|---|---|---|
| `family-mls-browser-experiment` | path | 레포 | 파사드(세 호스트 공용) |
| `uniffi` | `=0.32.2` | MPL-2.0 (미수정 사용) | Rust↔Swift 바인딩 생성. 대안 = 수동 `extern "C"` + Swift 래퍼(의존 0, 바이트 버퍼·오류 전달을 손으로). 스파이크 결과(크기·빌드 시간)로 택한다 — #271 §3 |
| `sha2` | `=0.10.9` | MIT/Apache-2.0 | 지문 = sha256(공개키) (DEVICES-V4). 파사드 그래프에 이미 있는 핀 |
| `native-mls-host` | path | 레포 | 방 동기화·송신 상태기계와 릴레이 와이어(#366) — 봇·Android 공용. 새 외부 의존 없음(serde·serde_json·sha2 핀 동일) |
| `zeroize` | `=1.9.0` | MIT/Apache-2.0 | 연산 전 스냅샷(키 재료) 지우기. 파사드·봇 그래프에 이미 있는 핀 |
| `serde_json` (dev) | `=1.0.151` | MIT/Apache-2.0 | `tests/room_host.rs` 의 in-memory 릴레이 와이어 JSON. 그래프에 이미 있는 핀 |

전체 전이 라이선스 고지(`THIRD-PARTY-NOTICES.txt`)·`dependencies.json` 은 **스파이크 통과 뒤** 파사드와 같은 형식으로 생성한다(여기서는 `Cargo.lock` 만 커밋).

## `MlsRoom` — 모바일 호스트의 방 (#366 3a)

호스트(Kotlin)가 구현하는 두 trait(`#[uniffi::export(foreign)]`):

| trait | 메서드 | 호스트가 하는 일 |
|---|---|---|
| `HttpTransport` | `send(method, url, headers, body) → HttpResponse{status, body}` | OkHttp 로 바이트만 옮긴다(TLS 는 여기). **연결 실패만** `Err`(→ transient) — HTTP 오류 상태는 보통의 응답. 경로·쿼리·JSON·오류 봉투·CF Access 헤더는 Rust |
| `RoomObserver` | `persist(state, sync)` · `event(RoomEvent)` · `application(seq, sender, client_id, plaintext)` · `halted(reason, detail, sync)` | 원자 영속(tmp→fsync→rename, Keystore 봉인) — **돌아오기 전에는 바이트가 나가지 않는다**(review 2 B-H2) · 로그 · 메시지 저장/표시 · 정지 마커 |

`MlsRoom`: `new(identity, room, base_url, transport, observer)` / `import(…, state, sync, …)` · `poll()`(봇 `poll_room` 순서: ack → GET → gap → welcome/commit/application; 끝에 dirty 면 persist) · `send(plaintext) → Sent | Queued(409 cas_mismatch, 다음 poll 뒤 재시도 ≤8) | AlreadyDelivered` · `post_commit` / `post_welcome`(초대: `dispatch("invite_with_commit")` → `post_commit` → `poll` 이 `OwnCommitMerged` → `post_welcome`) · `export_state` · `sync_state` · `dispatch`(성공 시 바로 persist) · `set_access_token` · `read_seq()` / `mark_read(seq)`(#571 후속: 릴레이가 아는 **같은 사람(actor)의** 읽음 위치 — `poll` 의 `GET /events` `read_seq` 와 `POST /read` 응답의 max, 영속 안 함; 옛 릴레이 404 · `no_such_room` 은 무시, 410/403/400 은 `Relay` 오류). 오류는 `RoomError{Relay{transient}, Mls, Host}` — 기존 `MlsError` 는 그대로.

프레이밍은 봇과 바이트 동일(AAD client_id = 기기 identity). 릴레이 dedup client_id 는 iOS 와 같은 모양 `<identity>-<8 hex>`(카운터 영속). Kotlin 어댑터·JVM 왕복·`HOST-CONTRACT.md` 는 3b.

3c(`MlsLobby` · `MlsRoom::adopt` · `MlsRoom::close_room`): 기기 수준 호출은 `../HOST-CONTRACT.md` §2b. host-core `api::Client` 에는 같은 와이어의 `post_lobby_key_packages` · `lobby_status` · `lobby_welcomes` · `delete_lobby_key_packages` · `list_rooms` · `register_push` · `unregister_push` 가 더해졌다(봇도 쓸 수 있다). #571 후속으로 `post_read(room, device, seq) → read_seq` 와 `EventsResponse.read_seq`(`#[serde(default)]` — 봇·옛 릴레이 무영향)도.

## 증명하지 않는 것

- 정책 메서드 4개(`members`·`members_after_pending`·`policy_fingerprint`·`sign_approval`)는 #275 L2 에서 `dispatch` 에 더했다. 바이트 규칙은 파사드 `policy_wire`(durable lane `Session::dispatch` 와 같은 함수)가 소유한다. `tests/policy_wire.rs` 는 승인 서명을 고정 벡터 `../tests/fixtures/ios-ffi-approval-vector.json`(합성 키, 테스트 전용)과 바이트 단위로 비교하고, Go `server/cmd/native-devices/approval_vector_test.go` 가 같은 벡터를 `-add-device` 로 수락하는지 검사한다. 재생성: `FM_REGEN_APPROVAL_VECTOR=1 cargo +1.91.1 test --locked --test policy_wire`.
- durable lane `Session` 의 HMAC record 체인·store 는 노출하지 않는다(영속은 호스트 몫, #271 §12-B).
- 실제 iOS 앱에서 승인 화면 → CLI 까지의 사람 경로(L3·파이널라이저 범위).
- iOS 기기에서의 **실행**(시뮬레이터 단위시험까지만 CI). upstream OpenMLS 는 iOS 를 "built, not tested in CI" 로 표기한다.
- 프로세스 간 단일 작성자·원자 영속·NSE 예산 — #271 §12-B/D.
- 릴레이 통신·CF Access·푸시 — #271 §12-C/D.

## Android 호스트 (#338 스파이크 A — 네 번째 호스트)

같은 크레이트·같은 uniffi 핀으로 **Kotlin** 바인딩과 Android ABI 3개(`arm64-v8a`·`armeabi-v7a`·`x86_64`) `.so` 를 만든다.
MLS 로직 추가 0줄, iOS 산출물·CI 는 그대로다. 크레이트 이름(`family-mls-ios-ffi`)은 스파이크 통과 뒤 `mobile-ffi` 로 개명할지 결정한다(#338 §2).

```bash
# Linux — rustup Android 타겟 3개 + cargo-ndk(=4.1.2) + ANDROID_NDK_HOME
rustup target add --toolchain 1.91.1 aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk --version 4.1.2 --locked
./build-android.sh            # → out/android/jniLibs/<abi>/*.so, out/android/kotlin/**/*.kt, jnilibs-sha256.txt, build-report.txt
```

- Kotlin 패키지 `com.seoyoon_family.hande.mls`(`uniffi.toml`) — Java 식별자 규칙상 하이픈 불가라 iOS 번들 ID 와 다르다.
- 바인딩은 **dev 호스트 cdylib** 에서 생성한다(release 는 `strip = true` 라 Linux 에서 uniffi 메타데이터가 없다).
- CI: `.github/workflows/native-mls-android.yml` — ubuntu 1 job ≤20분(결정 E 규칙 2). 수용 기준(#338 §4 A): 3 ABI 빌드 3/3, `.so` 합계 ≤ 15 MB. JVM/에뮬레이터 왕복은 다음 슬라이스.
- Kotlin 런타임 의존 `net.java.dev.jna:jna`(Apache-2.0)는 앱 Gradle 쪽 의존이며, #177 원칙 5 에 따라 앱 프로젝트 생성 시 `dependencies.json`·고지에 추가한다.
