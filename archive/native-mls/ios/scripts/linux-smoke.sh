#!/usr/bin/env bash
# 격리 릴레이 스모크 — Linux 실행기 (#276 §2.4, 파이널라이저 PR ③).
#
# 왜 Linux 인가: Go 릴레이는 Linux 전용이다(internal/devicepolicy 의 dirfd 기반 syscall.Openat/Renameat — darwin 빌드 불가),
# GitHub macOS 러너에는 Docker 가 없고, -access-mode disabled 는 loopback 만 허용한다. 그래서 같은 Rust 파사드(ios-ffi)를
# Linux 호스트용 정적 라이브러리 + uniffi Swift 바인딩으로 만들고, 앱의 비UI 소스(AppModel·live()·RoomMembership·FfiEngine)와
# Core(URLSessionRelayTransport·RoomSyncEngine·File* 저장소)를 **그대로** 복사한 임시 SwiftPM 패키지에서
# FamilyChatTests 의 시나리오(TwoDeviceScenario·RelaySmokeTests)를 돌린다. iOS 시뮬레이터 실행은 native-mls-ios.yml ios-build.
#
# 입력(환경변수):
#   FFI_LIB_DIR        libfamily_mls_ios_ffi.a **만** 있는 디렉터리(.so 가 같이 있으면 링커가 동적 라이브러리를 고른다)
#   FFI_SWIFT_DIR      uniffi 산출물(FamilyMLS.swift · FamilyMLSFFI.h)
#   FC_SMOKE_RELAY_URL / FC_SMOKE_CONTROL_URL  (선택) 감독자가 띄운 릴레이 — 없으면 RelaySmokeTests 는 skip
# 리포는 읽기만 한다. 작업 패키지는 mktemp -d(또는 SMOKE_WORK)에 만든다.
#
# Linux 대역(이 스크립트 안에만): Combine(ObservableObject·@Published), App Group(containerURL), CryptoKit(SHA256·SymmetricKey).
# Linux Core 에는 CryptoKit 봉인이 없어 상태 파일은 Passthrough(Core 기본) — 봉인 경로는 macOS 시뮬레이터가 검증한다.
set -euo pipefail
: "${FFI_LIB_DIR:?}" "${FFI_SWIFT_DIR:?}"
ios="$(cd "$(dirname "$0")/.." && pwd)"
work="${SMOKE_WORK:-$(mktemp -d)}"
mkdir -p "$work/Sources/CryptoKit" "$work/Sources/FamilyMLSFFI/include" "$work/Sources/FamilyChat" "$work/Tests/FamilyChatTests"

cat > "$work/Package.swift" <<EOF
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "FamilyChatLinuxSmoke", platforms: [.macOS(.v13)],
  dependencies: [.package(path: "$ios/FamilyMLSCore")],
  targets: [
    .target(name: "CryptoKit", path: "Sources/CryptoKit"),
    .target(name: "FamilyMLSFFI", path: "Sources/FamilyMLSFFI",
            linkerSettings: [.unsafeFlags(["-L$FFI_LIB_DIR"]), .linkedLibrary("family_mls_ios_ffi"),
                             .linkedLibrary("m"), .linkedLibrary("dl"), .linkedLibrary("pthread")]),
    .target(name: "FamilyChat", dependencies: ["CryptoKit", "FamilyMLSFFI", .product(name: "FamilyMLSCore", package: "FamilyMLSCore")],
            path: "Sources/FamilyChat"),
    .testTarget(name: "FamilyChatTests", dependencies: ["FamilyChat", "CryptoKit", .product(name: "FamilyMLSCore", package: "FamilyMLSCore")],
                path: "Tests/FamilyChatTests"),
  ], swiftLanguageVersions: [.v5])
EOF

cat > "$work/Sources/CryptoKit/LinuxStub.swift" <<'EOF'
// Linux 스모크 전용 CryptoKit 대역 — 키 패키지 ref(식별용 해시, 보안 의미 없음)와 테스트 봉인 키 자리만.
import Foundation
public enum SHA256 {
    public static func hash(data: Data) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 32)
        for (i, b) in data.enumerated() { h[i % 32] = h[i % 32] &* 31 &+ b }
        return h
    }
}
public struct SymmetricKey { public enum Size { case bits256 }; public init(size: Size) {} }
EOF
echo '// 헤더를 모듈로 노출하는 빈 C 타깃(정적 라이브러리는 linkerSettings 로 링크).' > "$work/Sources/FamilyMLSFFI/shim.c"
cp "$FFI_SWIFT_DIR/FamilyMLSFFI.h" "$work/Sources/FamilyMLSFFI/include/"
printf 'module FamilyMLSFFI {\n  header "FamilyMLSFFI.h"\n  export *\n}\n' > "$work/Sources/FamilyMLSFFI/include/module.modulemap"
cat > "$work/Sources/FamilyChat/LinuxStubs.swift" <<'EOF'
// Linux 스모크 전용: Apple Foundation 이 노출하는 Combine 심볼·App Group API 대역.
import Foundation
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value; init(wrappedValue: Value) { self.wrappedValue = wrappedValue } }
extension FileManager { func containerURL(forSecurityApplicationGroupIdentifier: String) -> URL? { nil } }
EOF

# 앱 비UI 소스·테스트를 그대로 복사(뷰·SwiftUI 진입점·Keychain 테스트 제외).
cp "$FFI_SWIFT_DIR/FamilyMLS.swift" "$work/Sources/FamilyChat/"
cp "$ios"/FamilyChat/App/{AppModel,Strings,LiveDependencies}.swift "$ios"/FamilyChat/Sync/*.swift \
   "$ios"/FamilyChat/Engine/{DeviceIdentity,InMemoryMessageStore,FfiEngine}.swift "$work/Sources/FamilyChat/"
# 푸시 등록·NSE 처리(§12-D)는 플랫폼 무관 Swift(UIKit 부분은 #if canImport 로 가린다) — 디렉터리째 복사.
cp "$ios"/FamilyChat/Push/*.swift "$work/Sources/FamilyChat/"
cp "$ios"/FamilyChatTests/{AppModelTests,RoundtripTests,RelaySmokeTests}.swift "$ios"/FamilyChatTests/Support/*.swift \
   "$work/Tests/FamilyChatTests/"
sed -i 's/config.sealer = ChaChaPolySealer(key: sealKey).*/config.sealer = nil   \/\/ Linux: Core 기본(Passthrough)/' \
   "$work/Tests/FamilyChatTests/TwoDeviceScenario.swift"
grep -q 'config.sealer = nil' "$work/Tests/FamilyChatTests/TwoDeviceScenario.swift"
cat > "$work/Tests/FamilyChatTests/LinuxScenarioTests.swift" <<'EOF'
// IntegrationTests.testTwoDeviceScenarioOverInMemoryRelay 의 Linux 판(그 파일은 Keychain(Security)을 써서 복사하지 않는다).
import XCTest
@testable import FamilyChat
@MainActor final class LinuxScenarioTests: XCTestCase {
    func testTwoDeviceScenarioOverInMemoryRelay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fc-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = InMemoryRelay()
        try await TwoDeviceScenario(relay: relay, control: relay, root: root, room: "family").run()
    }
}
EOF

cd "$work"
swift test --scratch-path "$work/.build"
