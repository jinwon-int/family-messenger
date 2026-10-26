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

    /// 방 진입 직후 lazy 행이 실제 높이로 바뀌거나 이미지가 늦게 커지면 최하단을 다시 맞춘다(build 30: 2~3번째 최신 글에서 멈춤).
    func testContentGrowthRescrollsWhileFollowing() {
        XCTAssertTrue(ScrollFollow.shouldRescrollOnContentGrowth(old: 0, new: 1800, following: true), "first layout")
        XCTAssertTrue(ScrollFollow.shouldRescrollOnContentGrowth(old: 1800, new: 2020, following: true), "an image loaded above the tail")
        XCTAssertFalse(ScrollFollow.shouldRescrollOnContentGrowth(old: 1800, new: 2020, following: false), "reading older messages")
        XCTAssertFalse(ScrollFollow.shouldRescrollOnContentGrowth(old: 2020, new: 1800, following: true), "content shrank (rows recycled)")
        XCTAssertFalse(ScrollFollow.shouldRescrollOnContentGrowth(old: 1800, new: 1800.2, following: true), "sub-point jitter")
    }

    /// 실측 보정: 배치 뒤 바닥 표지가 화면 아래에 남아 있으면(긴 마지막 글의 위만 보임) 한 번 더 맞춘다.
    func testMeasuredBottomCorrection() {
        XCTAssertTrue(ScrollFollow.needsBottomCorrection(sentinelBottom: 900, viewportHeight: 620, following: true), "sentinel below the viewport")
        XCTAssertFalse(ScrollFollow.needsBottomCorrection(sentinelBottom: 619.8, viewportHeight: 620, following: true), "at the bottom")
        XCTAssertFalse(ScrollFollow.needsBottomCorrection(sentinelBottom: 300, viewportHeight: 620, following: true), "short timeline, nothing below")
        XCTAssertFalse(ScrollFollow.needsBottomCorrection(sentinelBottom: 900, viewportHeight: 620, following: false), "reading older messages")
        XCTAssertFalse(ScrollFollow.needsBottomCorrection(sentinelBottom: 900, viewportHeight: 0, following: true), "viewport not measured yet")
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

    /// #472: 위로 끝까지 올라오면 과거 글을 더 읽는다 — 따라가는 중(진입 직후, 표지가 화면에 있어도)·읽는 중·끝에 닿은 방은 읽지 않는다.
    func testLoadOlderOnlyWhenScrolledUpNearTheTop() {
        XCTAssertTrue(ScrollFollow.shouldLoadOlder(sentinelBottom: -100, following: false, busy: false, exhausted: false), "near the top while reading up")
        XCTAssertTrue(ScrollFollow.shouldLoadOlder(sentinelBottom: 12, following: false, busy: false, exhausted: false), "sentinel on screen")
        XCTAssertFalse(ScrollFollow.shouldLoadOlder(sentinelBottom: -5_000, following: false, busy: false, exhausted: false), "far above the viewport")
        XCTAssertFalse(ScrollFollow.shouldLoadOlder(sentinelBottom: 12, following: true, busy: false, exhausted: false), "entry: following the bottom")
        XCTAssertFalse(ScrollFollow.shouldLoadOlder(sentinelBottom: 12, following: false, busy: true, exhausted: false), "a page is already loading")
        XCTAssertFalse(ScrollFollow.shouldLoadOlder(sentinelBottom: 12, following: false, busy: false, exhausted: true), "oldest row already shown")
        XCTAssertFalse(ScrollFollow.shouldLoadOlder(sentinelBottom: SentinelTopKey.defaultValue, following: false, busy: false, exhausted: false), "not measured yet")
    }

    // MARK: #497 — 상대 사진 뒤 위·아래 점프 반복

    /// 새로 생긴 행만 본다: 이 기기에서 보낸 글(보내는 중 포함)과 남의 글(내 다른 기기 포함)을 가른다.
    func testArrivalSeparatesThisDeviceFromOthers() {
        let before: Set<Int64> = [10, 11]
        XCTAssertEqual(ScrollFollow.arrival(before: before, after: [(10, false), (11, false)]), .init(), "nothing new")
        XCTAssertEqual(ScrollFollow.arrival(before: before, after: [(10, false), (11, false), (12, false)]), .init(mine: false, others: true))
        XCTAssertEqual(ScrollFollow.arrival(before: before, after: [(10, false), (11, false), (-1_000, true)]), .init(mine: true, others: false),
                       "my outgoing bubble")
        XCTAssertEqual(ScrollFollow.arrival(before: [10, -1_000], after: [(10, false), (12, true)]), .init(mine: true, others: false),
                       "outgoing replaced by its record (new seq)")
        XCTAssertEqual(ScrollFollow.arrival(before: before, after: [(10, false)]), .init(), "a row left the window — not an arrival")
    }

    /// 내 글은 언제나 최하단(부드럽게) · 남의 글은 따라가는 중이면 즉시 한 번, 위로 읽는 중이면 버튼만 · 새 행이 없으면 아무것도.
    func testAfterReloadDecision() {
        XCTAssertEqual(ScrollFollow.afterReload(following: false, arrival: .init(mine: true, others: true)), .followAnimated)
        XCTAssertEqual(ScrollFollow.afterReload(following: true, arrival: .init(mine: false, others: true)), .follow)
        XCTAssertEqual(ScrollFollow.afterReload(following: false, arrival: .init(mine: false, others: true)), .markNewBelow,
                       "reading older messages: a new photo does not pull the view down")
        XCTAssertEqual(ScrollFollow.afterReload(following: true, arrival: .init()), .stay, "status change only: no scroll command")
        XCTAssertEqual(ScrollFollow.afterReload(following: false, arrival: .init()), .stay)
    }

    /// 끌기로 따라가기가 꺼져도 손을 떼고 맨 아래에 멈추면 다시 따라간다 — 끄는 중에는 아니다.
    func testRefollowOnlyAfterSettlingAtTheBottom() {
        XCTAssertTrue(ScrollFollow.shouldRefollow(following: false, sentinelBottom: 604, viewportHeight: 620, sinceDrag: 1))
        XCTAssertTrue(ScrollFollow.shouldRefollow(following: false, sentinelBottom: 640, viewportHeight: 620, sinceDrag: 1), "within nearBottom")
        XCTAssertFalse(ScrollFollow.shouldRefollow(following: false, sentinelBottom: 604, viewportHeight: 620, sinceDrag: 0.05), "still dragging")
        XCTAssertFalse(ScrollFollow.shouldRefollow(following: false, sentinelBottom: 900, viewportHeight: 620, sinceDrag: 1), "reading older")
        XCTAssertFalse(ScrollFollow.shouldRefollow(following: true, sentinelBottom: 604, viewportHeight: 620, sinceDrag: 1), "already following")
        XCTAssertFalse(ScrollFollow.shouldRefollow(following: false, sentinelBottom: 604, viewportHeight: 0, sinceDrag: 1), "not measured")
    }

    /// 같은 런루프의 스크롤 요청은 하나 — 하나라도 즉시면 즉시, 꺼낸 뒤에는 다시 받는다.
    func testScrollRequestsCoalescePerRunLoop() {
        let tracking = ScrollTracking()
        XCTAssertTrue(tracking.request(animated: true), "first request schedules")
        XCTAssertFalse(tracking.request(animated: true), "second one joins")
        XCTAssertTrue(tracking.take(), "all animated → animated")
        XCTAssertTrue(tracking.request(animated: true))
        XCTAssertFalse(tracking.request(animated: false))
        XCTAssertFalse(tracking.take(), "any immediate → immediate")
        XCTAssertTrue(tracking.request(animated: false), "taken: a new request schedules again")
        XCTAssertFalse(tracking.isAnimating)
        tracking.animatingUntil = Date().addingTimeInterval(10)
        XCTAssertTrue(tracking.isAnimating)
    }
}
