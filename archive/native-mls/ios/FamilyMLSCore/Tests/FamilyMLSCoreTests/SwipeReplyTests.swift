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
        XCTAssertFalse(SwipeReply.shouldReply(dx: -90, dy: 60), "ended diagonal: 90 is not > 60 × 1.5")
        XCTAssertTrue(SwipeReply.shouldReply(dx: -91, dy: 60))
    }

    func testDirectionDoesNotOverlapBackSwipe() {
        // 같은 끌기가 뒤로가기와 답장을 둘 다 일으키지 않는다.
        for dx in stride(from: -300.0, through: 300.0, by: 10) {
            let back = BackSwipe.shouldGoBack(startX: 50, width: 390, dx: dx, dy: 0)
            let reply = SwipeReply.shouldReply(dx: dx, dy: 0)
            XCTAssertFalse(back && reply, "dx=\(dx)")
        }
    }

    func testSideScrollBlocksDisableSwipe() {
        XCTAssertFalse(SwipeReply.hasSideScroll(AgentMarkdown.parse("그냥 글\n\n- 목록")))
        XCTAssertTrue(SwipeReply.hasSideScroll(AgentMarkdown.parse("코드:\n```\nlet x = 1\n```")))
        XCTAssertTrue(SwipeReply.hasSideScroll(AgentMarkdown.parse("| a | b |\n|---|---|\n| 1 | 2 |")))
    }
}
