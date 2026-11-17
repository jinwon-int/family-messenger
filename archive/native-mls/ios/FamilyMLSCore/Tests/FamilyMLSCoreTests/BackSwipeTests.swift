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

    // #829(오너 2026-11-17): 긴 표를 오른쪽으로 되밀면 표가 움직이면서 목록으로도 나갔다.
    func testDragStartedOnSideScrollBlockDoesNotGoBack() {
        XCTAssertTrue(BackSwipe.shouldGoBack(startX: 100, width: width, dx: 120, dy: 4, startedOnSideScroll: false))
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 100, width: width, dx: 120, dy: 4, startedOnSideScroll: true),
                       "scrolling a wide table back to its first columns must stay in the room")
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 5, width: width, dx: 300, dy: 0, startedOnSideScroll: true),
                       "the wide swipe is off even from the edge — the system edge swipe is a separate recognizer")
    }

    func testStartsOnSideScrollUsesBlockAreasInTimelineCoordinates() {
        let table = SwipeReply.Zone(minX: 16, minY: 300, maxX: 374, maxY: 460)
        let code = SwipeReply.Zone(minX: 16, minY: 520, maxX: 374, maxY: 560)
        XCTAssertTrue(BackSwipe.startsOnSideScroll(x: 120, y: 380, blocks: [table, code]))
        XCTAssertTrue(BackSwipe.startsOnSideScroll(x: 120, y: 540, blocks: [table, code]))
        XCTAssertTrue(BackSwipe.startsOnSideScroll(x: 16, y: 300, blocks: [table]), "edges count as the block")
        XCTAssertFalse(BackSwipe.startsOnSideScroll(x: 120, y: 480, blocks: [table, code]), "the paragraph between the blocks")
        XCTAssertFalse(BackSwipe.startsOnSideScroll(x: 120, y: 299, blocks: [table]))
        XCTAssertFalse(BackSwipe.startsOnSideScroll(x: 120, y: 380, blocks: []), "no wide block on screen — old behaviour")
    }

    func testOnlyBlocksThatActuallyOverflowCount() {
        XCTAssertTrue(BackSwipe.overflowsSideways(contentWidth: 620, viewportWidth: 358))
        XCTAssertFalse(BackSwipe.overflowsSideways(contentWidth: 300, viewportWidth: 358), "a narrow table does not scroll")
        XCTAssertFalse(BackSwipe.overflowsSideways(contentWidth: 358.5, viewportWidth: 358), "rounding slack")
        XCTAssertFalse(BackSwipe.overflowsSideways(contentWidth: 359, viewportWidth: 358), "exactly the tolerance")
        XCTAssertTrue(BackSwipe.overflowsSideways(contentWidth: 359.1, viewportWidth: 358))
        XCTAssertFalse(BackSwipe.overflowsSideways(contentWidth: 620, viewportWidth: 0), "not laid out yet")
    }

    func testUnmeasuredWidthOrNegativeStartDoesNotGoBack() {
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: 10, width: 0, dx: 200, dy: 0), "width not measured yet")
        XCTAssertFalse(BackSwipe.shouldGoBack(startX: -1, width: width, dx: 200, dy: 0))
    }
}
