// swift-tools-version:5.9
// FamilyMLSCore — iOS 앱의 **순수 Swift 계약 층**(#271 계약 동결, CONTRACTS.md).
// xcframework(Rust)·URLSession·SQLite·Keychain 에 의존하지 않으므로 Linux 에서도 `swift test` 가 돈다
// (CI `swift-core-linux`, 1~2분). 레인 L1(저장)·L3(릴레이/동기화)은 이 패키지 안의 자기 디렉터리에서
// 프로토콜을 구현하고, 같은 계약 테스트(`StateStoreContract`)를 통과시킨다.
import PackageDescription

let package = Package(
    name: "FamilyMLSCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "FamilyMLSCore", targets: ["FamilyMLSCore"]),
    ],
    targets: [
        .target(name: "FamilyMLSCore", path: "Sources/FamilyMLSCore"),
        .testTarget(name: "FamilyMLSCoreTests", dependencies: ["FamilyMLSCore"], path: "Tests/FamilyMLSCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
