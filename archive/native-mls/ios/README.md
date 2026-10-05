# iOS 스파이크 앱 (#271 §12-A)

`../ios-ffi/build-xcframework.sh` 가 만든 `FamilyMLS.xcframework` + 생성 Swift 바인딩을 링크한 빈 SwiftUI 앱.
XCTest(`FamilyMLSSpikeTests`)가 **시뮬레이터에서 Rust 파사드를 실행**해 2기기 E2EE 왕복·상태 export/import·거부 롤백을
검사한다 — `ios-ffi/tests/host_roundtrip.rs` 와 같은 시나리오·같은 프레이밍.

```bash
../ios-ffi/build-xcframework.sh
brew install xcodegen && xcodegen generate
xcodebuild -project FamilyMLSSpike.xcodeproj -scheme FamilyMLSSpike \
  -destination 'platform=iOS Simulator,name=<iPhone>' CODE_SIGNING_ALLOWED=NO test
```

제품 앱(#271 §9)의 화면·영속·릴레이·NSE 는 여기 없다. 설계가 성립하면 이 디렉터리가 제품 앱 트리로 자란다(`archive/` 규칙: 결정 E 규칙 1).
