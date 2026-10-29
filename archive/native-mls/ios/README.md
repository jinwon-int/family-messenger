# 한데(코드명 FamilyChat) iOS (독자 E2EE) — 앱 트리 (#271)

| 디렉터리 | 역할 | 소유 |
|---|---|---|
| `FamilyMLSCore/` | 순수 Swift 계약 층(프로토콜·와이어 타입·참조 구현·계약 테스트). Linux `swift test` | 계약: CONTRACTS.md PR · 구현: L1(`Store/File*`) · L3(`Relay/URLSession*`, `Sync/`, `Policy/`) |
| `FamilyChat/` | 앱 타깃: `AppModel` 상태기계(starting→needsServer→needsActor→needsLogin→needsEnrollment→ready⇄halted), 화면(§9), `FfiEngine`(xcframework 어댑터) | 파이널라이저 |
| `FamilyChatTests/` | 시뮬레이터 XCTest: 상태기계(가짜 엔진) + Rust 파사드 2기기 E2EE 왕복 | 파이널라이저 |
| `project.yml` | XcodeGen 정의(생성물 커밋 금지) | 파이널라이저 |

```bash
../ios-ffi/build-xcframework.sh
brew install xcodegen && xcodegen generate
xcodebuild -project FamilyChat.xcodeproj -scheme FamilyChat \
  -destination 'platform=iOS Simulator,name=<iPhone>' CODE_SIGNING_ALLOWED=NO test
```

새 기기 셀프서비스(#574 PR 3, 2026-10-29): 등록 대기 화면이 후보를 릴레이 우편함에 올리고(`AppModel.enrollment`), 같은 계정의 다른 기기가
🔔 알림 → 「새 기기 승인」에서 지문을 비교해 승인하면(`sign_approval`, `Views/DevicesView.swift`) 그 기기가 참여한 대화방에 자동 초대된다
(형제 기기가 보낸 로비 Welcome 은 가족 기기도 자동 수락). 설정 → 「내 기기」가 체인의 내 기기와 등록 기기(registrar) 부여/해제(`sign_roles`)를
보인다. 판정은 `FamilyMLSCore/Sync/SelfService.swift`(웹 `self-service.js` 와 동일), 와이어는 CONTRACTS.md §2.3.

## 온보딩 — 서버 선택(#584 PR 2, 2026-10-29)

한데 iOS 는 App Store 공개 앱을 전제로 한다(Element 의 홈서버 선택과 같은 구조). 릴레이 주소는 더 이상 빌드 시점 상수가 아니다.

1. **첫 화면 `ServerSelectView`**(`AppModel.Phase.needsServer`): 도메인(`example.com`)이나 https 주소를 입력 → 「서버 찾기」 →
   `https://<host>/.well-known/hande` → `https://hande.<host>/.well-known/hande` → (없으면) 입력 주소를 릴레이로 → `GET /v2/health` 확인
   (`FamilyMLSCore/Relay/ServerDiscovery.swift`, CONTRACTS.md §2.5) → 서버 이름·주소 확인 → 「이 서버로 계속」 → 기존 흐름(사용자 이름 → Google 로그인 → 등록).
   웹 설정 화면의 `hande://server?url=…` 링크를 붙여넣거나 열어도 된다. QR 스캔은 카메라 권한(`NSCameraUsageDescription`)이 아직 없어 후속.
   오류: 못 찾음 · 릴레이 응답 없음 · 앱이 너무 오래됨(`min_app.ios`) · http 거부.
2. **저장**: 선택은 App Group UserDefaults `hande.server`(JSON) — NSE 도 같은 값을 읽는다(`ServerStore.resolve`, App Group → Info.plist 폴백).
3. **서버별 네임스페이스 `ServerScope`**(`Sync/ServerScope.swift`): 서버마다 `servers/<id>/` 디렉터리(MLS 상태·messages.db), 기기 ID·사용자 이름·푸시 기록·읽음 위치·방 순서의 defaults 키, Keychain 자격증명 account 가 따로다 — 서버를 바꿔도 데이터가 섞이지 않는다. 봉인 키만 공용(파일 보호 키).
4. **설정 → 서버**: 현재 서버(이름·주소·찾은 방법) + 「서버 바꾸기」 — 로그아웃(푸시 DELETE·이 스코프의 자격증명 삭제) 뒤 서버 선택 화면. 이 서버의 로컬 데이터는 그 스코프에 남고, 새 서버는 빈 스코프(새 기기)로 시작한다. 로그인·이름 화면에도 「다른 서버 선택」이 있다.
5. **`FC_RELAY_URL` 은 기본값**(project.yml): 값이 있으면(가족 TestFlight — 릴리스 워크플로가 `vars.FC_RELAY_URL` 로 채운다) 저장된 선택이 없을 때 그 서버를 그대로 쓰고(첫 화면 생략, `discoveredVia: .buildDefault`) 서버 선택 화면에 미리 채운다. **App Store 빌드는 비워 둔다** — `native-mls-ios-release.yml` 의 `workflow_dispatch` 입력 **`distribution`**(PR 4): `testflight-family`(기본, `vars.FC_RELAY_URL` 을 넣는 지금까지의 가족 빌드) / `appstore-public`(`FC_RELAY_URL=""` 로 archive → Info.plist `FamilyChatRelayURL` 빈 문자열 → `Bundle.familyChatValue` 가 nil → `ServerStore.resolve(.unset, defaultURL: nil)` = nil → 첫 화면이 서버 선택). 서명·버전·업로드·environment `testflight` 승인은 같고, 아카이브 검증 단계가 앱·NSE Info.plist 의 `FamilyChatRelayURL` 이 배포 종류와 맞는지(공개 = 빈 값)와 Privacy manifest 두 개가 번들 루트에 있는지 확인한다.
6. **옛 설치 이관**(`Sync/LegacyScopeMigration.swift`): 업데이트 뒤 첫 실행에 저장된 선택이 없고 기본값이 있으면 스코프 없는 자리의 `mls/`·`messages.db*`·기기 ID·사용자 이름·푸시 기록·읽음 위치·방 순서·Keychain `v1` 자격증명을 기본 서버 스코프로 한 번 옮기고 `hande.server` 에 기본 서버를 적는다. 가족 기기는 화면 변화 없이 그대로 이어진다(재로그인 불필요). 그 사이 NSE 가 먼저 깨면 스코프 디렉터리가 없어 대체 알림만 보인다(앱을 한 번 열면 끝).

테스트: `FamilyMLSCoreTests/ServerDiscoveryTests`(순수, Linux) · `FamilyChatTests/ServerScopeTests`(저장·스코프·이관, Linux 스모크에도 복사) ·
`AppModelTests`(needsServer / 기본값 / 탐색·선택 / 서버 바꾸기 / reopen).

## App Store 준비(#584 PR 4, 2026-10-29) — Privacy manifest · 온보딩 문구 · 정책 링크

App Store Connect 쪽 답(App Privacy·심사 노트·수출 규정)은 [`docs/hande/app-store-review.md`](../../../docs/hande/app-store-review.md), 체크리스트는 [`release-checklist.md`](../../../docs/hande/release-checklist.md)(A-2·A-7·A-8 가 이 절).

1. **Privacy manifest** — `FamilyChat/PrivacyInfo.xcprivacy`(앱)·`FamilyChatNSE/PrivacyInfo.xcprivacy`(알림 확장). 두 파일은 각 타깃의 소스 그룹 안에 있어 xcodegen 이 Resources 로 넣는다(알 수 없는 확장자의 기본 build phase; 별도 항목으로 또 적으면 중복). `NSPrivacyTracking = false`, 추적 도메인 없음.
   - **수집 유형**(앱): `app-store-review.md` §1-1 표 그대로 — Email Address(CF Access subject) · Name(actor) · User ID(체인의 기기 기록) · Device ID(앱이 만든 기기 ID + APNs 토큰) · Other User Content(대화방 이름·참여 목록·읽음 위치·발신 시각), 모두 Linked=예 · Tracking=아니오 · App Functionality. 메시지 내용(Emails or Text Messages)은 E2EE 라 신고하지 않는다(§1-1 ⓐ 오너 결정; 보수적으로 가려면 두 파일과 ASC 라벨을 함께 바꾼다). NSE 는 릴레이에서 읽기만 하므로 그 요청이 싣는 User ID · Device ID 만.
   - **Required Reason API** — 코드 grep(2026-10-29, Swift 앱·NSE·FamilyMLSCore 소스 + 정적 링크되는 Rust 크레이트)으로 확인한 범주만 적는다. 바꾸면 `FamilyChatTests/PrivacyManifestTests` 의 기대값도 함께.

     | 범주 | 사유 | 근거(코드) |
     |---|---|---|
     | `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1`(앱 전용 `.standard`) + `1C8F.1`(앱·NSE 가 공유하는 App Group suite) | `Sync/SharedStorage.swift`(`UserDefaults(suiteName:)`·`.standard` 1회 이관) · `Sync/ServerStore.swift`(`hande.server`) · `Sync/ServerScope.swift`(`ScopedDefaults`) · `Sync/LocalPrefs.swift` · `Engine/DeviceIdentity.swift` · `Push/PushRegistrar.swift`(`UserDefaultsPushRecordStore`) · Core `Sync/SelfService.swift`(`UserDefaultsSiblingQueueStore`) |
     | `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1`(앱 컨테이너·App Group 컨테이너 안 파일의 메타데이터) | Swift 소스에는 없다(`FileManager.attributesOfItem` 은 Core 테스트에만). 정적 링크되는 Rust 라이브러리 `FamilyMLS.xcframework` 가 `stat`/`fstat` 를 참조한다 — `host-core/src/api.rs` `Access::File` 의 `std::fs::read_to_string`(iOS 는 `Access::Static/None` 만 만들지만 같은 함수에 컴파일된다)과 Rust std 의 panic 백트레이스 심볼화(dSYM `File::metadata`). 접근 대상은 전부 앱 컨테이너 안 |
     | 시스템 부팅 시각(`systemUptime`·`mach_absolute_time`) · 디스크 공간(`volumeAvailableCapacity*`) · 활성 키보드(`activeInputModes`) | 선언하지 않음 | grep 결과 없음(Rust std 의 `Instant` 는 `clock_gettime` 을 쓰고 호스트 크레이트는 `Instant` 를 쓰지 않는다) |

   ASC 는 업로드 뒤 바이너리의 심볼을 보고 빠진 범주를 **ITMS-91053** 메일로 알린다 — 메일이 오면 그 범주를 표·두 파일·테스트에 추가한다(릴리스 워크플로의 아카이브 검증 단계는 두 파일이 번들 루트에 있는지만 본다).
2. **App Store 빌드 입력** — 「온보딩 — 서버 선택」 5(`distribution` 입력).
3. **온보딩 문구(가이드라인 4.2 대비, `Strings+Server.swift`·`Strings.swift`)** — 서버 선택 화면 상단에 「한데는 가족 운영자의 서버에 연결하는 종단간 암호화 메신저」 안내 + 안내서(`PolicyLinks.site` = `https://jinwon-int.github.io/family-messenger/hande/`)·개인정보처리방침 링크; 이름(`actorHint`)·로그인(`loginHint`) 화면은 「회원가입 없음·운영자가 등록」을 먼저 말한다. 대화방 목록 빈 상태(`Strings.noRooms`·`invitesInBell`)는 이미 있다.
4. **설정 정책 링크(`Strings+Policy.swift`·`SettingsView`)** — 「정책」 칸: 「개인정보처리방침」 → `…/hande/privacy/`, 「계정 및 데이터 삭제」 → `…/hande/delete-account/`(SwiftUI `Link` = Safari) + 첫 칸에 「앱 버전」(`CFBundleShortVersionString (CFBundleVersion)`). 「이 기기 지우기」(앱 내 삭제 경로)는 그대로 두고 설명에 「서버의 기기 기록은 「계정 및 데이터 삭제」 안내로」를 더했다 — `docs/hande/delete-account.md`·Android `Strings.wipeDeviceHint` 와 같은 구성. 라벨은 Android 와 같다. 주소를 바꾸면 Android `BuildConfig`/repo variables·스토어 콘솔을 함께.
5. **테스트** — `FamilyChatTests/PrivacyManifestTests`(두 매니페스트를 `#filePath` 기준 저장소 경로에서 읽어 수집 유형·API 범주·사유를 정확히 비교, 호스트 앱에서 돌 때는 번들 루트·`PlugIns/FamilyChatNSE.appex` 에 복사됐는지, 정책 URL 정본). Linux 스모크 복사 목록에는 넣지 않는다(복사하면 상대 경로가 깨진다) — macOS `native-mls-ios.yml` ios-build 가 돌린다.

뼈대 단계(2026-10-05)에서 앱은 InMemory 스토어를 쓰고 네트워크가 없다. L1·L3 머지 후 `AppModel.Dependencies.live()` 의
의존성만 파일 스토어·릴레이 동기화로 바뀐다. 푸시/NSE(§12-D)·첨부·QR 등록(§12-E)은 통합 단계.
