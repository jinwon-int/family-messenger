// 사진 보기 위·아래로 밀어 닫기 판정(오너 2026-11-05) — 세로 최소 거리(양방향 같은 기준) · 세로 우세.
import XCTest
@testable import FamilyMLSCore

final class PhotoSwipeDismissTests: XCTestCase {
    func testUpwardSwipeDismisses() {
        XCTAssertTrue(PhotoSwipeDismiss.shouldDismiss(dx: 0, dy: -80), "exactly the minimum distance")
        XCTAssertTrue(PhotoSwipeDismiss.shouldDismiss(dx: 20, dy: -200))
    }

    func testDownwardSwipeDismisses() {
        XCTAssertTrue(PhotoSwipeDismiss.shouldDismiss(dx: 0, dy: 80), "exactly the minimum distance")
        XCTAssertTrue(PhotoSwipeDismiss.shouldDismiss(dx: -20, dy: 200))
    }

    func testShortSwipeDoesNotDismiss() {
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 0, dy: -79.9), "below the minimum distance, up")
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 0, dy: 79.9), "below the minimum distance, down")
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 0, dy: 0))
    }

    func testDiagonalOrSidewaysSwipeDoesNotDismiss() {
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 200, dy: -90), "sideways")
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 200, dy: 90), "sideways, down")
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: -60, dy: -90), "90 is not > 60 × 1.5")
        XCTAssertFalse(PhotoSwipeDismiss.shouldDismiss(dx: 60, dy: 90), "90 is not > 60 × 1.5, down")
        XCTAssertTrue(PhotoSwipeDismiss.shouldDismiss(dx: -60, dy: -91), "just past the dominance ratio")
        XCTAssertTrue(PhotoSwipeDismiss.shouldDismiss(dx: 60, dy: 91), "just past the dominance ratio, down")
    }
}
