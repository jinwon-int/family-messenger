// #666 공유 시트 대화 추천 — 식별자 규칙·스코프 거르기·내릴 방 계산.
import XCTest
@testable import FamilyMLSCore

final class ShareSuggestionsTests: XCTestCase {
    func testConversationIdentifierRoundTripsWithinTheSameScope() {
        let id = ShareSuggestions.conversation(scope: "relay.test", room: "family")
        XCTAssertEqual(id, "relay.test/family")
        XCTAssertEqual(ShareSuggestions.room(conversation: id, scope: "relay.test"), "family")
    }

    func testIdentifierFromAnotherScopeIsIgnored() {
        let id = ShareSuggestions.conversation(scope: "old.server", room: "family")
        XCTAssertNil(ShareSuggestions.room(conversation: id, scope: "relay.test"))
        XCTAssertNil(ShareSuggestions.room(conversation: "relay.test", scope: "relay.test"), "방 없음")
        XCTAssertNil(ShareSuggestions.room(conversation: "relay.test/", scope: "relay.test"), "빈 방")
        XCTAssertNil(ShareSuggestions.room(conversation: "relay.test/a/b", scope: "relay.test"), "식별자 형식 아님")
        XCTAssertNil(ShareSuggestions.room(conversation: "relay.test-2/family", scope: "relay.test"), "접두 일치가 아니라 스코프 일치")
    }

    func testRetiredIsPreviousMinusCurrentInPreviousOrder() {
        XCTAssertEqual(ShareSuggestions.retired(previous: ["b", "a", "c"], current: ["a"]), ["b", "c"])
        XCTAssertEqual(ShareSuggestions.retired(previous: [], current: ["a"]), [])
        XCTAssertEqual(ShareSuggestions.retired(previous: ["a"], current: ["a", "b"]), [])
    }

    func testDefaultDonorDoesNothing() {
        let donor = ShareSuggestionDonor()
        donor.donate("x/y", "y"); donor.delete(["x/y"]); donor.deleteAll()   // 아무 일도 없다(크래시 없음)
    }
}
