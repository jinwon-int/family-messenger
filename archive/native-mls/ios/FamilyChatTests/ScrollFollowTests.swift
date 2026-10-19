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

    /// 키보드가 올라와 메시지 칸이 줄면 최신 메시지를 키보드 바로 위로 다시 맞춘다.
    func testShrinkingViewportRescrollsWhileFollowing() {
        XCTAssertTrue(ScrollFollow.shouldRescrollOnResize(old: 620, new: 330, following: true), "keyboard up")
        XCTAssertTrue(ScrollFollow.shouldRescrollOnResize(old: 330, new: 300, following: true), "composer grew a line")
        XCTAssertFalse(ScrollFollow.shouldRescrollOnResize(old: 620, new: 330, following: false), "reading older messages")
        XCTAssertFalse(ScrollFollow.shouldRescrollOnResize(old: 330, new: 620, following: true), "keyboard down")
        XCTAssertFalse(ScrollFollow.shouldRescrollOnResize(old: 0, new: 620, following: true), "first layout")
        XCTAssertFalse(ScrollFollow.shouldRescrollOnResize(old: 620, new: 619.8, following: true), "sub-point jitter")
    }
}
