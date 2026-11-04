// 대화방 → 목록 넓은 뒤로가기 스와이프 판정(오너 2026-11-04) — 시작 위치 3/5(오너 2026-11-05, 종전 2/5) · 최소 거리 · 가로 우세.
import XCTest
@testable import FamilyMLSCore

final class BackSwipeTests: XCTestCase {
    private let width = 390.0 // iPhone 세로 너비 예시 — 3/5 = 234pt

    func testStartInsideLeftThreeFifthsGoesBack() {
        XCTAssertTrue(BackSwipe.shouldGoBack(startX: 5, width: width, dx: 120, dy: 4), "edge start still works")
        XCTAssertTrue(BackSwipe.shouldGoBack(startX: 100, width: width, dx: 120, dy: 10))
        XCTAssertTrue(BackSwipe.shouldGoBack(startX: 200, width: width, dx: 120, dy: 10), "past the old 2/5 line (156pt) — now inside")
        XCTAssertTrue(BackSwipe.shouldGoBack(startX: 234, width: width, dx: 80, dy: 0), "exactly 3/5 and exactly the minimum distance")
    }

    func testStartPastThreeFifthsDoesNotGoBack() {
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 235, width: width, dx: 150, dy: 0))
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 300, width: width, dx: 80, dy: 0))
        XCTAssertEqual(BackSwipe.startZoneFraction, 0.6)
    }

    func testShortOrLeftwardDragDoesNotGoBack() {
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 50, width: width, dx: 79.9, dy: 0), "below the minimum distance")
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 150, width: width, dx: -120, dy: 0), "leftward")
    }

    func testVerticalOrDiagonalDragDoesNotGoBack() {
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 50, width: width, dx: 90, dy: 200), "timeline scroll")
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 50, width: width, dx: 90, dy: -60), "45°-ish diagonal: 90 is not > 60 × 1.5")
        XCTAssertTrue(BackSwipe.shouldGoBack(startX: 50, width: width, dx: 91, dy: -60), "just past the dominance ratio")
    }

    func testUnmeasuredWidthOrNegativeStartDoesNotGoBack() {
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 10, width: 0, dx: 200, dy: 0), "width not measured yet")
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: -1, width: width, dx: 200, dy: 0))
    }
}
