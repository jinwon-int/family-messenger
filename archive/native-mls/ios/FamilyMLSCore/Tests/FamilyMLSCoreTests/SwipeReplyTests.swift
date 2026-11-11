// 말풍선 밀어서 답장 판정(오너 2026-11-09) — 왼쪽만 · 축 고정 · 문턱 · 저항 · 옆으로 미는 블록 제외.
import XCTest
@testable import FamilyMLSCore

final class SwipeReplyTests: XCTestCase {
    func testAxisWaitsUntilLockDistance() {
        XCTAssertNil(SwipeReply.axis(dx: -5, dy: 0), "too small to decide yet")
        XCTAssertNil(SwipeReply.axis(dx: -8, dy: -8), "11.3pt < 12")
        XCTAssertEqual(SwipeReply.axis(dx: -12, dy: 0), .reply, "exactly the lock distance")
    }

    func testLeftwardHorizontalDragLocksToReply() {
        XCTAssertEqual(SwipeReply.axis(dx: -20, dy: 5), .reply)
        XCTAssertEqual(SwipeReply.axis(dx: -16, dy: -10), .reply, "16 > 10 × 1.5")
    }

    func testRightwardVerticalOrDiagonalDragIsIgnored() {
        XCTAssertEqual(SwipeReply.axis(dx: 20, dy: 0), .ignore, "rightward belongs to BackSwipe")
        XCTAssertEqual(SwipeReply.axis(dx: -3, dy: 20), .ignore, "timeline scroll")
        XCTAssertEqual(SwipeReply.axis(dx: -15, dy: -10), .ignore, "15 is not > 10 × 1.5")
    }

    func testOffsetFollowsFingerThenResistsAndCaps() {
        XCTAssertEqual(SwipeReply.offset(dx: 30), 0, "rightward never moves the bubble")
        XCTAssertEqual(SwipeReply.offset(dx: 0), 0)
        XCTAssertEqual(SwipeReply.offset(dx: -40), -40)
        XCTAssertEqual(SwipeReply.offset(dx: -60), -60, "exactly the trigger distance")
        XCTAssertEqual(SwipeReply.offset(dx: -100), -72, accuracy: 1e-9, "60 + 40 × 0.3")
        XCTAssertEqual(SwipeReply.offset(dx: -500), -SwipeReply.maxOffset, "capped")
    }

    func testShouldReplyNeedsTriggerDistanceAndDominance() {
        XCTAssertTrue(SwipeReply.shouldReply(dx: -60, dy: 0), "exactly the trigger distance")
        XCTAssertTrue(SwipeReply.shouldReply(dx: -120, dy: 30))
        XCTAssertFalse(SwipeReply.shouldReply(dx: -59.9, dy: 0), "short")
        XCTAssertFalse(SwipeReply.shouldReply(dx: 120, dy: 0), "rightward")
        // #745: 축은 시작 때 정했다 — 끝에서는 엄지 궤적이 위로 휜 것(약 53°까지)도 답장.
        XCTAssertTrue(SwipeReply.shouldReply(dx: -90, dy: 60), "thumb arc toward the top: 90 ≥ 60 × 0.75")
        XCTAssertTrue(SwipeReply.shouldReply(dx: -75, dy: -100), "75 ≥ 100 × 0.75 (boundary)")
        XCTAssertFalse(SwipeReply.shouldReply(dx: -74, dy: -100), "mostly vertical at release")
    }

    func testDirectionDoesNotOverlapBackSwipe() {
        // 같은 끌기가 뒤로가기와 답장을 둘 다 일으키지 않는다.
        for dx in stride(from: -300.0, through: 300.0, by: 10) {
            let back = BackSwipe.shouldGoBack(startX: 50, width: 390, dx: dx, dy: 0)
            let reply = SwipeReply.shouldReply(dx: dx, dy: 0)
            XCTAssertFalse(back && reply, "dx=\(dx)")
        }
    }

    func testPanBeginsOnlyForLeftwardHorizontalVelocity() {
        // TestFlight 107: 말풍선 위 세로 스크롤이 막혔다 — 세로·오른쪽·정지 끌기는 팬이 시작하지 않아야 스크롤이 받는다.
        XCTAssertTrue(SwipeReply.shouldBegin(vx: -400, vy: 50))
        // #745: 시작 배수 1.2(약 40°) — 위쪽 말풍선의 비스듬한 엄지 출발도 받는다.
        XCTAssertTrue(SwipeReply.shouldBegin(vx: -150, vy: 100), "150 > 100 × 1.2 (was rejected at 1.5)")
        XCTAssertTrue(SwipeReply.shouldBegin(vx: -121, vy: 100), "121 > 100 × 1.2")
        XCTAssertFalse(SwipeReply.shouldBegin(vx: -120, vy: 100), "~40° diagonal")
        XCTAssertFalse(SwipeReply.shouldBegin(vx: -300, vy: 600), "steep diagonal scroll stays a scroll")
        XCTAssertFalse(SwipeReply.shouldBegin(vx: -20, vy: 600), "vertical scroll up")
        XCTAssertFalse(SwipeReply.shouldBegin(vx: 10, vy: -600), "vertical scroll down")
        XCTAssertFalse(SwipeReply.shouldBegin(vx: 400, vy: 0), "rightward belongs to BackSwipe")
        XCTAssertFalse(SwipeReply.shouldBegin(vx: 0, vy: 0), "no motion")
    }

    func testSideScrollZoneBlocksOnlyDragsStartingInsideIt() {
        // #737: 표가 든 카드도 표 밖(문단·제목)에서 시작한 밀기는 답장, 표 위에서 시작한 밀기만 표 넘기기 몫.
        let table = SwipeReply.Zone(minX: 14, minY: 120, maxX: 376, maxY: 300)
        XCTAssertTrue(SwipeReply.startsInSideScroll(x: 200, y: 200, zones: [table]), "inside the table")
        XCTAssertFalse(SwipeReply.startsInSideScroll(x: 200, y: 60, zones: [table]), "paragraph above the table")
        XCTAssertFalse(SwipeReply.startsInSideScroll(x: 200, y: 340, zones: [table]), "list below the table")
        XCTAssertFalse(SwipeReply.startsInSideScroll(x: 5, y: 200, zones: [table]), "card padding left of the table")
    }

    func testSideScrollZoneEdgesBelongToTheBlock() {
        let code = SwipeReply.Zone(minX: 14, minY: 40, maxX: 376, maxY: 90)
        XCTAssertTrue(SwipeReply.startsInSideScroll(x: 14, y: 40, zones: [code]), "top-left corner")
        XCTAssertTrue(SwipeReply.startsInSideScroll(x: 376, y: 90, zones: [code]), "bottom-right corner")
        XCTAssertFalse(SwipeReply.startsInSideScroll(x: 376.5, y: 90, zones: [code]))
        XCTAssertFalse(SwipeReply.startsInSideScroll(x: 200, y: 39.5, zones: [code]))
    }

    func testNoZonesNeverBlocks() {
        // 표·코드 없는 카드·사람 말풍선은 영역이 없다 → 종전 그대로 어디서든 밀기.
        XCTAssertFalse(SwipeReply.startsInSideScroll(x: 0, y: 0, zones: []))
        XCTAssertFalse(SwipeReply.startsInSideScroll(x: 200, y: 200, zones: []))
    }

    func testAnyOfSeveralZonesBlocks() {
        let code = SwipeReply.Zone(minX: 14, minY: 40, maxX: 376, maxY: 90)
        let table = SwipeReply.Zone(minX: 14, minY: 150, maxX: 376, maxY: 260)
        XCTAssertTrue(SwipeReply.startsInSideScroll(x: 100, y: 60, zones: [code, table]))
        XCTAssertTrue(SwipeReply.startsInSideScroll(x: 100, y: 200, zones: [code, table]))
        XCTAssertFalse(SwipeReply.startsInSideScroll(x: 100, y: 120, zones: [code, table]), "text between the two blocks")
    }
}
