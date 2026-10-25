// 단축어 「에이전트에게 보내기」의 방 고르기(AgentRooms) — AppIntents 파일에 있어 macOS(ios-build)에서만 돈다.
import XCTest
@testable import FamilyChat

final class SendToAgentTests: XCTestCase {
    func testPicksNodeRoomsAndGongmyoungAccRoomOnly() {
        let picked = AgentRooms.pick(from: ["family", "jingun", "family-acc", "test-rs2", "sogyo"])
        XCTAssertEqual(picked, ["jingun", "family-acc", "sogyo"], "keeps order; family and unknown rooms are not agent rooms")
    }

    func testIntentOpensTheAppSoTheSameModelSends() {
        XCTAssertTrue(SendToAgentIntent.openAppWhenRun, "single writer: the app process, not a background extension")
    }
}
