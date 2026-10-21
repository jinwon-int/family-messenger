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
}
