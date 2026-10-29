# 한데(코드명 FamilyChat) iOS (독자 E2EE) — 앱 트리 (#271)

| 디렉터리 | 역할 | 소유 |
|---|---|---|
| `FamilyMLSCore/` | 순수 Swift 계약 층(프로토콜·와이어 타입·참조 구현·계약 테스트). Linux `swift test` | 계약: CONTRACTS.md PR · 구현: L1(`Store/File*`) · L3(`Relay/URLSession*`, `Sync/`, `Policy/`) |
| `FamilyChat/` | 앱 타깃: `AppModel` 상태기계(starting→needsLogin→needsEnrollment→ready⇄halted), 화면(§9), `FfiEngine`(xcframework 어댑터) | 파이널라이저 |
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

뼈대 단계(2026-10-05)에서 앱은 InMemory 스토어를 쓰고 네트워크가 없다. L1·L3 머지 후 `AppModel.Dependencies.live()` 의
의존성만 파일 스토어·릴레이 동기화로 바뀐다. 푸시/NSE(§12-D)·첨부·QR 등록(§12-E)은 통합 단계.
