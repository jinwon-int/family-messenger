import XCTest
import FamilyMLSCore
@testable import FamilyChat

/// 초대 창 「이 자리에 있는 사람」(오너 2026-11-19): 기기 명단을 사람 줄로 묶는 규칙.
final class RoomMemberListTests: XCTestCase {
    private func names(_ device: DeviceID) -> String {
        ["dad": "아빠", "mom": "엄마", "jin": "진"][MessageRecord.actor(of: device)]
            ?? (device.hasPrefix("bot-") ? String(device.dropFirst(4)) : device)
    }

    func testGroupsPeopleByActorMeFirstThenFamilyThenAgents() {
        let roster = ["mom-iphone-1a", "bot-seoseo", "jin-iphone-2b", "dad-ipad-3c", "jin-ipad-4d", "bot-gongmyoung"]
        let rows = RoomMemberList.people(roster: roster, myDevice: "jin-iphone-2b", agentActors: ["bot"], name: names)
        XCTAssertEqual(rows.map(\.name), ["진", "아빠", "엄마", "gongmyoung", "seoseo"])
        XCTAssertEqual(rows[0].devices, ["jin-iphone-2b", "jin-ipad-4d"])   // 같은 사람 기기는 한 줄, 명단 순서
        XCTAssertTrue(rows[0].isMe)
        XCTAssertEqual(rows.filter(\.isMe).count, 1)
        XCTAssertEqual(rows.filter(\.isAgent).map(\.id), ["bot-gongmyoung", "bot-seoseo"])   // 에이전트는 기기마다 따로
    }

    func testDuplicateDevicesAndUnknownMyDevice() {
        let rows = RoomMemberList.people(roster: ["mom-iphone-1a", "mom-iphone-1a"], myDevice: "", agentActors: ["bot"], name: names)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].devices, ["mom-iphone-1a"])
        XCTAssertFalse(rows[0].isMe)   // 내 기기 ID 를 모르면 아무도 「나」가 아니다
        XCTAssertTrue(RoomMemberList.people(roster: [], myDevice: "jin-iphone-2b", agentActors: ["bot"], name: names).isEmpty)
    }
}
