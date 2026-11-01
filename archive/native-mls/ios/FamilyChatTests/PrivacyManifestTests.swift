import XCTest
@testable import FamilyChat

/// #584 PR 4: Privacy manifest(`PrivacyInfo.xcprivacy`)가 docs/hande/app-store-review.md §1 의 App Privacy 답과 같은지(수집 유형·연결·추적 없음),
/// Required Reason API 범주가 코드에서 확인한 것(UserDefaults · 파일 메타데이터)과 **정확히** 같은지, 두 타깃 번들 루트에 실제로 들어갔는지.
/// 파일은 저장소 경로(`#filePath` 기준)에서 읽는다 — Linux 스모크 복사 목록에는 넣지 않는다(복사하면 상대 경로가 깨진다).
final class PrivacyManifestTests: XCTestCase {
    /// `archive/native-mls/ios/`
    private static let iosDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static let expectedAPIs: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
    ]
    private static let appFunctionality = ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]

    private func manifest(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.iosDir.appendingPathComponent(relative))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any], relative)
    }

    private func accessedAPIs(_ manifest: [String: Any]) throws -> [String: [String]] {
        let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var out: [String: [String]] = [:]
        for entry in entries {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            XCTAssertNil(out[type], "duplicate category \(type)")
            out[type] = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        return out
    }

    private func collectedTypes(_ manifest: [String: Any]) throws -> [String] {
        let entries = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        return try entries.map { entry -> String in
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String], Self.appFunctionality)
            return try XCTUnwrap(entry["NSPrivacyCollectedDataType"] as? String)
        }
    }

    func testAppManifestMatchesTheAppPrivacyAnswers() throws {
        let app = try manifest("FamilyChat/PrivacyInfo.xcprivacy")
        XCTAssertEqual(app["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(app["NSPrivacyTrackingDomains"] as? [String]), [])
        // app-store-review.md §1-1 표: Email · Name · User ID · Device ID · Other User Content — 메시지 내용(Emails or Text Messages)은 E2EE 라 신고하지 않음(ⓐ 오너 결정).
        XCTAssertEqual(try collectedTypes(app), [
            "NSPrivacyCollectedDataTypeEmailAddress",
            "NSPrivacyCollectedDataTypeName",
            "NSPrivacyCollectedDataTypeUserID",
            "NSPrivacyCollectedDataTypeDeviceID",
            "NSPrivacyCollectedDataTypeOtherUserContent",
        ])
        XCTAssertEqual(try accessedAPIs(app), Self.expectedAPIs)
    }

    func testExtensionManifestDeclaresOnlyWhatTheExtensionSends() throws {
        let nse = try manifest("FamilyChatNSE/PrivacyInfo.xcprivacy")
        XCTAssertEqual(nse["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(nse["NSPrivacyTrackingDomains"] as? [String]), [])
        // NSE 는 릴레이에서 읽기만 한다 — 요청이 싣는 식별자(세션 subject · 기기 ID)만.
        XCTAssertEqual(try collectedTypes(nse), ["NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeDeviceID"])
        // Required Reason API 는 앱과 같은 코드(SharedStorage·ServerStore·DeviceIdentity + Rust 라이브러리)라 같은 선언.
        XCTAssertEqual(try accessedAPIs(nse), Self.expectedAPIs)
    }

    /// #643 공유 확장: 네트워크 없이 기기 안 App Group 에 맡기기만 한다 — 수집 유형 없음, App Group defaults(1C8F.1)만.
    /// (Rust 라이브러리·파일 시각 API 를 쓰지 않으므로 FileTimestamp 범주가 없다 — 앱·NSE 와 다르다.)
    func testShareExtensionManifestDeclaresNoCollectionAndOnlyAppGroupDefaults() throws {
        let share = try manifest("FamilyChatShare/PrivacyInfo.xcprivacy")
        XCTAssertEqual(share["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(share["NSPrivacyTrackingDomains"] as? [String]), [])
        XCTAssertEqual(try collectedTypes(share), [])
        XCTAssertEqual(try accessedAPIs(share), ["NSPrivacyAccessedAPICategoryUserDefaults": ["1C8F.1"]])
    }

    /// 호스트 앱(FamilyChat.app)에서 도는 경우에만: xcodegen 이 세 파일을 Resources 로 넣어 번들 루트에 복사했는지(ITMS-91053 예방).
    func testManifestsAreBundledAtTheRootOfTheAppAndTheExtension() throws {
        let app = Bundle.main
        try XCTSkipUnless(app.bundleURL.pathExtension == "app", "hosted test only (Bundle.main = \(app.bundleURL.lastPathComponent))")
        XCTAssertNotNil(app.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "app bundle root")
        let nse = app.bundleURL.appendingPathComponent("PlugIns/FamilyChatNSE.appex/PrivacyInfo.xcprivacy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nse.path), nse.path)
        let share = app.bundleURL.appendingPathComponent("PlugIns/FamilyChatShare.appex/PrivacyInfo.xcprivacy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: share.path), share.path)
    }

    func testPolicyLinksAreTheCanonicalPagesURLs() {
        XCTAssertEqual(PolicyLinks.site.absoluteString, "https://jinwon-int.github.io/family-messenger/hande/")
        XCTAssertEqual(PolicyLinks.privacy.absoluteString, "https://jinwon-int.github.io/family-messenger/hande/privacy/")
        XCTAssertEqual(PolicyLinks.deleteAccount.absoluteString, "https://jinwon-int.github.io/family-messenger/hande/delete-account/")
        for url in [PolicyLinks.site, PolicyLinks.privacy, PolicyLinks.deleteAccount] {
            XCTAssertEqual(url.scheme, "https", url.absoluteString)
        }
    }

    func testAppVersionLineUsesShortVersionAndBuild() {
        XCTAssertEqual(Strings.appVersion("0.1.0", "57"), "0.1.0 (57)")
        XCTAssertEqual(SettingsView.appVersionLine(Bundle(for: PrivacyManifestTests.self)).split(separator: " ").count, 2)
    }
}
