// 사진 보기 위로 밀어 닫기 판정(오너 2026-11-05) — 위쪽 최소 거리 · 세로 우세 · 아래로는 따라가지 않음.
import XCTest
@testable import FamilyMLSCore

final class PhotoSwipeDismissTests: XCTestCase {
    func testUpwardSwipeDismisses() {
        XCTAssertTrue(PhotoSwipeDismiss.shouldDismiss(dx: 0, dy: -80), "exactly the minimum distance")
        XCTAssertTrue(PhotoSwipeDismiss.shouldDismiss(dx: 20, dy: -200))
    }

    func testShortOrDownwardSwipeDoesNotDismiss() {
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 0, dy: -79.9), "below the minimum distance")
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 0, dy: 200), "downward")
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 0, dy: 0))
    }

    func testDiagonalOrSidewaysSwipeDoesNotDismiss() {
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 200, dy: -90), "sideways")
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: -60, dy: -90), "90 is not > 60 × 1.5")
        XCTAssertTrue(PhotoSwipeDismiss.shouldDismiss(dx: -60, dy: -91), "just past the dominance ratio")
    }

    func testFollowOffsetMovesUpOnly() {
        XCTAssertEqual(PhotoSwipeDismiss.followOffset(dy: -120), -120)
        XCTAssertEqual(PhotoSwipeDismiss.followOffset(dy: 50), 0)
    }
}
