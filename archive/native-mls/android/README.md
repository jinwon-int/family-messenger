# android — 「한데」 Android 호스트 (#338 · #366 3b·3c · B1)

> **상태: B1 — 앱 골격(Compose).** Rust 코어(`MlsRoom`·`MlsLobby`, [`../HOST-CONTRACT.md`](../HOST-CONTRACT.md))를 Kotlin 에서 쓰는 **호스트 어댑터**(`host/`),
> 그것이 봇·Rust 테스트와 같은 규칙으로 도는지 확인하는 **JVM 왕복 테스트**, 그리고 **앱 모듈**(`app/`: 처음 설정 → 등록 대기 → 대화방 목록/대화)이 있다.
> 바인딩·`.so` 는 [`../ios-ffi`](../ios-ffi/README.md) `build-android.sh` 가 만든다(크레이트 개명은 #338 §2 결정 뒤). 패키지 `com.seoyoon_family.hande`, minSdk 26(G0).

| 경로 | 역할 |
|---|---|
| `app/` | **앱 모듈(B1)**. `core/DeviceHub`(단일 작성자: `MlsLobby` 시드 → 방은 전부 `MlsRoom.adopt`, 전면 4 s poll, 로비 보충, Welcome 받아들이기, 등록 JSON, #574 셀프서비스 틱) · `core/SelfService`(#574 순수 판정 — 웹 `self-service.js` 1:1: `canApprove`·`isSibling`·`candidatesFor`·`rolesActions`·`enrollModeFrom`·형제 초대 대기열) · `core/KeystoreSealer`(Android Keystore AES-GCM 비수출 키, StrongBox 우선 — `FileRoomStore`/`FileLobbyStore` 의 `seal`/`open` 훅; Jetpack Security 미사용, 의존 0) · `core/Settings`(릴레이 주소·이름·봉인된 세션 값·진행 중 로그인 state·형제 초대 대기열) · `core/MessageDb`+`core/MessageSchema`(정식 저장소 — SQLite, iOS 동결 DDL v1 공유, B2) · `core/AppLogin`+`core/LoginLauncher`(가족 로그인, B2; `subjectOf` = JWT `sub`) · `core/Unread`(안 읽음 판정 — 웹 `read-seq.js`·iOS `Unread` 와 같은 규칙, #571 후속) · `ui/Screens`(설정 · 등록(운영자/형제 승인 모드) · 로그인 · 목록(안 읽음 배지 · 새 기기 승인 카드) · 대화 · 내 기기). 전송은 `host/JdkHttpTransport`(OkHttp 는 보류 — 의존 0 으로 충분, 필요 시 같은 trait 로 교체) |
| `settings.gradle.kts` · `build.gradle.kts` · `gradle/libs.versions.toml` | Gradle(wrapper jar 는 커밋하지 않는다 — CI 가 Gradle 8.11.1 을 핀으로 설치). 버전 핀은 toml |
| `app/debug.keystore` | **디버그 서명키(PKCS12, 표준 공개 자격 `androiddebugkey`/`android`)** — 커밋해서 CI 디버그 APK 서명을 고정한다. 없으면 러너마다 새 키라 실기기 `adb install -r` 이 `INSTALL_FAILED_UPDATE_INCOMPATIBLE` 로 거부된다(2026-10-20 공융, 재설치 3회 무효). 릴리스 서명에는 절대 쓰지 않는다(E 단계 Play App Signing). CI 가 APK 서명자 지문을 이 키와 대조한다 |
| `host/src/main/kotlin/.../host/JdkHttpTransport.kt` | `HttpTransport` — `HttpURLConnection`(Android 에도 있음). 응답이 있으면 상태코드 그대로, 연결 실패만 throw(→ transient). 앱은 OkHttp 로 바꿔도 같은 규칙 |
| `host/src/main/kotlin/.../host/FileRoomStore.kt` | `RoomObserver` — 원자 영속(tmp → fsync → rename → 디렉터리 fsync) · 정지 마커 · 이벤트/메시지 싱크 · `load()` → `MlsRoom.import`. `seal`/`open` 훅에 Keystore 봉인(EncryptedFile 상당)을 끼운다 |
| `host/src/main/kotlin/.../host/FileLobbyStore.kt` | `LobbyObserver`(3c) — 로비 슬롯(시드 + 로비 key package 비밀 + 게시 장부) 한 파일 원자 영속 · `load()` → `MlsLobby.import`. 같은 `seal`/`open` 훅 |
| `host/src/test/kotlin/.../host/InMemoryRelay.kt` | 테스트 전용 in-memory 릴레이(`ios-ffi/tests/support/mod.rs` 의 Relay 와 같은 규칙: events(`read_seq`) + 로비(`from` 포함 welcomes)·방 목록·닫기·푸시·읽음 위치 `POST /read` + #574 `/v2/me`·후보 우편함·승인·역할 — 체인 대역은 revision CAS·registrar 규칙만) |
| `host/src/test/kotlin/.../host/RoomRoundtrip.kt` | `main` 하나로 7 시나리오: 두 기기 왕복 · 409 재전송 · 영속 뒤 `import` 이어 받기 · 전송 실패 transient + 잘린 이력 정지(재시작 뒤 유지) · **로비**(보충 → steward 가 로비 키로 초대 → `welcomes` → `MlsRoom.adopt` → 방 목록 → 닫기 410 → 푸시 등록 → 회수) · **읽음 위치**(#571 후속: `poll` 이 actor 단위 `read_seq` 를 실어 옴 · `markRead` 가 `POST /read` · 옛 릴레이 404 무시) · **셀프서비스**(#574: 후보 게시 → 등록 기기 승인(지문 불일치 거부 · 409 재서명) → 역할 부여/해제(마지막 registrar 보호) → `MlsRoom.invite`(로비 키 소비 → commit → echo → Welcome `from`) → adopt → 옛 릴레이). JUnit 의존 0 |
| `scripts/jvm-roundtrip.sh` | kotlinc 로 바인딩+어댑터+테스트를 jar 로 → JNA 로 호스트 `.so` 실행 |

## 실행 (Linux, Gradle·Android SDK 불필요)

```bash
# 1) 호스트 cdylib(dev, uniffi 메타데이터 포함) + Kotlin 바인딩
cd ../ios-ffi && cargo +1.91.1 build --locked --features cli
target/debug/uniffi-bindgen generate --library target/debug/libfamily_mls_ios_ffi.so --language kotlin --out-dir out/android/kotlin --no-format
# 2) JDK 17 · kotlinc 2.1.20 · jna 5.17.0 (CI 는 sha256 핀으로 받는다 — native-mls-android.yml)
KOTLINC=/path/kotlinc/bin/kotlinc JNA_JAR=/path/jna-5.17.0.jar BINDINGS_DIR=out/android/kotlin FFI_LIB_DIR=target/debug \
  ../android/scripts/jvm-roundtrip.sh      # 마지막 줄 ROUNDTRIP PASS
```

CI: `.github/workflows/native-mls-android.yml` — job 1 `android-ffi`: 3 ABI `.so` + JVM 왕복(ubuntu, ≤20분) → job 2 `android-app`: 아티팩트로 `gradle :app:assembleDebug`(JDK 17 · Gradle 8.11.1 · 러너 내장 SDK), APK 에 3 ABI `.so` + `libjnidispatch.so` 포함 확인, 디버그 APK 아티팩트.

```bash
# 앱 빌드(로컬, Android SDK + JDK 17 + Gradle 8.11.1): 먼저 ../ios-ffi/build-android.sh
cd ../android && gradle :app:assembleDebug            # 또는 -PhandeFfiOut=<build-android.sh --out 경로>
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## 앱 흐름(B1)
1. **처음 설정**: 릴레이 주소 · 이름(영문 소문자, 한 번 정하면 고정 → 기기 ID `<이름>-android-<6 hex>`) · 세션 값(운영자용, 선택).
2. **등록 대기**: 릴레이가 403 `device_subject_mismatch` 면 지문·등록 JSON(`actor`·`device_id`·`fingerprint`·`signing_key`·`subject`, iOS 와 같은 키) 을 보여 준다 → 운영자 CLI(`-enroll-first`/`-add-device`). `subject` 는 세션 JWT 의 `sub`(`AppLogin.subjectOf`, iOS PR #347 과 같은 출처; 없으면 `/v2/me` 의 subject, 그것도 없으면 빈값). 401·엣지 302 면 **가족 로그인**(B2: 「Google 계정으로 로그인」 → Custom Tabs → `hande://auth#jwt` 콜백; 세션 값 붙여넣기는 운영자용).
   **셀프서비스(#574 PR 4, 웹 `app.js enrollTick` 와 같은 순서)**: 403 인 동안 틱마다 `MlsLobby.postCandidate()`(`POST /v2/devices/candidates`, subject 없는 strict JSON) — 201 이면 「다른 기기에서 승인해 주세요」 + 큰 지문(4자 묶음) + 만료 시각(만료 5분 전에 다시 올린다); 409 `device_exists` 면 「새 ID 로 다시」; 403 `first_device_out_of_band`·봉투 없는 404(옛 릴레이) 면 오늘의 운영자 JSON 화면. 3틱마다 `probe`(로비 상태) 가 200 이 되면 — 형제 기기가 승인했다 — 「이 기기가 등록되었습니다」 와 함께 대화방 목록으로.
3. **대화방 목록**: 「참여 요청」 = `MlsLobby.replenish(8)`(로비 키 게시). 운영자(steward 봇)가 초대하면 `welcomes()` 에 방이 뜨고 `MlsRoom.adopt(seq - 1)` → `poll` 이 join → 목록에 나타난다. 하단에 기기 ID · 로비 키 n/8 · 키 보관 위치(StrongBox/TEE). 같은 사람의 다른 기기가 보낸 Welcome(`from` 이 `/v2/me` 의 같은 actor 활성 기기, `SelfService.isSibling`)도 같은 길로 자동 수락한다(이 앱에는 초대 카드가 없어 모든 Welcome 을 받는다 — 형제 기기면 알림에 그 사실을 적는다).
   **새 기기 승인(#574 E2)**: 내 기록이 활성이고 (registrar 이거나 내 actor 에 registrar 가 없으면 — `SelfService.canApprove`) 틱마다 `MlsLobby.listCandidates()` → 내 actor 의 후보를 목록 위 카드로(지문 4자 묶음·만료). 「지문 비교 후 승인」 = 새 기기 화면의 지문과 눈으로 견준 뒤 → `MlsLobby.approve(candidate, policyRevision)`(코어가 `policy_fingerprint` 로 지문을 다시 계산해 다르면 거부 → `sign_approval` → `POST /v2/devices/approvals`); 409 `stale_revision` 이면 릴레이가 준 revision 으로 한 번 다시, 403 이면 `detail` 을 카드에. 201 이면 `/v2/me` 를 새로 읽고 **형제 기기 초대 대기열**(`Settings.siblingQueue`, 30분 TTL)에 내가 참여한 방을 적는다 → 틱마다 `MlsRoom.invite(target)`(로비 키 소비 → `invite_with_commit` → commit → echo → Welcome): `NoKeyPackage`(새 기기가 아직 로비 키를 안 올림)·`Pending`·`Raced` 는 다음 틱에 다시, 그 밖은 포기·알림.
   **내 기기(#574 E5)**: 상단 「내 기기」 → `/v2/me` 의 내 기기 전부(이 기기 먼저 · 활성/폐기 · 「등록 기기」 표시 · 지문). 허용될 때만(`SelfService.rolesActions` — 서버 `VerifyRoles` 와 같은 규칙: 대상 활성·같은 actor, 마지막 registrar 는 해제 불가) 「등록 기기로」/「등록 기기 해제」 → `MlsLobby.setRoles(deviceId, actor, 완전한 역할 목록, policyRevision)` → `POST /v2/devices/roles`; 409 면 `/v2/me` 를 다시 읽고 한 번 다시 서명.
4. **대화**: 텍스트 송수신(`send` → `Sent | Queued`), 첨부는 「📎 첨부(n B)」 자리 표시(C 단계). file-v2(#499) 설명자는 `FileV2.kt` 가 엄격 검증해 같은 자리 표시로 두고, 설명자(파일 키)는 글로 저장·표시하지 않는다(`FILE-V2.md` §6).
5. **안 읽음·읽음 위치 공유**(#571 후속, 웹 `RELAY-APP.md` 8 과 같은 규칙): 목록의 「새 글」배지 = 마지막 글이 남의 글(actor 기준)이고 `max(Settings.readSeq, MlsRoom.readSeq())` 보다 뒤(`core/Unread`). 방을 열 때·보는 중 마지막 seq 가 움직일 때 `DeviceHub.markRead` 가 로컬 값을 적고 `MlsRoom.markRead(seq)` → `POST /v2/rooms/{room}/read` 로 올린다(릴레이가 **actor 단위**로 보관 → PC 웹에서 읽으면 폰 배지도 다음 poll 에 꺼진다). 로컬 값은 `Settings`(SharedPreferences, 줄어들지 않음) — `messages.db` 는 iOS 와 동결 DDL 을 공유하므로 열을 더하지 않는다. 실패(옛 릴레이 404·410·403·전송)는 로그만.

첨부 전송·알림(FCM, D)·정식 아이콘(E)은 범위 밖(Google 로그인·정식 저장소는 B2 에서 들어왔다 — 아래 「B2 결정」).

## 의존성 (#177 원칙 5)

| 항목 | 핀 | 라이선스 | 왜 |
|---|---|---|---|
| OkHttp | `4.12.0` | Apache-2.0 | 앱 릴레이 전송(#338 §2 RelayClient). `host/JdkHttpTransport`(HttpURLConnection)는 실기기에서 CF Access/HTTP2 엣지에 멈춤(공융 build fa4f286) → OkHttp(HTTP/2·`callTimeout`·리다이렉트 무추적). okio 는 전이 의존 |
| `androidx.browser:browser` | `1.8.0` | Apache-2.0 | 가족 로그인(B2) Chrome Custom Tabs — Google 은 WebView 로그인을 막고 Custom Tabs(브라우저 본체)는 허용. 제공자가 없으면 `ACTION_VIEW` 폴백 |
| `kotlin-test-junit` (test 전용) | `2.1.20` (JUnit `4.13.2` 전이) | Apache-2.0 / EPL-1.0 | `AppLogin`·`Unread`·`FileV2`·`SelfService` 순수 로직 JVM 단위 테스트(CI `:app:testDebugUnitTest`). 앱 APK 에는 들어가지 않는다 |
| JNA | `5.17.0` | Apache-2.0 / LGPL-2.1 (이중) | uniffi Kotlin 바인딩의 런타임 요구(#338 §5 예고). 앱은 `jna@aar`(libjnidispatch.so 포함), JVM 테스트는 jar 직접 |
| Kotlin 컴파일러 · KGP · Compose 컴파일러 플러그인 | `2.1.20` | Apache-2.0 | 앱 빌드·테스트 빌드 |
| Android Gradle Plugin | `8.7.2` | Apache-2.0 | KGP 2.1.20 호환 상한(kotlinlang 호환표: AGP 7.3.1–8.7.2 · Gradle 7.6.3–8.12.1) |
| Gradle | `8.11.1` | Apache-2.0 | 빌드 도구(CI 가 설치, wrapper jar 미커밋) |
| Compose BOM | `2024.12.01` | Apache-2.0 | `compose-ui` · `material3` 버전 묶음 |
| `androidx.activity:activity-compose` | `1.9.3` | Apache-2.0 | `setContent` |
| `androidx.lifecycle:lifecycle-runtime-compose` | `2.8.7` | Apache-2.0 | `collectAsStateWithLifecycle` |
| `androidx.core:core-ktx` | `1.15.0` | Apache-2.0 | 플랫폼 확장 |
| `kotlinx-coroutines-android` | `1.9.0` | Apache-2.0 | 허브 poll 루프·IO 디스패처 |

## B2 결정 — 메시지 저장소 · 가족 로그인 (2026-10-20)

**저장소 = 프레임워크 SQLite(`core/MessageDb`, `SQLiteOpenHelper`) + iOS 동결 DDL v1 공유.** #338 §2 의 Room·"Rust 우선 검토(rusqlite)" 는 채택하지 않았다:
- Room 은 KSP 플러그인 + annotation processor + 런타임 3 의존이 붙는다. 표는 2개(`rooms`·`messages`)고 쿼리는 4종 — iOS `FileSQLiteStore` 가 sqlite3 C API 로 **의존 0** 을 지킨 것과 같은 선택이 맞다(#177 원칙 5).
- rusqlite 는 메시지 저장을 코어로 옮기는 뜻인데 HOST-CONTRACT §1 이 메시지 저장·표시를 **호스트 몫** 으로 두었고 iOS 가 이미 Swift 에서 구현했다. 코어에 넣어도 공유되는 코드가 없고, 3 ABI 에 SQLite 를 추가로 컴파일해 `.so` 가 커진다.
- 스키마는 iOS `MessageRecord.swift` 의 DDL v1 을 **글자 그대로**(`core/MessageSchema.kt`) — 두 플랫폼의 `messages.db` 모양이 같다. CI `scripts/check-ddl-sync.sh` 가 드리프트를 막는다. Android 는 `rooms`·`messages` 만 쓴다(`outbox`·`cursors` 는 Rust 코어가 `<room>.sync` 에 가진다 — 빈 표로 둔다).
- 보호: 앱 전용 디렉터리(Android 파일 기반 암호화) + `allowBackup=false`. 살아 있는 SQLite 파일은 통째로 봉인할 수 없다 → #338 §2 "SQLCipher 불요 — 파일 레벨 암호화", iOS `messages.db` 의 Data Protection 과 같은 수준. **MLS 상태·로비 슬롯·세션 값은 그대로 Keystore 봉인**(`FileRoomStore`/`FileLobbyStore`/`Settings`).
- 이관: 첫 실행 때 B1 임시 저장(`<room>.messages`, 봉인 JSONL)을 `messages.db` 로 옮기고 파일을 지운다(`MessageDb.migrateLegacy`). 시각은 알 수 없어 옮긴 순간.
- 내 글 판정은 읽을 때 actor 비교(`MessageSchema.isMine`) — 같은 사람의 다른 기기 글도 내 글(오너 결정 2026-10-20, iOS `isMine` 과 동일).
- `received_at` 은 복호화한 순간이다. 코어 `RoomObserver.application` 이 릴레이 `created_at` 을 주지 않는다 — iOS #405 와 맞추려면 FFI 에 시각 필드를 더한다(C 단계 후보).

**가족 로그인 = iOS §12-C A 와 같은 프로토콜.** `core/AppLogin`(순수 로직, iOS `AppLogin.swift` 1:1 — `makeState`·`loginUrl`·`tokenFromCallback`·`formFields`·`isJwtShaped`, JVM 테스트 10) + `core/LoginLauncher`(Custom Tabs) + `MainActivity`(`singleTask`, `hande://auth` intent-filter → `onNewIntent` → `DeviceHub.completeLogin`). 릴레이 `server/applogin.go` 의 고정 콜백 `hande://auth#jwt=…&state=…` 를 그대로 받는다 — 릴레이 변경 없음. `state` 는 `Settings.pendingLoginState`(공개 난수)에 두어 브라우저가 열린 동안 프로세스가 죽어도 검증한다. 세션 값 붙여넣기는 운영자용으로 접어 둔다(iOS LoginView 와 같은 구성).
- 알려진 한계(iOS 와 같음): 커스텀 스킴은 다른 앱도 등록할 수 있다. 토큰은 fragment·state 검증으로 보호되지만, 더 강하게 하려면 App Links(`https://` 콜백 + `assetlinks.json`)로 바꾼다 — 릴레이 `appLoginCallback` 과 함께 바꾸는 조정 변경(E 단계 후보).

## 기기 수준 호출(3c) — `MlsLobby`

방 밖의 일은 기기 하나에 하나인 `MlsLobby`([`../HOST-CONTRACT.md` §2b](../HOST-CONTRACT.md)) 가 맡는다: 로비 key package 보충(`replenish(8)` — 시작·포그라운드·방 참여 뒤), 로비 Welcome 발견(`welcomes()` → `MlsRoom.adopt(identity, room, lobby.seedState(), seq - 1, …)`), 방 목록(`rooms()`), 푸시 등록(`registerPush(token, "com.seoyoon_family.familychat")`), 회수(`withdraw()`). **방은 전부 `MlsRoom.adopt(…, lobby.seedState(), 0, …)` 로 만든다** — 그래야 서명키가 하나다(`MlsRoom(identity, …)` 생성자는 새 키를 만드는 테스트 대역용). 영속은 `FileLobbyStore`.

## 기기 셀프서비스(#574 PR 4) — 남은 것
- `MlsRoom.invite` 의 대기 중 Welcome(commit 은 올렸는데 echo 가 같은 페이지에 없던 `Posted` 경우)은 영속하지 않는다 — 그 사이 프로세스가 죽으면 Welcome 이 나가지 않고, 대기열의 다음 `invite` 는 「이미 멤버」로 실패해 알린다(운영자 재초대). `RoomSyncState` 에 필드를 더하는 것은 `FileRoomStore` 형식 변경이라 후속.
- 「무시」한 후보는 이번 실행에서만 숨긴다(우편함 행은 10분 뒤 사라진다). 「이 기기 지우기」(ID 사용 불가 때 새 ID) 는 iOS §9-5 상당 — 후속.
- 승인 화면의 지문 비교는 사람의 눈(두 화면을 나란히) — QR 교차 확인은 범위 밖.

## 다음
C(UI: 방 목록·대화 다듬기·첨부 ≤256 KiB·정지 표시·`imePadding`) · D(FCM — 릴레이 G3 푸시 와이어 일반화 선행) · E(서명·Play 내부 테스트 트랙).
