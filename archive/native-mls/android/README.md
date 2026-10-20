# android — 「한데」 Android 호스트 (#338 · #366 3b)

> **상태: 스파이크 A 2차(JVM 왕복).** Android 앱(Compose) 은 아직 없다. 여기에는 Rust 코어(`MlsRoom`, [`../HOST-CONTRACT.md`](../HOST-CONTRACT.md))를
> Kotlin 에서 쓰는 **호스트 어댑터**와, 그것이 봇·Rust 테스트와 같은 규칙으로 도는지 Linux JVM 에서 확인하는 **왕복 테스트**가 있다.
> 바인딩·`.so` 는 [`../ios-ffi`](../ios-ffi/README.md) `build-android.sh` 가 만든다(크레이트 개명은 #338 §2 결정 뒤).

| 경로 | 역할 |
|---|---|
| `host/src/main/kotlin/.../host/JdkHttpTransport.kt` | `HttpTransport` — `HttpURLConnection`(Android 에도 있음). 응답이 있으면 상태코드 그대로, 연결 실패만 throw(→ transient). 앱은 OkHttp 로 바꿔도 같은 규칙 |
| `host/src/main/kotlin/.../host/FileRoomStore.kt` | `RoomObserver` — 원자 영속(tmp → fsync → rename → 디렉터리 fsync) · 정지 마커 · 이벤트/메시지 싱크 · `load()` → `MlsRoom.import`. `seal`/`open` 훅에 Keystore 봉인(EncryptedFile 상당)을 끼운다 |
| `host/src/main/kotlin/.../host/FileLobbyStore.kt` | `LobbyObserver`(3c) — 로비 슬롯(시드 + 로비 key package 비밀 + 게시 장부) 한 파일 원자 영속 · `load()` → `MlsLobby.import`. 같은 `seal`/`open` 훅 |
| `host/src/test/kotlin/.../host/InMemoryRelay.kt` | 테스트 전용 in-memory 릴레이(`ios-ffi/tests/support/mod.rs` 의 Relay 와 같은 규칙: events + 로비·방 목록·닫기·푸시) |
| `host/src/test/kotlin/.../host/RoomRoundtrip.kt` | `main` 하나로 5 시나리오: 두 기기 왕복 · 409 재전송 · 영속 뒤 `import` 이어 받기 · 전송 실패 transient + 잘린 이력 정지(재시작 뒤 유지) · **로비**(보충 → steward 가 로비 키로 초대 → `welcomes` → `MlsRoom.adopt` → 방 목록 → 닫기 410 → 푸시 등록 → 회수). JUnit 의존 0 |
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

CI: `.github/workflows/native-mls-android.yml` — 3 ABI `.so` 뒤 같은 job 에서 JVM 왕복(ubuntu, 예산 ≤20분).

## 의존성 (#177 원칙 5)

| 항목 | 핀 | 라이선스 | 왜 |
|---|---|---|---|
| JNA | `5.17.0` | Apache-2.0 / LGPL-2.1 (이중) | uniffi Kotlin 바인딩의 런타임 요구(#338 §5 예고). 앱은 Gradle 의존으로, 여기선 jar 직접 |
| Kotlin 컴파일러 | `2.1.20` | Apache-2.0 | 테스트 빌드 도구(앱 의존 아님) |

## 기기 수준 호출(3c) — `MlsLobby`

방 밖의 일은 기기 하나에 하나인 `MlsLobby`([`../HOST-CONTRACT.md` §2b](../HOST-CONTRACT.md)) 가 맡는다: 로비 key package 보충(`replenish(8)` — 시작·포그라운드·방 참여 뒤), 로비 Welcome 발견(`welcomes()` → `MlsRoom.adopt(identity, room, lobby.seedState(), seq - 1, …)`), 방 목록(`rooms()`), 푸시 등록(`registerPush(token, "com.seoyoon_family.familychat")`), 회수(`withdraw()`). **방은 전부 `MlsRoom.adopt(…, lobby.seedState(), 0, …)` 로 만든다** — 그래야 서명키가 하나다(`MlsRoom(identity, …)` 생성자는 새 키를 만드는 테스트 대역용). 영속은 `FileLobbyStore`.

## 다음
OkHttp/EncryptedFile 실제 구현 · Compose 앱 골격(#338 B) · 푸시 와이어 FCM 일반화는 릴레이(#338 G3).
