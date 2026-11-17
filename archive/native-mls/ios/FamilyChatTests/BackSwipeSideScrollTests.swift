// #829(오너 2026-11-17): 넓은 뒤로가기가 긴 표의 가로 스크롤과 겹쳐 대화 목록으로 나갔다.
// 타임라인 스크롤 뷰 아래에서 **가로로 넘치는** 블록만, 타임라인 칸 좌표로 찾는지 확인한다(`TimelineScrollHandle.sideScrollBlocks`).
import XCTest
import UIKit
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class BackSwipeSideScrollTests: XCTestCase {
    /// 타임라인(390×600, 세로로 1,000pt 내려간 상태) 안에 행 하나 — 그 안에 넓은 표, 좁은 표.
    private func makeTimeline() -> (window: UIWindow, timeline: UIScrollView, wide: UIScrollView, narrow: UIScrollView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let timeline = UIScrollView(frame: CGRect(x: 0, y: 100, width: 390, height: 600))
        timeline.contentSize = CGSize(width: 390, height: 4000)
        timeline.contentOffset = CGPoint(x: 0, y: 1000)
        window.addSubview(timeline)

        let row = UIView(frame: CGRect(x: 16, y: 1200, width: 358, height: 400)) // 내용 좌표
        timeline.addSubview(row)

        let wide = UIScrollView(frame: CGRect(x: 0, y: 20, width: 358, height: 160))
        wide.contentSize = CGSize(width: 900, height: 160)
        wide.contentOffset = CGPoint(x: 240, y: 0) // 이미 옆으로 민 상태 — 보이는 칸은 그대로여야 한다
        row.addSubview(wide)

        let narrow = UIScrollView(frame: CGRect(x: 0, y: 220, width: 358, height: 100))
        narrow.contentSize = CGSize(width: 300, height: 100)
        row.addSubview(narrow)
        return (window, timeline, wide, narrow)
    }

    func testOnlyOverflowingBlocksAreReportedInTimelineViewportCoordinates() {
        let made = makeTimeline()
        let handle = TimelineScrollHandle()
        handle.scrollView = made.timeline

        // 행 y 1200 + 표 y 20 − 타임라인 스크롤 1000 = 칸 좌표 y 220…380, x 16…374
        XCTAssertEqual(handle.sideScrollBlocks, [SwipeReply.Zone(minX: 16, minY: 220, maxX: 374, maxY: 380)])

        let blocks = handle.sideScrollBlocks
        XCTAssertTrue(BackSwipe.startsOnSideScroll(x: 120, y: 300, blocks: blocks), "on the wide table")
        XCTAssertFalse(BackSwipe.startsOnSideScroll(x: 120, y: 470, blocks: blocks), "on the narrow table — it does not scroll")
        XCTAssertFalse(BackSwipe.startsOnSideScroll(x: 120, y: 100, blocks: blocks), "above the row")
        _ = made.window // 끝까지 창을 붙들어 둔다(`attached` 는 창에 붙은 스크롤 뷰만)
    }

    func testAreasFollowTheTimelineScrollPosition() {
        let made = makeTimeline()
        let handle = TimelineScrollHandle()
        handle.scrollView = made.timeline
        made.timeline.contentOffset = CGPoint(x: 0, y: 1100)
        XCTAssertEqual(handle.sideScrollBlocks, [SwipeReply.Zone(minX: 16, minY: 120, maxX: 374, maxY: 280)])
        _ = made.window
    }

    func testNoBlocksWhenNothingOverflowsOrTheScrollViewIsGone() {
        let made = makeTimeline()
        let handle = TimelineScrollHandle()
        XCTAssertEqual(handle.sideScrollBlocks, [], "no scroll view held — old behaviour")

        handle.scrollView = made.timeline
        made.wide.contentSize = CGSize(width: 358, height: 160)
        XCTAssertEqual(handle.sideScrollBlocks, [], "nothing overflows")

        made.wide.contentSize = CGSize(width: 900, height: 160)
        made.wide.isHidden = true
        XCTAssertEqual(handle.sideScrollBlocks, [], "hidden block")

        made.wide.isHidden = false
        made.timeline.removeFromSuperview()
        XCTAssertEqual(handle.sideScrollBlocks, [], "detached from the window")
    }
}
