import XCTest
@testable import FamilyChat

/// #405 P1: 승인 버튼이 보내는 글은 봇이 알아듣는 형식이어야 하고(native-mls-bot `parse_approval_reply`), 이름 조사는 받침을 따른다.
final class AgentStringsTests: XCTestCase {
    func testApprovalButtonsSendTheBotsReplyFormat() {
        XCTAssertEqual(Strings.approvalReply(3, allow: true), "승인 3")
        XCTAssertEqual(Strings.approvalReply(12, allow: false), "거절 12")
    }

    func testSubjectParticleFollowsTheFinalConsonant() {
        XCTAssertEqual(Strings.agentThinking("공명"), "공명이 생각하는 중")
        XCTAssertEqual(Strings.approvalTitle("루나"), "루나가 허락을 구합니다")
        XCTAssertEqual(Strings.subjectParticle("newnode"), "이(가)")
    }

    func testSenderLabelUsesNamesAndDeviceKind() {
        XCTAssertEqual(Strings.senderLabel(device: "owner-pc"), "오너 · PC")
        XCTAssertEqual(Strings.senderLabel(device: "jungin-iphone-1b89e3"), "정인 · 아이폰")
        XCTAssertEqual(Strings.senderLabel(device: "dad"), "dad")
        XCTAssertEqual(Strings.senderLabel(device: "bot-gongmyoung"), "공명")
    }

    func testPreviewLineDropsMarkdownNoise() {
        XCTAssertEqual(Strings.previewLine(name: "공명", body: "## 결과\n| 방 | 모드 |\n**두 개**입니다 `room_status`"),
                       "공명: 결과 방 | 모드 | 두 개입니다 room_status")
    }

    func testMessageTimeAndDayLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = Date(timeIntervalSince1970: 1_792_306_680)  // 2026-10-18 15:58 KST(토)
        XCTAssertEqual(Strings.dayLabel(now, now: now, calendar: calendar), "오늘")
        XCTAssertEqual(Strings.dayLabel(now.addingTimeInterval(-86_400), now: now, calendar: calendar), "어제")
        XCTAssertTrue(Strings.dayLabel(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar).hasSuffix("요일"))
        XCTAssertTrue(Strings.dayLabel(now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar).contains("년"))
        let time = Strings.messageTime(now)
        XCTAssertTrue(time.hasPrefix("오전") || time.hasPrefix("오후"), time)
    }

    func testListHeaderWordmarkAndTagline() {
        XCTAssertEqual(Strings.wordmark, "HANDE")
        XCTAssertEqual(Strings.campfireSubtitle, "오늘 밤, 모닥불에 한데 모여")
    }

    func testKnownAgentName() {
        XCTAssertEqual(Strings.agentNames["gongmyoung"], "공명")
    }
}
