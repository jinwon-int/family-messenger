// #398: 사진이 늦게 로드돼 커진 행 → 최하단 다시 따라가기 판정.
import XCTest
@testable import FamilyChat

final class ScrollFollowTests: XCTestCase {
    func testTailRowsRescrollWhileFollowing() {
        let ids: [Int64] = [10, 11, 12, 13, 14]
        XCTAssertTrue(ScrollFollow.shouldRescroll(loaded: 14, ids: ids, following: true), "the last row grew")
        XCTAssertTrue(ScrollFollow.shouldRescroll(loaded: 12, ids: ids, following: true), "third from the end still pushes the bottom")
        XCTAssertFalse(ScrollFollow.shouldRescroll(loaded: 11, ids: ids, following: true), "an older photo does not move the view")
    }

    func testUserScrolledUpNeverRescrolls() {
        XCTAssertFalse(ScrollFollow.shouldRescroll(loaded: 14, ids: [13, 14], following: false))
    }

    func testUnknownRowAndShortTimeline() {
        XCTAssertFalse(ScrollFollow.shouldRescroll(loaded: 99, ids: [1, 2, 3], following: true), "a row no longer in the timeline")
        XCTAssertTrue(ScrollFollow.shouldRescroll(loaded: 1, ids: [1], following: true))
        XCTAssertFalse(ScrollFollow.shouldRescroll(loaded: 1, ids: [], following: true))
    }
}
