// 방별 작성 초안(LocalPrefs.draft/setDraft/clearDrafts) — 방을 나갔다 와도·앱을 다시 켜도 쓰던 글이 남는다(웹 drafts.js 와 같은 역할).
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class LocalPrefsDraftTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "hande.tests.drafts.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testDraftSurvivesANewPrefsInstanceAndIsPerRoom() throws {
        let base = try defaults()
        let prefs = LocalPrefs(defaults: base)
        XCTAssertEqual(prefs.draft(for: "family"), "")
        prefs.setDraft("쓰다 만 글", for: "family")
        prefs.setDraft("다른 방", for: "family-acc")
        // 앱을 다시 켠 것과 같다: 같은 저장소에서 새로 읽는다.
        let again = LocalPrefs(defaults: base)
        XCTAssertEqual(again.draft(for: "family"), "쓰다 만 글")
        XCTAssertEqual(again.draft(for: "family-acc"), "다른 방")
        XCTAssertEqual(again.draft(for: "fleet-alerts"), "")
    }

    func testEmptyDraftRemovesTheRoomAndTheKeyWhenNothingIsLeft() throws {
        let base = try defaults()
        let prefs = LocalPrefs(defaults: base)
        prefs.setDraft("a", for: "family")
        prefs.setDraft("b", for: "family-acc")
        prefs.setDraft("", for: "family")   // 보냈거나 다 지웠다
        XCTAssertEqual(LocalPrefs(defaults: base).draft(for: "family"), "")
        XCTAssertNotNil(base.object(forKey: LocalPrefs.draftKey))
        prefs.setDraft("", for: "family-acc")
        XCTAssertNil(base.object(forKey: LocalPrefs.draftKey), "빈 초안만 남으면 키를 지운다")
    }

    func testDraftIsCappedAndWhitespaceIsKept() throws {
        let base = try defaults()
        let prefs = LocalPrefs(defaults: base)
        prefs.setDraft(String(repeating: "가", count: LocalPrefs.draftLimit + 50), for: "family")
        XCTAssertEqual(LocalPrefs(defaults: base).draft(for: "family").count, LocalPrefs.draftLimit)
        prefs.setDraft("줄 끝 공백 \n", for: "family")
        XCTAssertEqual(LocalPrefs(defaults: base).draft(for: "family"), "줄 끝 공백 \n")
    }

    func testDraftsAreScopedPerServerAndClearedByWipe() throws {
        let base = try defaults()
        let a = LocalPrefs(defaults: ServerScope(baseURL: URL(string: "https://a.example.com")!).defaults(base))
        let b = LocalPrefs(defaults: ServerScope(baseURL: URL(string: "https://b.example.com")!).defaults(base))
        a.setDraft("서버 A", for: "family")
        XCTAssertEqual(b.draft(for: "family"), "", "다른 서버의 초안은 보이지 않는다")
        a.markRead("family", seq: 3)
        a.clearDrafts()
        let again = LocalPrefs(defaults: ServerScope(baseURL: URL(string: "https://a.example.com")!).defaults(base))
        XCTAssertEqual(again.draft(for: "family"), "")
        XCTAssertEqual(again.readSeq["family"], 3, "기기 지우기는 초안만 지우고 표시 설정은 둔다")
    }
}
