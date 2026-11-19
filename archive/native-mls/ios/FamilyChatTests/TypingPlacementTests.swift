import XCTest
@testable import FamilyChat

/// 「타닥타닥…」 자리(오너 2026-11-19): 뒤로가기와 방 이름 사이 가운데, 좁으면 점 + 불 → 점만 — 어느 쪽이든 방 이름에 겹치지 않는다.
/// 꾸밈(오너 2026-11-20): 불 그림 1→2→3 을 0.5초씩, 에이전트만 치면 파란 점.
final class TypingPlacementTests: XCTestCase {
    private func place(_ titleMinX: Double, text: Double = 54) -> TypingPlacement.Result {
        TypingPlacement.place(titleMinX: titleMinX, backTrailing: 60,
                              fullWidth: TypingPlacement.fullWidth(textWidth: text), compactWidth: TypingPlacement.compactWidth)
    }

    func testCentersBetweenBackButtonAndTitle() {
        // 뒤로가기 끝 60, 방 이름 시작 160 → 틈 100, 배지(6+4+54+4+14=82) → 가운데 = 방 이름에서 50 왼쪽.
        let r = place(160)
        XCTAssertEqual(r, .init(shape: .full, shift: 50))
        XCTAssertGreaterThanOrEqual(r.shift - TypingPlacement.fullWidth(textWidth: 54) / 2, TypingPlacement.minGap)
    }

    func testNarrowGapDropsTextThenFlame() {
        XCTAssertEqual(place(120), .init(shape: .compact, shift: 30))   // 틈 60: 글자는 안 들어가고 점 + 불(24)은 들어감
        let tight = place(80)                                            // 틈 20 < 24 + 8
        XCTAssertEqual(tight.shape, .dotOnly)
        XCTAssertEqual(tight.shift, 10)
        // 측정 전(0) 같은 음수 틈에도 점은 방 이름 왼쪽에 떨어져 있다.
        XCTAssertEqual(place(0), .init(shape: .dotOnly, shift: TypingPlacement.dotWidth / 2 + TypingPlacement.minGap))
    }

    func testFlameCyclesOneTwoThreeEveryHalfSecond() {
        let base = Date(timeIntervalSinceReferenceDate: 3000)   // 3000 / 0.5 = 6000 → 6000 % 3 = 0 → 1단계
        let levels = (0..<7).map { TypingIndicator.flameLevel(at: base.addingTimeInterval(Double($0) * 0.5 + 0.1)) }
        XCTAssertEqual(levels, [1, 2, 3, 1, 2, 3, 1])
        XCTAssertEqual(TypingIndicator.flameLevel(at: base.addingTimeInterval(0.49)), 1)   // 0.5초 안에서는 같은 그림
    }

    func testDotIsBlueOnlyWhenEveryTypistIsAnAgent() {
        let agents: Set<String> = ["bot"]
        XCTAssertTrue(TypingIndicator.agentOnly(devices: ["bot-gongmyoung"], agentActors: agents))
        XCTAssertTrue(TypingIndicator.agentOnly(devices: ["bot-gongmyoung", "bot-seoseo"], agentActors: agents))
        XCTAssertFalse(TypingIndicator.agentOnly(devices: ["mom-iphone-1a"], agentActors: agents))
        XCTAssertFalse(TypingIndicator.agentOnly(devices: ["bot-gongmyoung", "mom-iphone-1a"], agentActors: agents))   // 사람이 섞이면 크림색
        XCTAssertFalse(TypingIndicator.agentOnly(devices: [], agentActors: agents))
    }
}
