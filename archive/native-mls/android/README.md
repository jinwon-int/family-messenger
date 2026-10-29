# android — 「한데」 Android 호스트 (#338 · #366 3b·3c · B1)

> **상태: B1 — 앱 골격(Compose).** Rust 코어(`MlsRoom`·`MlsLobby`, [`../HOST-CONTRACT.md`](../HOST-CONTRACT.md))를 Kotlin 에서 쓰는 **호스트 어댑터**(`host/`),
> 그것이 봇·Rust 테스트와 같은 규칙으로 도는지 확인하는 **JVM 왕복 테스트**, 그리고 **앱 모듈**(`app/`: 처음 설정 → 등록 대기 → 대화방 목록/대화)이 있다.
> 바인딩·`.so` 는 [`../ios-ffi`](../ios-ffi/README.md) `build-android.sh` 가 만든다(크레이트 개명은 #338 §2 결정 뒤). 패키지 `com.seoyoon_family.hande`, minSdk 26(G0), **targetSdk 36**(#584 Play 신규 앱 요건 — 아래 「Google Play 출시」).

| 경로 | 역할 |
|---|---|
| `app/` | **앱 모듈(B1)**. `core/DeviceHub`(단일 작성자: `MlsLobby` 시드 → 방은 전부 `MlsRoom.adopt`, 전면 4 s poll, 로비 보충, Welcome 받아들이기, 등록 JSON, #574 셀프서비스 틱) · `core/SelfService`(#574 순수 판정 — 웹 `self-service.js` 1:1: `canApprove`·`isSibling`·`candidatesFor`·`rolesActions`·`enrollModeFrom`·형제 초대 대기열) · `core/KeystoreSealer`(Android Keystore AES-GCM 비수출 키, StrongBox 우선 — `FileRoomStore`/`FileLobbyStore` 의 `seal`/`open` 훅; Jetpack Security 미사용, 의존 0) · `core/Settings`(릴레이 주소·서버 이름·이름·봉인된 세션 값·진행 중 로그인 state·형제 초대 대기열 · `wipe`) · `core/ServerDiscovery`(#584 서버 탐색 — 순수: `normalizeBase`·`candidates`·`parseWellKnown`·`compareVersions`·주입 `fetch` 의 `discover`; 전송은 `OkHttpTransport.get`) · `core/MessageDb`+`core/MessageSchema`(정식 저장소 — SQLite, iOS 동결 DDL v1 공유, B2) · `core/AppLogin`+`core/LoginLauncher`(가족 로그인, B2; `subjectOf` = JWT `sub`) · `core/Unread`(안 읽음 판정 — 웹 `read-seq.js`·iOS `Unread` 와 같은 규칙, #571 후속) · `ui/Screens`(설정(서버 찾기) · 등록(운영자/형제 승인 모드) · 로그인 · 목록(제목 아래 서버 이름 · 안 읽음 배지 · 새 기기 승인 카드) · 대화 · 내 기기 · **설정**(#584 Play: 앱 버전·서버·기기 ID · 개인정보처리방침·계정 및 데이터 삭제 링크(`BuildConfig.PRIVACY_URL`/`DELETE_ACCOUNT_URL`) · 「이 기기 지우기」 = `DeviceHub.wipeDevice`)). 전송은 `host/JdkHttpTransport`(OkHttp 는 보류 — 의존 0 으로 충분, 필요 시 같은 trait 로 교체) |
| `settings.gradle.kts` · `build.gradle.kts` · `gradle/libs.versions.toml` | Gradle(wrapper jar 는 커밋하지 않는다 — CI 가 Gradle 8.11.1 을 핀으로 설치). 버전 핀은 toml. `app/build.gradle.kts` 가 `-PversionCode`/`-PversionName`·업로드 키 서명·정책 링크 `BuildConfig` 를 읽는다(「Google Play 출시」) |
| `app/debug.keystore` | **디버그 서명키(PKCS12, 표준 공개 자격 `androiddebugkey`/`android`)** — 커밋해서 CI 디버그 APK 서명을 고정한다. 없으면 러너마다 새 키라 실기기 `adb install -r` 이 `INSTALL_FAILED_UPDATE_INCOMPATIBLE` 로 거부된다(2026-10-20 공융, 재설치 3회 무효). **릴리스 서명에는 절대 쓰지 않는다** — release 는 업로드 키가 없으면 미서명이고(`signingConfig = null`), CI 번들 job 이 release 서명자 ≠ 이 키를 검사한다. CI 가 디버그 APK 서명자 지문을 이 키와 대조한다 |
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

CI: `.github/workflows/native-mls-android.yml` — job 1 `android-ffi`: 3 ABI `.so`(16 KB 페이지 정렬 검증 포함) + JVM 왕복(ubuntu, ≤20분) → job 2 `android-app`: 아티팩트로 `gradle :app:assembleDebug`(JDK 17 · Gradle 8.11.1 · 러너 내장 SDK), APK 에 3 ABI `.so` + `libjnidispatch.so` 포함 확인, 디버그 APK 아티팩트 → job 3 `android-bundle`(#584): `:app:bundleRelease` → `app-release.aab`(업로드 키 secret 이 있으면 서명, 없으면 미서명 + 알림) 아티팩트 `hande-android-bundle-<sha>`(14일).

```bash
# 앱 빌드(로컬, Android SDK + JDK 17 + Gradle 8.11.1): 먼저 ../ios-ffi/build-android.sh
cd ../android && gradle :app:assembleDebug            # 또는 -PhandeFfiOut=<build-android.sh --out 경로>
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## 앱 흐름(B1)
1. **처음 설정**: 서버 주소(**도메인만**, #584 PR 3) · 이름(영문 소문자, 한 번 정하면 고정 → 기기 ID `<이름>-android-<6 hex>`) · 세션 값(운영자용, 선택).
   **서버 탐색**(`core/ServerDiscovery`, 릴레이 `server/wellknown.go` 의 문서 — Matrix `.well-known/matrix/client` 방식): 「서버 찾기」(또는 「확인」) 가
   `https://<도메인>/.well-known/hande` → `https://hande.<도메인>/.well-known/hande` 순서로 문서(`version` 1 · `relay.base_url` https · `name` · `min_app.android`)를 찾고,
   둘 다 없으면 입력값을 릴레이 base URL 로 그대로 쓴다(옛 길 — `https://…` 를 직접 적어도 된다). 그 뒤 `GET <base>/v2/health` 가 `{"ok":true}` 면 확정,
   302/401/403(CF Access 엣지가 가림)이면 「릴레이가 로그인 뒤에 있음」으로 역시 확정(저장 뒤 가족 로그인), 그 밖은 오류. `min_app.android` 가 앱 `versionName` 보다
   높으면 「앱이 오래됨」으로 막는다(느슨한 semver). 찾은 서버 이름·주소를 카드로 보여 준 뒤 저장(`Settings.relayUrl`·`serverName`); 서버 이름은 대화방 목록 제목 아래에
   (없으면 릴레이 호스트). 입력 정규화: 스킴 없으면 `https://`, 호스트 소문자, 끝 `/` 제거, http 는 localhost/127.0.0.1 만. 전송은 `OkHttpTransport.get`(토큰 없음·리다이렉트 무추적·16 KiB 상한).
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
| `kotlin-test-junit` (test 전용) | `2.1.20` (JUnit `4.13.2` 전이) | Apache-2.0 / EPL-1.0 | `AppLogin`·`Unread`·`FileV2`·`SelfService`·`ServerDiscovery` 순수 로직 JVM 단위 테스트(CI `:app:testDebugUnitTest`). 앱 APK 에는 들어가지 않는다 |
| JNA | `5.17.0` | Apache-2.0 / LGPL-2.1 (이중) | uniffi Kotlin 바인딩의 런타임 요구(#338 §5 예고). 앱은 `jna@aar`(libjnidispatch.so 포함), JVM 테스트는 jar 직접 |
| Kotlin 컴파일러 · KGP · Compose 컴파일러 플러그인 | `2.1.20` | Apache-2.0 | 앱 빌드·테스트 빌드 |
| Android Gradle Plugin | `8.10.1` | Apache-2.0 | **API 36 을 지원하는 첫 안정 계열**(8.7–8.9 는 최대 API 35; AGP 8.10.0 릴리스 노트: 최소 Gradle 8.11.1 · Build Tools 35.0.0 · JDK 17). kotlinlang 호환표에서 KGP 2.1.20 의 「완전 지원」 AGP 상한은 8.7.2 이지만 같은 표가 「AGP 는 최신까지 사용 가능(경고 가능)」이라 명시 — Kotlin 핀(kotlinc sha256·compose 컴파일러)을 흔들지 않으려고 KGP 는 그대로 둔다(#584). AGP 8.11+ 는 Gradle 8.13 이 필요해 CI 핀까지 바꿔야 하므로 보류 |
| Gradle | `8.11.1` | Apache-2.0 | 빌드 도구(CI 가 설치, wrapper jar 미커밋). AGP 8.10.x 의 최소 버전과 같다 |
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
- 「무시」한 후보는 이번 실행에서만 숨긴다(우편함 행은 10분 뒤 사라진다). 「이 기기 지우기」(ID 사용 불가 때 새 ID, iOS §9-5 상당)는 #584 Play 출시 PR 에서 설정 화면에 들어왔다(아래).
- 승인 화면의 지문 비교는 사람의 눈(두 화면을 나란히) — QR 교차 확인은 범위 밖.

## Google Play 출시 (#584 — 조직 계정, 오너 결정 2026-10-29)

코드 쪽 준비는 이 절의 ①~⑤(PR 「Play 출시 준비」). 콘솔·정책·심사 준비(데모 서버·App access·콘텐츠 등급·D-U-N-S 재사용)는 #584 PR 4.

### ① SDK 36 · Android 16 동작 변경
- `compileSdk`/`targetSdk` **36**(신규 앱 요건; 기존 앱은 2026-08-31 이후 35+). AGP `8.10.1`(API 36 지원 첫 안정 계열, 최소 Gradle 8.11.1 = CI 핀 그대로, Build Tools 35.0.0 — 러너 내장). KGP 2.1.20 유지(의존성 표의 이유).
- **edge-to-edge 강제**(35 에서 선택 해제 가능했던 것이 36 에서 불가): 화면은 전부 Material3 `Scaffold`/`TopAppBar`(인셋 처리)이고, `adjustResize` 가 더는 키보드에 맞춰 줄이지 않으므로 입력 화면(처음 설정·로그인·대화)에 `imePadding` 을 넣었다. 오류·시작 화면은 `safeDrawingPadding`.
- **predictive back 기본 켜짐**(`enableOnBackInvokedCallback` 기본 true): `BackHandler` 로 설정 → 대화 → 내 기기 를 한 단계씩 닫는다(전에는 어느 화면에서든 뒤로가기 = 앱 종료).
- **16 KB 페이지**(targetSdk 35+ 앱, 2025-11-01 이후 제출): 64비트 `.so` 의 LOAD 정렬 16 KB. `../ios-ffi/build-android.sh` 가 `-Wl,-z,max-page-size=16384` 를 명시하고 `llvm-readelf` 로 검증(`build-report.txt` 의 `16 KB page alignment: ok`, CI 수용 기준). JNA 의 `libjnidispatch.so`(5.17.0 aar, sha256 `4dbeffff…cf38`)도 arm64-v8a·x86_64·armeabi-v7a 모두 LOAD Align 0x4000(2026-10-29 `readelf` 확인) — CI 번들 job 이 AAB 안의 64비트 `.so` 전부를 다시 검사한다. 압축 없이 패키징(`useLegacyPackaging = false`).
- 대형 화면 방향·크기 제한 무시(36): 이 앱은 방향을 고정하지 않아 해당 없음. 권한은 `INTERNET` 하나 — 알림 권한(FCM, D 단계) 은 아직 없다.

### ② 릴리스 서명 — 업로드 키(Play App Signing)
- `app/build.gradle.kts` 의 release `signingConfig` 는 네 값(Gradle 속성 `-P` 또는 환경 변수)이 **전부** 있을 때만 만들어진다: `HANDE_UPLOAD_KEYSTORE`(키스토어 경로) · `HANDE_UPLOAD_KEYSTORE_PASSWORD` · `HANDE_UPLOAD_KEY_ALIAS` · `HANDE_UPLOAD_KEY_PASSWORD`. 전부 없으면 **미서명** 번들(빌드는 성공 — Play Console 이 거부), 일부만 있으면 설정 오류로 멈춘다. 디버그 키스토어 경로를 주면 거부한다. release 는 어떤 경우에도 `app/debug.keystore` 로 서명하지 않는다.
- 업로드 키 만들기(오너, 레포 밖 — 비밀 저장 위치만 Wiki 에 적는다). 키스토어는 PKCS12, 유효기간 ≥ 25년(Play 요건 2033-10-22 이후 만료):
  ```bash
  keytool -genkeypair -v -storetype PKCS12 -keystore hande-upload.keystore -alias hande-upload \
    -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=hande upload, O=<법인명>, C=KR"
  base64 -w0 hande-upload.keystore > hande-upload.keystore.b64     # → GitHub secret HANDE_UPLOAD_KEYSTORE_B64
  keytool -list -v -keystore hande-upload.keystore | grep SHA256    # 지문(비밀 아님) — Play Console 「업로드 키 인증서」와 대조
  ```
  Play App Signing 에서 **앱 서명 키는 Google 이 생성·보관**(기본) 하고 이 키는 업로드 전용이다. 업로드 키를 잃으면 Play Console 에서 재설정 요청(새 키 인증서 업로드).
- `isMinifyEnabled = false` 유지: uniffi 바인딩이 JNA 로 심벌을 이름으로 찾고 JNA 자체가 리플렉션 기반이라 R8 keep 규칙을 실기기에서 검증하기 전에는 켜지 않는다(규칙 초안은 `app/build.gradle.kts` 주석).

### ③ 버전 관리
- `versionCode` = `-PversionCode=`(기본 1), `versionName` = `-PversionName=`(기본 `0.1.0`). CI 번들 job 은 **`versionCode = github.run_number`**(이 워크플로가 유일한 출처라 단조 증가; 디버그 APK job 은 기본값이라 실기기 `adb install -r` 호환이 그대로다) 와 `workflow_dispatch` 입력 `version_name`(비우면 Gradle 기본). Play 에 올릴 번들은 **`workflow_dispatch` 로 `version_name` 을 적어 만든다**(예: `0.2.0`); PR 의 자동 번들(`0.1.0 (run_number)`)은 검증용.
- `versionName` 은 릴레이 `/.well-known/hande` 의 `min_app.android` 와 비교된다(#584 PR 3) — 서버가 최소 버전을 올리면 그보다 낮은 앱은 「앱이 오래됨」. 설정 화면에 `앱 버전 <name> (<code>)` 가 보인다.

### ④ CI — `android-bundle` job
- 입력: job 1 의 FFI 아티팩트. 비밀 `HANDE_UPLOAD_KEYSTORE_B64`(base64 키스토어) 가 있으면 러너 `$RUNNER_TEMP` 에 0600 으로 풀고(값은 찍지 않는다) `HANDE_UPLOAD_KEYSTORE_PASSWORD`·`HANDE_UPLOAD_KEY_ALIAS`·`HANDE_UPLOAD_KEY_PASSWORD` 와 함께 Gradle 에 넘긴다. 없으면(포크 PR 포함) `::notice` 와 함께 미서명 번들.
- 검증(bundletool 없이): `app-release.aab` 존재 · `base/lib/{arm64-v8a,armeabi-v7a,x86_64}/libfamily_mls_ios_ffi.so` 3개 · `libjnidispatch.so` · 서명했으면 `jarsigner -verify -strict` + 서명자 SHA-256 ≠ `DEBUG_SIGNER_SHA256`, 미서명이면 `META-INF/*.{RSA,SF}` 없음. 아티팩트 `hande-android-bundle-<sha>`(14일).
- 변수(선택, repo **variables**): `HANDE_PRIVACY_URL`·`HANDE_DELETE_URL` — 정책 페이지 주소를 바꿀 때(기본은 아래 ⑤).

### ⑤ 앱 안 정책 링크 · 계정 삭제(Play 정책)
- 설정 화면(목록·등록 대기·로그인·오류 화면의 「설정」) 과 처음 설정 화면에 **개인정보처리방침**·**계정 및 데이터 삭제** 링크. 주소는 `BuildConfig.PRIVACY_URL`/`DELETE_ACCOUNT_URL` — 기본 `https://jinwon-int.github.io/family-messenger/hande/privacy` · `…/hande/delete-account`(https 만). **GitHub Pages 는 아직 꺼져 있다**(`gh api repos/jinwon-int/family-messenger/pages` → 404, 2026-10-29) — PR 4 에서 켜거나(`docs/` 소스) 다른 호스트로 바꾸고 변수로 주소를 맞춘다. 초안: [`docs/hande/privacy.md`](../../../docs/hande/privacy.md) · [`docs/hande/delete-account.md`](../../../docs/hande/delete-account.md), Data safety 입력표 [`docs/hande/play-data-safety.md`](../../../docs/hande/play-data-safety.md).
- **계정 삭제 경로(정직한 정의)**: 한데의 「계정」 = 가족 운영자가 허용한 Google 계정(CF Access 신원 `subject`) + 릴레이 기기 정책 체인의 기기 기록. 앱이 지울 수 있는 것은 **이 기기의 자료**(설정 → 「이 기기 지우기」 → 확인: `files/mls` 봉인 상태·로비 슬롯 · `messages.db` · SharedPreferences(세션 값·기기 ID 접미) · Keystore 봉인 키 → 처음 설정, 새 기기 ID). 서버 쪽 기기 기록 폐기(E3 `revoke`)·대화방 데이터 삭제·Access 허용 목록 제외는 앱 권한 밖이라 **웹 링크의 절차로 운영자에게 요청**한다 — 앱 안 문구와 문서가 같은 말을 한다.

### 체크리스트 (코드 밖 — 오너·PR 4)
1. Play Console 조직 계정($25) — D-U-N-S 는 Apple 가입 때 번호 재사용, 결제 프로필 법인명·주소를 D&B 와 일치.
2. 업로드 키 생성(②) → GitHub secrets 4개(`HANDE_UPLOAD_KEYSTORE_B64`·`HANDE_UPLOAD_KEYSTORE_PASSWORD`·`HANDE_UPLOAD_KEY_ALIAS`·`HANDE_UPLOAD_KEY_PASSWORD`) → `workflow_dispatch`(version_name) → 서명된 `app-release.aab` 아티팩트 → 내부 테스트 트랙 업로드 → Play App Signing 등록.
3. 정책 페이지 게시(GitHub Pages 또는 다른 호스트) → 필요하면 변수 `HANDE_PRIVACY_URL`/`HANDE_DELETE_URL` → 콘솔 「개인정보처리방침 URL」·「계정 삭제 URL」 에 같은 주소.
4. App content: Data safety(`play-data-safety.md`) · 콘텐츠 등급(IARC) · 광고 없음 · App access(심사용 데모 서버·계정 — iOS 와 공용) · 건강/금융 해당 없음 · 뉴스 앱 아님.
5. 내부 테스트 → (조직 계정이라 비공개 테스트 12명×14일 면제) → production 신청.

## 다음
C(UI: 방 목록·대화 다듬기·첨부 ≤256 KiB·정지 표시) · D(FCM — 릴레이 G3 푸시 와이어 일반화 선행) · E(Play 내부 테스트 트랙 — 위 체크리스트).
