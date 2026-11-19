import XCTest
@testable import FamilyChat

/// 「타닥타닥…」 자리(오너 2026-11-19): 뒤로가기와 방 이름 사이 가운데, 좁으면 점만 — 어느 쪽이든 방 이름에 겹치지 않는다.
final class TypingPlacementTests: XCTestCase {
    func testCentersBetweenBackButtonAndTitle() {
        // 뒤로가기 끝 60, 방 이름 시작 150 → 틈 90, 배지 64 → 가운데(105) = 방 이름에서 45 왼쪽.
        let r = TypingPlacement.place(titleMinX: 150, backTrailing: 60, badgeWidth: 64)
        XCTAssertEqual(r, .init(shape: .full, shift: 45))
        XCTAssertGreaterThanOrEqual(r.shift - 64 / 2, TypingPlacement.minGap)   // 배지 오른쪽 끝이 방 이름과 떨어져 있다
    }

    func testNarrowGapFallsBackToDotAwayFromTitle() {
        let r = TypingPlacement.place(titleMinX: 100, backTrailing: 60, badgeWidth: 64)   // 틈 40 < 64 + 8
        XCTAssertEqual(r.shape, .dotOnly)
        XCTAssertEqual(r.shift, 20)
        // 측정 전(0) 같은 음수 틈에도 점은 방 이름 왼쪽에 떨어져 있다.
        let early = TypingPlacement.place(titleMinX: 0, backTrailing: 60, badgeWidth: 64)
        XCTAssertEqual(early, .init(shape: .dotOnly, shift: TypingPlacement.dotWidth / 2 + TypingPlacement.minGap))
    }
}
