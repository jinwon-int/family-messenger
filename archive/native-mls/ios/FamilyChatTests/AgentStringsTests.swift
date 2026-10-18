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

    func testKnownAgentName() {
        XCTAssertEqual(Strings.agentNames["gongmyoung"], "공명")
    }
}
